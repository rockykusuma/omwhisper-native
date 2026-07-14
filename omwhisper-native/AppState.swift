//
//  AppState.swift
//  OmWhisper
//
//  Single source of truth for app state (fixes the Tauri app's settings-sync debt:
//  never do per-view read-modify-write of settings). Also owns the M1 core loop:
//  hotkey -> AudioCapture -> TranscriptionEngine -> overlay partials -> paste on stop.
//

import AppKit
import AVFoundation
import FluidAudio  // ParakeetEngine download progress type (fractionCompleted)
import Foundation
import Observation
import os
import ServiceManagement
import Speech

// nonisolated: called from HistoryStore/LegacyHistoryImporter's background
// work too, not just MainActor code — Logger is Sendable, safe either way.
nonisolated let log = Logger(subsystem: "com.omwhisper.mac", category: "AppState")
private let latencyLog = Logger(subsystem: "com.omwhisper.mac", category: "Latency")

/// True when the process is an XCTest host. Guards side effects that must
/// never fire during test runs — global hotkeys, the menu-bar status item,
/// permission prompts, Sparkle's update checker, real HistoryStore/legacy-
/// import I/O — which otherwise launch a real, fully-interactive instance of
/// the app for every test run and don't self-terminate when the run finishes,
/// leaving orphaned menu-bar icons and live global event taps behind
/// indefinitely.
///
/// Checks whether the XCTest framework is loaded into this process — true
/// regardless of how the test host was launched (dyld injects XCTest before
/// user code runs, so this is available from the very start). Neither the
/// XCTestConfigurationFilePath env var nor the -ApplePersistenceIgnoreState
/// launch argument xcodebuild's CLI passes turned out to be reliable:
/// launching tests via Xcode's own Test navigator/Cmd+U — as opposed to the
/// `xcodebuild test` CLI every automated run in this project had used so
/// far — sets neither, so a real hotkey/PTT/status-item/Sparkle instance
/// still launched under that path with only the argument-based check.
nonisolated let isRunningUnderTests = NSClassFromString("XCTestCase") != nil

// nonisolated: plain data, no MainActor affinity — without this, the project's
// MainActor-by-default setting also pins the synthesized Equatable conformance,
// which then can't be used from a nonisolated context (e.g. exitPhase's tests).
nonisolated enum DictationState: Equatable {
    case idle
    case starting     // toggle fired, awaiting permissions / capture start (claimed synchronously)
    case recording
    case finalizing   // stop pressed, waiting for final transcript / paste
}

/// Transient overlay-only flourish, layered on top of `.finalizing` — NOT a
/// second dictation state machine. `dictation` stays authoritative; this only
/// decorates how the overlay renders the tail end of a session, and is reset
/// to `.none` the instant `dictation` returns to `.idle`. See OVERLAY_SPEC.md §4.
nonisolated enum OverlayPhase: Equatable {
    case none
    case pasting
    case polishing               // Smart Dictation / Polish Selected Text running the active style
    case error(label: String)   // "NOTHING HEARD" | "SOMETHING BROKE — TEXT COPIED"
    case cancelled
}

/// What a dictation session does with its text on stop.
nonisolated enum SessionMode { case normal, smart, brainDump }

@MainActor
@Observable
final class AppState {
    // MARK: Live session
    var dictation: DictationState = .idle
    /// Overlay-only exit flourish (pasting/error/cancelled) — see `OverlayPhase`.
    var overlayPhase: OverlayPhase = .none
    /// Streaming transcript: volatile (dimmed in UI) + finalized portions.
    var volatileTranscript: String = ""
    var finalizedTranscript: String = ""
    /// Set on permission failure or engine error; cleared at the start of the next attempt.
    var errorMessage: String?
    /// True only while the onboarding "Try it" step is on screen. Makes
    /// stopDictation() skip the paste/clipboard + history-record blocks, so the
    /// real dictation pipeline runs (overlay, sounds, live transcript) but the
    /// demo never pastes into another app or pollutes history. Set by OnboardingView.
    var onboardingDemoActive = false

    /// Overlay presentation for the CURRENT session — captured from `overlayStyle`
    /// when the overlay is shown, so a mid-session settings change never reshapes a
    /// live overlay (OVERLAY_SPEC §3: "applies next dictation only").
    private(set) var sessionOverlayStyle: OverlayStyle = .full
    /// Non-nil only while the settings "Preview" demo runs (see previewOverlay).
    var overlayPreview: OverlayStyle?

    // MARK: Settings (persisted; keep keys stable — see SettingsKeys)
    var pasteAfterStop: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.pasteAfterStop) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.pasteAfterStop) }
    }
    /// Hub/menu-bar-panel appearance. `.system` (default) follows macOS; `.light`/
    /// `.dark` override it. Drives the window's NSAppearance + SwiftUI colorScheme
    /// (see HubShellView). access/withMutation needed for the same reason as
    /// polishBackend — it backs a Picker that must re-highlight on change.
    var appearancePreference: AppearancePreference {
        get {
            access(keyPath: \.appearancePreference)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.appearancePreference) else { return .system }
            return AppearancePreference(rawValue: raw) ?? .system
        }
        set {
            withMutation(keyPath: \.appearancePreference) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.appearancePreference)
            }
        }
    }
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.soundEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.soundEnabled) }
    }
    /// Matches the old app's default (`sound_volume: 0.2`).
    var soundVolume: Double {
        get { UserDefaults.standard.object(forKey: SettingsKeys.soundVolume) as? Double ?? 0.2 }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.soundVolume) }
    }
    /// nil = system default input. AVCaptureDevice.uniqueID, not a display name
    /// (the old app matched by name, which breaks for two identical mic models).
    var audioInputDeviceUID: String? {
        get {
            access(keyPath: \.audioInputDeviceUID)
            return UserDefaults.standard.string(forKey: SettingsKeys.audioInputDeviceUID)
        }
        set {
            withMutation(keyPath: \.audioInputDeviceUID) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.audioInputDeviceUID)
            }
        }
    }
    var customVocabulary: [String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customVocabulary) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customVocabulary) }
    }
    var wordReplacements: [ReplacementRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.wordReplacements) else { return [] }
            return (try? JSONDecoder().decode([ReplacementRule].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.wordReplacements) }
    }
    var fuzzyVocabCorrection: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection) }
    }
    /// Disabled by default — polish is opt-in.
    ///
    /// access(keyPath:)/withMutation(keyPath:) manually register this with
    /// Observation: @Observable only auto-instruments *stored* properties, so
    /// a plain get/set computed property over UserDefaults — like every other
    /// setting in this file — never fires a change notification on its own.
    /// That's invisible for a Toggle (its own click animation looks right
    /// regardless of whether the view body actually re-renders), but a
    /// `.pickerStyle(.radioGroup)` Picker needs a real Observation signal to
    /// re-highlight the selected option, so without this it stays showing the
    /// stale selection until some unrelated event forces the view to rebuild
    /// (e.g. switching Settings tabs and back) — found via live verification.
    var polishBackend: PolishBackendKind {
        get {
            access(keyPath: \.polishBackend)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.polishBackend) else { return .disabled }
            return PolishBackendKind(rawValue: raw) ?? .disabled
        }
        set {
            withMutation(keyPath: \.polishBackend) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.polishBackend)
            }
        }
    }
    var ollamaBaseURL: String {
        get {
            access(keyPath: \.ollamaBaseURL)
            return UserDefaults.standard.string(forKey: SettingsKeys.ollamaBaseURL) ?? "http://localhost:11434"
        }
        set {
            withMutation(keyPath: \.ollamaBaseURL) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.ollamaBaseURL)
            }
        }
    }
    var ollamaModel: String {
        get {
            access(keyPath: \.ollamaModel)
            return UserDefaults.standard.string(forKey: SettingsKeys.ollamaModel) ?? ""
        }
        set {
            withMutation(keyPath: \.ollamaModel) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.ollamaModel)
            }
        }
    }
    var cloudAPIURL: String {
        get {
            access(keyPath: \.cloudAPIURL)
            return UserDefaults.standard.string(forKey: SettingsKeys.cloudAPIURL) ?? "https://api.openai.com/v1"
        }
        set {
            withMutation(keyPath: \.cloudAPIURL) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.cloudAPIURL)
            }
        }
    }
    var cloudModel: String {
        get {
            access(keyPath: \.cloudModel)
            return UserDefaults.standard.string(forKey: SettingsKeys.cloudModel) ?? "gpt-4o-mini"
        }
        set {
            withMutation(keyPath: \.cloudModel) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.cloudModel)
            }
        }
    }
    /// Defaults to Smart Correct — the least presumptuous built-in (cleanup only,
    /// preserves the speaker's own wording), a safe universal default.
    var activePolishStyleID: UUID {
        get {
            access(keyPath: \.activePolishStyleID)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.activePolishStyleID),
                  let id = UUID(uuidString: raw) else { return PolishStyles.builtIns[6].id }
            return id
        }
        set {
            withMutation(keyPath: \.activePolishStyleID) {
                UserDefaults.standard.set(newValue.uuidString, forKey: SettingsKeys.activePolishStyleID)
            }
        }
    }
    var activePolishStyle: PolishStyle? {
        PolishStyles.style(id: activePolishStyleID, customStyles: customPolishStyles)
    }
    var translateTargetLanguage: String {
        get {
            access(keyPath: \.translateTargetLanguage)
            return UserDefaults.standard.string(forKey: SettingsKeys.translateTargetLanguage) ?? "English"
        }
        set {
            withMutation(keyPath: \.translateTargetLanguage) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.translateTargetLanguage)
            }
        }
    }
    var customPolishStyles: [PolishStyle] {
        get {
            access(keyPath: \.customPolishStyles)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customPolishStyles) else { return [] }
            return (try? JSONDecoder().decode([PolishStyle].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.customPolishStyles) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customPolishStyles)
            }
        }
    }

    // MARK: Brain-dump (F5)
    var activeBrainDumpShapeID: UUID {
        get {
            access(keyPath: \.activeBrainDumpShapeID)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.activeBrainDumpShapeID),
                  let id = UUID(uuidString: raw) else { return BrainDumpShapes.builtIns[0].id }
            return id
        }
        set {
            withMutation(keyPath: \.activeBrainDumpShapeID) {
                UserDefaults.standard.set(newValue.uuidString, forKey: SettingsKeys.activeBrainDumpShapeID)
            }
        }
    }
    var activeBrainDumpShape: PolishStyle? {
        BrainDumpShapes.shape(id: activeBrainDumpShapeID, customShapes: brainDumpShapes)
    }
    var brainDumpShapes: [PolishStyle] {
        get {
            access(keyPath: \.brainDumpShapes)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.brainDumpShapes) else { return [] }
            return (try? JSONDecoder().decode([PolishStyle].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.brainDumpShapes) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.brainDumpShapes)
            }
        }
    }

    // MARK: Custom dictation triggers
    var dictationShortcut: KeyCombo {
        get {
            access(keyPath: \.dictationShortcut)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.dictationShortcut),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else {
                return .defaultDictation
            }
            return combo
        }
        set {
            withMutation(keyPath: \.dictationShortcut) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.dictationShortcut)
            }
            hotkey.reconfigure(keyCode: newValue.keyCode, modifiers: newValue.flags)
        }
    }
    var pttKey: PTTKey {
        get {
            access(keyPath: \.pttKey)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.pttKey),
                  let k = PTTKey(rawValue: raw) else { return .fn }
            return k
        }
        set {
            withMutation(keyPath: \.pttKey) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.pttKey)
            }
            pushToTalk.reconfigure(key: newValue)
        }
    }
    /// Off by default — every Smriti-derived feature in this project ships off
    /// by default. Reads the frontmost window's visible text at dictation start
    /// to bias engine vocabulary; nothing is stored. See S2 design spec.
    var contextAwareDictationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.contextAwareDictationEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.contextAwareDictationEnabled) }
    }
    /// SMAppService is itself the source of truth (macOS's login-item registry) —
    /// unlike the other settings above, nothing is mirrored into UserDefaults.
    /// access/withMutation so `@Observable` re-renders a bound control after the
    /// register/unregister — without them the getter is a plain computed property
    /// that fires no change notification, so a Toggle/checkbox never reflects the
    /// new status (a switch-style Toggle masks it with its own animation; a
    /// `.checkbox` Toggle, like onboarding's, visibly snaps back).
    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    log.error("launchAtLogin — \(newValue ? "register" : "unregister") failed: \(error)")
                }
            }
        }
    }
    /// nil = off. 0 doubles as "unset" since UserDefaults.integer(forKey:) already
    /// returns 0 for a missing key — no separate "has a value" bookkeeping needed.
    var autoDeleteAfterDays: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: SettingsKeys.autoDeleteAfterDays)
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: SettingsKeys.autoDeleteAfterDays) }
    }
    /// Off by default — every Smriti-derived feature ships off by default.
    /// MeetingWatcher isn't started at all unless this is on: no poll timer,
    /// no consent prompts, no recording capability for a user who never opens
    /// this tab. access(keyPath:)/withMutation(keyPath:) needed for the same
    /// reason as the M3 polish settings — a plain get/set computed property
    /// over UserDefaults never fires an Observation change notification on
    /// its own, and this Toggle needs to reflect external state changes.
    var meetingsEnabled: Bool {
        get {
            access(keyPath: \.meetingsEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.meetingsEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.meetingsEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.meetingsEnabled)
            }
            if newValue {
                meetingWatcher.isSuppressed = { [weak self] in self?.dictation != .idle }
                meetingWatcher.onStartRecording = { [weak self] appName in
                    self?.beginRecording(appName: appName)
                }
                meetingWatcher.onStopRecording = { [weak self] in
                    Task { await self?.endRecording() }
                }
                meetingWatcher.onShowConsentPanel = { [weak self] appName, respond in
                    self?.meetingConsentPanel.show(appName: appName, onDecision: respond)
                }
                meetingWatcher.start()
            } else {
                meetingWatcher.stop()
            }
        }
    }

    /// Start the recorder and mark recording. Shared by the auto-detect closure
    /// and the manual toggle. On failure, resets the watcher so it isn't stuck
    /// showing .recording with no audio actually flowing.
    private func beginRecording(appName: String) {
        do {
            try meetingRecorder.start(appName: appName, preferredMicUID: audioInputDeviceUID)
            meetingStartedAt = Date()
            meetingAppName = appName
            isRecordingMeeting = true
        } catch {
            log.error("meeting recording failed to start: \(error)")
            meetingWatcher.failedToStartRecording()
            isRecordingMeeting = false
        }
    }

    /// Stop the recorder, clear the flag, and persist the finished-meeting row.
    private func endRecording() async {
        await meetingRecorder.stop()
        isRecordingMeeting = false
        recordFinishedMeeting()
    }

    /// User-initiated start/stop, available anytime (records system audio + mic
    /// on demand — independent of the meetingsEnabled auto-detect toggle, which
    /// only governs automatic call detection + the consent prompt). The watcher-
    /// coordination calls are harmless no-ops when the watcher isn't running.
    /// Clicking record IS the consent — no consent panel here.
    func toggleMeetingRecording() {
        if isRecordingMeeting {
            meetingWatcher.markDeclined()
            Task { await endRecording() }
        } else {
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Recording"
            meetingWatcher.enterRecording(appName: appName)
            beginRecording(appName: appName)
        }
    }

    /// Called after meetingRecorder.stop() flushes me.caf/them.caf: insert a
    /// "Recorded" row so the meeting shows immediately (transcript/summary filled
    /// on demand by transcribeMeeting).
    private func recordFinishedMeeting() {
        guard let store = meetingStore, let dir = meetingRecorder.meetingDirectory else { return }
        let iso = ISO8601DateFormatter()
        let duration = MeetingTranscriber.audioDuration(dir.appendingPathComponent("me.caf"))
        do {
            _ = try store.insert(Meeting(
                id: nil,
                startedAt: iso.string(from: meetingStartedAt ?? Date()),
                appName: meetingAppName ?? "Meeting",
                directory: dir.path,
                durationSeconds: duration,
                transcript: nil, summary: nil,
                createdAt: iso.string(from: Date())
            ))
        } catch {
            log.error("recordFinishedMeeting — insert failed: \(error)")
        }
        meetingStartedAt = nil
        meetingAppName = nil
    }

    /// The view's path: transcribe both tracks on-device (AppleEngine) and, if
    /// Apple Intelligence is on, summarize (SystemLLM) -- never Cloud/Ollama,
    /// regardless of the dictation/polish backend. Transcript is always saved;
    /// summary is best-effort. Returns the updated meeting.
    func transcribeMeeting(id: Int64) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id) else {
            throw MeetingStoreError.notFound
        }
        let transcript = try await MeetingTranscriber.transcribeMeeting(
            directory: URL(fileURLWithPath: meeting.directory), engine: AppleEngine(), whisper: whisperEngine
        )
        var summary: String?
        if SystemLLM.isAvailable() {
            summary = try? await MeetingSummarizer.generate(transcript: transcript, polish: systemLLM)
        } else if !didNudgeFoundationModelsUnavailable {
            didNudgeFoundationModelsUnavailable = true
            errorMessage = "Apple Intelligence is off — enable it in Settings > AI to summarize meetings. Transcript saved without a summary."
        }
        try store.setTranscriptAndSummary(id: id, transcript: transcript, summary: summary)
        return try store.get(id: id) ?? meeting
    }

    /// access(keyPath:)/withMutation(keyPath:) for the same reason as
    /// meetingsEnabled — this Toggle needs to reflect external state changes.
    var replyAssistEnabled: Bool {
        get {
            access(keyPath: \.replyAssistEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.replyAssistEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.replyAssistEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.replyAssistEnabled)
            }
            if newValue {
                replyAssistMonitor.isSuppressed = { [weak self] in self?.dictation != .idle }
                replyAssistMonitor.onTriggered = { [weak self] in
                    Task { await self?.beginReplyAssist() }
                }
                replyAssistMonitor.start()
            } else {
                replyAssistMonitor.stop()
            }
        }
    }

    var memoryEnabled: Bool {
        get {
            access(keyPath: \.memoryEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.memoryEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.memoryEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryEnabled)
            }
            if newValue {
                memoryCapture.store = memoryStore
                memoryCapture.isSuppressed = { [weak self] in self?.memoryPaused ?? false }
                memoryCapture.captureIntervalSeconds = 5
                memoryCapture.retentionDays = memoryRetentionDays
                memoryCapture.excludedDomains = memoryExcludedDomains
                memoryCapture.start()
                chronicleScheduler.store = memoryStore
                chronicleScheduler.polish = systemLLM
                chronicleScheduler.isSuppressed = { [weak self] in
                    self?.polishBackend != .system || !SystemLLM.isAvailable()
                }
                chronicleScheduler.start()
            } else {
                memoryCapture.stop()
                chronicleScheduler.stop()
            }
        }
    }

    var memoryPaused: Bool {
        get {
            access(keyPath: \.memoryPaused)
            return UserDefaults.standard.object(forKey: SettingsKeys.memoryPaused) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.memoryPaused) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryPaused)
            }
        }
    }

    var memoryRetentionDays: Int {
        get {
            access(keyPath: \.memoryRetentionDays)
            let value = UserDefaults.standard.object(forKey: SettingsKeys.memoryRetentionDays) as? Int
            return value ?? 90
        }
        set {
            withMutation(keyPath: \.memoryRetentionDays) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryRetentionDays)
            }
            memoryCapture.retentionDays = newValue
        }
    }

    /// Bare hostnames (e.g. "example.com") whose pages are never captured into
    /// memory; subdomains are covered too (see BrowserURL.domain(_:matches:)).
    /// Only affects browser windows -- a snapshot with no URL is never excluded
    /// by domain. Empty by default.
    var memoryExcludedDomains: [String] {
        get {
            access(keyPath: \.memoryExcludedDomains)
            return UserDefaults.standard.stringArray(forKey: SettingsKeys.memoryExcludedDomains) ?? []
        }
        set {
            withMutation(keyPath: \.memoryExcludedDomains) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryExcludedDomains)
            }
            memoryCapture.excludedDomains = newValue
        }
    }

    func regenerateChronicle(day: String) async throws -> Chronicler.ChronicleResult {
        guard let memoryStore else { throw Chronicler.ChroniclerError.noSnapshots }
        return try await Chronicler.generate(day: day, store: memoryStore, polish: systemLLM)
    }

    var mcpAccessEnabled: Bool {
        get {
            access(keyPath: \.mcpAccessEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.mcpAccessEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.mcpAccessEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.mcpAccessEnabled)
            }
        }
    }

    /// First-run gate. False until onboarding is finished or skipped; then the
    /// Welcome window never auto-opens again. access/withMutation so a DEBUG
    /// "Reset Onboarding" re-open (and any bound control) sees the change.
    var hasCompletedOnboarding: Bool {
        get {
            access(keyPath: \.hasCompletedOnboarding)
            return UserDefaults.standard.object(forKey: SettingsKeys.hasCompletedOnboarding) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.hasCompletedOnboarding) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.hasCompletedOnboarding)
            }
        }
    }

    var engineKind: EngineKind {
        get {
            access(keyPath: \.engineKind)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.engineKind),
                  let kind = EngineKind(rawValue: raw) else { return .apple }
            return kind
        }
        set {
            withMutation(keyPath: \.engineKind) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.engineKind)
            }
        }
    }

    /// Which Parakeet variant to load (only relevant when engineKind == .parakeet).
    /// access/withMutation so the radio picker re-highlights; the setter also tells
    /// the engine so isReady/downloads track the selected variant.
    var parakeetModel: ParakeetModel {
        get {
            access(keyPath: \.parakeetModel)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.parakeetModel),
                  let model = ParakeetModel(rawValue: raw) else { return .v3 }
            return model
        }
        set {
            withMutation(keyPath: \.parakeetModel) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.parakeetModel)
            }
            parakeetEngine.setModel(newValue)
        }
    }

    /// Which Whisper variant to load (only relevant when engineKind == .whisper).
    /// access/withMutation so the radio picker re-highlights; setter syncs the engine.
    var whisperModel: WhisperModel {
        get {
            access(keyPath: \.whisperModel)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.whisperModel),
                  let model = WhisperModel(rawValue: raw) else { return .largeV3Turbo }
            return model
        }
        set {
            withMutation(keyPath: \.whisperModel) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.whisperModel)
            }
            whisperEngine.setModel(newValue)
        }
    }

    /// Which cloud transcription provider (only relevant when engineKind == .cloud).
    /// Read by activeEngine to build CloudEngine(provider:). access/withMutation so
    /// the provider picker re-highlights on change.
    var cloudProvider: CloudProviderKind {
        get {
            access(keyPath: \.cloudProvider)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.cloudProvider),
                  let p = CloudProviderKind(rawValue: raw) else { return .assemblyAI }
            return p
        }
        set {
            withMutation(keyPath: \.cloudProvider) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.cloudProvider)
            }
        }
    }

    /// Whisper spoken-language code ("auto" = detect). Changing it needs no reload.
    var whisperLanguage: String {
        get {
            access(keyPath: \.whisperLanguage)
            return UserDefaults.standard.string(forKey: SettingsKeys.whisperLanguage) ?? "auto"
        }
        set {
            withMutation(keyPath: \.whisperLanguage) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.whisperLanguage)
            }
            whisperEngine.setLanguage(newValue)
        }
    }

    /// When on, normal dictation transcribes via Whisper in `whisperLanguage` and
    /// pastes polished English (translate + normalize + your active style, one
    /// backend pass). Off by default. See the F4 design spec.
    var crossLingualEnabled: Bool {
        get {
            access(keyPath: \.crossLingualEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.crossLingualEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.crossLingualEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.crossLingualEnabled)
            }
        }
    }

    /// Human-readable name of the spoken language, for the cross-lingual prompt.
    private var spokenLanguageName: String {
        WhisperEngine.languageName(forCode: whisperLanguage)
    }

    /// Which overlay presentation to use. Bound by the "Recording overlay" picker;
    /// read into sessionOverlayStyle at dictation start. access/withMutation so the
    /// picker re-highlights on change.
    var overlayStyle: OverlayStyle {
        get {
            access(keyPath: \.overlayStyle)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.overlayStyle),
                  let style = OverlayStyle(rawValue: raw) else { return .full }
            return style
        }
        set {
            withMutation(keyPath: \.overlayStyle) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.overlayStyle)
            }
        }
    }

    // MARK: Core loop collaborators
    private let audioCapture = AudioCapture()
    private let appleEngine: TranscriptionEngine = AppleEngine()
    let parakeetEngine = ParakeetEngine()
    let whisperEngine = WhisperEngine()
    private var activeEngine: TranscriptionEngine {
        switch CrossLingual.engineKind(base: engineKind, crossLingual: crossLingualEnabled) {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: CloudEngine(provider: cloudProvider)   // stateless; built per session
        case .whisper: whisperEngine
        }
    }

    // Model-download UI state. Stored (so @Observable tracks them) and owned by
    // AppState, NOT the transient Settings view — so progress survives the view
    // being recreated when the user navigates between hub sections mid-download,
    // and the download Task keeps running regardless of what's on screen.
    var parakeetDownloadProgress: Double?
    var parakeetDownloadError: String?
    var whisperDownloadProgress: Double?
    var whisperDownloadError: String?

    func downloadParakeetModel() {
        guard parakeetDownloadProgress == nil else { return }   // already in flight
        parakeetDownloadError = nil
        parakeetDownloadProgress = 0
        Task {
            do {
                try await parakeetEngine.ensureModelsLoaded { progress in
                    Task { @MainActor in self.parakeetDownloadProgress = progress.fractionCompleted }
                }
                parakeetDownloadProgress = nil
            } catch {
                parakeetDownloadProgress = nil
                parakeetDownloadError = error.localizedDescription
            }
        }
    }

    func downloadWhisperModel() {
        guard whisperDownloadProgress == nil else { return }
        whisperDownloadError = nil
        whisperDownloadProgress = 0
        Task {
            do {
                try await whisperEngine.ensureModelLoaded { progress in
                    Task { @MainActor in self.whisperDownloadProgress = progress.fractionCompleted }
                }
                whisperDownloadProgress = nil
            } catch {
                whisperDownloadProgress = nil
                whisperDownloadError = error.localizedDescription
            }
        }
    }
    private let overlay = OverlayPanel()
    private var overlayPreviewTask: Task<Void, Never>?
    /// While a Preview demo runs, `audioLevel` returns this instead of the mic
    /// level, so the orb/bars look lively without real audio.
    private var previewAmplitude: Float?
    // @ObservationIgnored: hotkey is a collaborator, not observable UI state, and
    // @Observable can't instrument a `lazy` stored property (it rewrites stored
    // vars into computed ones). lazy is needed because the initializer captures self.
    @ObservationIgnored private lazy var hotkey = GlobalHotkey(
        keyCode: dictationShortcut.keyCode,
        modifiers: dictationShortcut.flags
    ) { [weak self] in
        self?.toggleDictation()
    }
    @ObservationIgnored private lazy var pushToTalk = PushToTalkMonitor(
        key: pttKey,
        onStart: { [weak self] in self?.beginPushToTalk() },
        onEnd: { [weak self] in self?.endPushToTalk() }
    )
    /// kVK_ANSI_B — Smart Dictation, always polishes with the active style.
    @ObservationIgnored private lazy var smartDictationHotkey = GlobalHotkey(
        keyCode: 11,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginSmartDictation()
    }
    /// kVK_ANSI_P — Polish Selected Text: copy the frontmost app's selection,
    /// polish it, paste it back in place. Not a dictation session — dictation
    /// stays .idle throughout; overlayPhase alone drives the brief pill.
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: 35,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginPolishSelectedText()
    }
    /// kVK_ANSI_D — Brain-dump mode: ramble, then structure into the active shape.
    @ObservationIgnored private lazy var brainDumpHotkey = GlobalHotkey(
        keyCode: 2,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginBrainDump()
    }
    @ObservationIgnored private let meetingWatcher = MeetingWatcher()
    @ObservationIgnored private let meetingRecorder = MeetingRecorder()
    @ObservationIgnored private let meetingConsentPanel = MeetingConsentPanel()
    @ObservationIgnored private var meetingStartedAt: Date?
    @ObservationIgnored private var meetingAppName: String?
    /// True whenever a meeting is being recorded — auto-detected OR manual.
    /// Observable (not @ObservationIgnored) so the hub button and mini-panel row
    /// reflect it. Flipped only in beginRecording/endRecording.
    private(set) var isRecordingMeeting = false
    @ObservationIgnored private let replyAssistMonitor = ReplyAssistMonitor()
    @ObservationIgnored private let replyStreamTypist = ReplyStreamTypist()
    @ObservationIgnored private var isReplyAssistDrafting = false
    @ObservationIgnored private let memoryCapture = MemoryCapture()
    @ObservationIgnored private let chronicleScheduler = ChronicleScheduler()

    /// Consumes the engine's event stream and applies it to `volatileTranscript`/
    /// `finalizedTranscript`. Awaited on stop so paste happens after the last
    /// final result, not before.
    private var transcriptionTask: Task<Void, Never>?

    /// Set when Fn is released while still in .starting (permissions/capture setup in
    /// flight) — startDictation() checks this the instant it reaches .recording and
    /// immediately stops, so a quick tap-and-release doesn't get stuck recording.
    private var stopRequestedWhilePTTStarting = false

    /// PTT keydown time — set only by beginPushToTalk(), cleared on toggle-start
    /// (toggle has no "hold" concept) and after each session ends. Used to compute
    /// hold duration for the short-hold-cancel check in `exitPhase`.
    private var pttPressedAt: ContinuousClock.Instant?

    /// Set right after audioCapture.start() succeeds; read at stop to compute the
    /// session duration recorded in history, and to time the start-to-first-partial
    /// latency log. Cleared at the end of every stopDictation().
    private(set) var recordingStartedAt: ContinuousClock.Instant?

    /// Fired the instant dictation=.starting is claimed (S2 context-aware
    /// dictation), concurrently with permission checks/audioCapture.start() so
    /// the AX read doesn't add latency on top of work already happening. Awaited
    /// once, right before engine.transcribe(). nil when the feature is off.
    private var contextCaptureTask: Task<[String], Never>?

    private let systemLLM = SystemLLM()

    /// Set at the start of a session in beginSmartDictation()/toggleDictation(),
    /// read in stopDictation() to decide whether to run polish before pasting.
    /// Reset alongside the other per-session flags at the end of stopDictation().
    /// The current dictation session's mode — drives what stopDictation does with
    /// the text and what the overlay renders. private(set) so the overlay observes it.
    private(set) var sessionMode: SessionMode = .normal
    /// S2 salient screen terms captured at session start, reused by brain-dump's
    /// structuring prompt (they already bias the engine at capture time).
    private var sessionScreenTerms: [String] = []

    /// Per-app-launch, not persisted — the Foundation-Models-unavailable nudge
    /// (errorMessage) only needs to fire once per run, not every polish attempt.
    private var didNudgeFoundationModelsUnavailable = false
    private var didNudgeCrossLingualEngine = false

    /// nil if the DB failed to open — history then becomes a silent no-op rather
    /// than crashing the app (matches the project's "engine error -> toast, not
    /// crash" principle). HistoryView reads/writes through this directly rather
    /// than AppState proxying every HistoryStore method.
    private(set) var historyStore: HistoryStore?

    /// nil if the DB failed to open — memory capture then becomes a silent
    /// no-op, matching historyStore's own principle.
    private(set) var memoryStore: MemoryStore?
    private(set) var meetingStore: MeetingStore?

    var hasAccessibilityPermission: Bool {
        PasteService.hasAccessibilityPermission()
    }

    /// Mic input level (0–1), for the overlay's voice-reactive orb. Safe to read
    /// every render-loop tick — AudioCapture isn't @Observable, so this registers
    /// no Observation dependency and can't trigger invalidation storms.
    var audioLevel: Float {
        if let previewAmplitude { return previewAmplitude }
        return audioCapture.level
    }

    init() {
        guard !isRunningUnderTests else {
            historyStore = nil
            memoryStore = nil
            meetingStore = nil
            return
        }

        // Open the stores FIRST. The feature-enable wiring further down (the
        // meetings / reply-assist / memory setters) assigns these stores into
        // their collaborators -- e.g. `memoryCapture.store = memoryStore`. This
        // used to run BEFORE the stores were opened, so it captured nil and the
        // capture daemon silently never wrote anything: the real cause of
        // "memory records nothing after launch". It only worked when the user
        // toggled the feature on at runtime (store already open, post-init).
        let appSupportDir = AppSupportDirectory.resolve()

        do {
            guard let appSupportDir else { throw CocoaError(.fileNoSuchFile) }
            historyStore = try .open(atPath: appSupportDir.appendingPathComponent("history.db").path)
        } catch {
            log.error("init — HistoryStore failed to open: \(error)")
            historyStore = nil
        }
        if let historyStore {
            runHistoryStartupTasks(store: historyStore, autoDeleteAfterDays: autoDeleteAfterDays)
        }

        // Separate database from HistoryStore (own file, own DatabaseQueue) --
        // memory (background screen capture) and dictation history are
        // differently-sensitive data with different default-on/off states; a
        // user must be able to wipe one without touching the other. Opened
        // independently of historyStore -- one failing to open must not
        // affect the other.
        do {
            guard let appSupportDir else { throw CocoaError(.fileNoSuchFile) }
            memoryStore = try .open(atPath: appSupportDir.appendingPathComponent("memory.db").path)
        } catch {
            log.error("init — MemoryStore failed to open: \(error)")
            memoryStore = nil
        }

        // Separate database from history/memory -- recorded meetings are their own
        // sensitivity class, wiped independently. Opened independently.
        do {
            guard let appSupportDir else { throw CocoaError(.fileNoSuchFile) }
            meetingStore = try .open(atPath: appSupportDir.appendingPathComponent("meetings.db").path)
        } catch {
            log.error("init — MeetingStore failed to open: \(error)")
            meetingStore = nil
        }

        // Stores are open now -- start input monitors and re-run the enable
        // setters, which wire the (now non-nil) stores into their daemons.
        hotkey.start()
        pushToTalk.start()
        smartDictationHotkey.start()
        brainDumpHotkey.start()
        polishSelectedTextHotkey.start()
        parakeetEngine.setModel(parakeetModel)  // engine defaults to .v3; honor the persisted choice
        whisperEngine.setModel(whisperModel)     // engine defaults to turbo; honor the persisted choice
        whisperEngine.setLanguage(whisperLanguage)
        if meetingsEnabled { meetingsEnabled = true }  // re-runs the setter's wiring/start path
        if replyAssistEnabled { replyAssistEnabled = true }  // re-runs the setter's wiring/start path
        if memoryEnabled { memoryEnabled = true }  // re-runs the setter's wiring/start path
        if !PasteService.hasAccessibilityPermission() {
            PasteService.requestAccessibilityPrompt()
        }
    }

    /// nonisolated so the Task it spawns runs on the cooperative thread pool, not
    /// MainActor — see AppState concurrency note in CLAUDE.md. Runs the legacy
    /// importer, then auto-delete cleanup; both are fire-and-forget, errors logged.
    nonisolated private func runHistoryStartupTasks(store: HistoryStore, autoDeleteAfterDays: Int?) {
        Task {
            LegacyHistoryImporter.importIfNeeded(into: store)
            guard let autoDeleteAfterDays else { return }
            do {
                try store.deleteOlderThan(days: autoDeleteAfterDays)
            } catch {
                log.error("startup cleanup — deleteOlderThan failed: \(error)")
            }
        }
    }

    /// nonisolated so the Task it creates runs on the cooperative thread pool —
    /// same rationale as runHistoryStartupTasks. `enabled` is a plain Bool
    /// parameter rather than reading contextAwareDictationEnabled inside the
    /// nonisolated body, because that property is MainActor-isolated and can't
    /// be read from here directly (same reason vocabSnapshot/replacementsSnapshot/
    /// fuzzySnapshot are read on MainActor and passed by value into
    /// startDictation()'s transcription Task).
    nonisolated private func startContextCapture(enabled: Bool) -> Task<[String], Never>? {
        guard enabled else { return nil }
        return Task {
            guard let text = ScreenContextReader.captureFrontmostWindowText() else { return [] }
            return await SalientTermExtractor.extractSalientTerms(from: text)
        }
    }

    // MARK: Actions

    func toggleDictation() {
        toggleOrStop(mode: .normal)
    }

    /// Cmd+Shift+B — identical to toggleDictation() except it flags the session
    /// as smart, so stopDictation() runs the active polish style before pasting.
    /// Toggle-style, like Cmd+Shift+V — no separate PTT variant for this one.
    func beginSmartDictation() {
        toggleOrStop(mode: .smart)
    }

    /// ⌘⇧D — capture a long ramble, then structure it into the active brain-dump
    /// shape on stop. Toggle-style, like ⌘⇧V/⌘⇧B.
    func beginBrainDump() {
        toggleOrStop(mode: .brainDump)
    }

    private func toggleOrStop(mode: SessionMode) {
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            overlayPreviewTask?.cancel()   // a settings Preview must not clobber a real session
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            sessionMode = mode
            dictation = .starting
            sessionOverlayStyle = overlayStyle
            overlay.show(appState: self)   // instant — warming look, before any permission/capture work
            contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .starting, .finalizing:
            break   // ignore toggles while a transition is in flight
        }
    }

    // MARK: Push-to-talk

    func beginPushToTalk() {
        // Ignore if already toggled-on via Cmd+Shift+V, or mid-transition — same
        // one-attempt-in-flight discipline as toggleDictation's .idle case.
        guard dictation == .idle else { return }
        overlayPreviewTask?.cancel()   // a settings Preview must not clobber a real session
        stopRequestedWhilePTTStarting = false
        pttPressedAt = .now
        sessionMode = .normal   // PTT is always normal dictation — never inherit a stale mode
        dictation = .starting
        sessionOverlayStyle = overlayStyle
        overlay.show(appState: self)   // instant — warming look, before any permission/capture work
        contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
        Task { await startDictation() }
    }

    func endPushToTalk() {
        switch dictation {
        case .starting:
            stopRequestedWhilePTTStarting = true
        case .recording:
            Task { await stopDictation() }
        case .idle, .finalizing:
            break   // stray release with no matching press (e.g. focus changed mid-hold) — no-op
        }
    }

    /// Cmd+Shift+P. Guarded on dictation == .idle so this can't fire mid-session
    /// and race the dictation state machine — press it while dictating and it's
    /// simply ignored. Nothing is selected -> silent no-op (no overlay, no paste).
    func beginPolishSelectedText() {
        guard dictation == .idle else { return }
        Task { await runPolishSelectedText() }
    }

    private func runPolishSelectedText() async {
        guard let original = await PasteService.copySelection() else { return }
        overlayPhase = .polishing
        overlay.show(appState: self)
        let result = await polishedText(for: original)
        overlay.hide()
        overlayPhase = .none
        PasteService.paste(result)
    }

    /// Play a one-off canned demo of `style` in the real HUD so the settings
    /// picker's choice is visible without starting a real dictation. Guarded on
    /// idle; never touches `dictation`, so no history/paste/sounds/menu-icon
    /// side effects. A second call cancels the in-flight demo first.
    func previewOverlay(_ style: OverlayStyle) {
        guard dictation == .idle else { return }
        overlayPreviewTask?.cancel()
        overlayPreviewTask = Task { await runOverlayPreview(style) }
    }

    private func runOverlayPreview(_ style: OverlayStyle) async {
        sessionOverlayStyle = style
        overlayPreview = style
        overlayPhase = .none
        finalizedTranscript = ""
        volatileTranscript = ""
        previewAmplitude = 0.12
        overlay.show(appState: self)
        do {
            try await Task.sleep(for: .milliseconds(450))         // warming beat
            previewAmplitude = 0.5                                 // "listening" liveliness
            finalizedTranscript = "The overlay should match how much attention you want to give it."
            try await Task.sleep(for: .milliseconds(1500))         // listening w/ sample text
            overlayPhase = .pasting                                // finalize beat
            previewAmplitude = 0.12
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            // Cancelled by a second Preview press — fall through to cleanup.
        }
        // If a real dictation started during the demo, it now owns the overlay —
        // abandon quietly (clear only preview-owned state), never hide it or wipe
        // its transcript.
        guard dictation == .idle else {
            overlayPreview = nil
            previewAmplitude = nil
            return
        }
        overlay.hide()
        overlayPhase = .none
        overlayPreview = nil
        previewAmplitude = nil
        finalizedTranscript = ""
        volatileTranscript = ""
    }

    func startDictation() async {
        // Caller (toggleDictation) claimed .starting synchronously; this guard
        // rejects direct calls made from any other state.
        guard dictation == .starting else {
            log.warning("startDictation — aborted (state=\(String(describing: self.dictation)))")
            return
        }
        errorMessage = nil

        guard await requestMicrophonePermission() else {
            errorMessage = "OmWhisper needs microphone access. Enable it in System Settings > Privacy & Security > Microphone."
            overlay.hide()   // early-show already put a warming pill on screen — must tear it down too
            dictation = .idle
            return
        }

        guard await requestSpeechPermission() else {
            errorMessage = "OmWhisper needs Speech Recognition access. Enable it in System Settings > Privacy & Security > Speech Recognition."
            overlay.hide()
            dictation = .idle
            return
        }

        finalizedTranscript = ""
        volatileTranscript = ""

        do {
            let audioStream = try audioCapture.start(preferredDeviceUID: audioInputDeviceUID)
            dictation = .recording
            if soundEnabled { SoundPlayer.play(.start, volume: Float(soundVolume)) }
            // overlay already shown in toggleDictation()/beginPushToTalk() (early-show,
            // before permissions/capture even start) — nothing to do here.

            recordingStartedAt = ContinuousClock.now
            var loggedFirstPartial = false

            // Snapshot once per session — read fresh at the moment this specific
            // dictation starts, not re-read per streamed partial.
            let vocabSnapshot = customVocabulary
            let replacementsSnapshot = wordReplacements
            let fuzzySnapshot = fuzzyVocabCorrection

            // Screen-extracted terms (S2) feed engine biasing only — never
            // vocabSnapshot itself, which also doubles as fuzzyCorrect's
            // post-hoc snap-to-nearest-term dictionary below. Mixing noisy
            // auto-extracted terms into that harder rewrite is a different
            // risk profile than soft engine biasing. Cloud excludes screen
            // terms entirely -- see mergeEngineVocabulary.
            let screenTerms = await contextCaptureTask?.value ?? []
            sessionScreenTerms = screenTerms
            let effectiveEngineKind = CrossLingual.engineKind(base: engineKind, crossLingual: crossLingualEnabled)
            let engineVocabulary = mergeEngineVocabulary(
                customTerms: vocabSnapshot,
                screenTerms: screenTerms,
                engineKind: effectiveEngineKind
            )
            if effectiveEngineKind == .cloud, !screenTerms.isEmpty {
                log.debug("cloud engine active: excluding \(screenTerms.count) screen term(s) from vocabulary")
            }
            // Cross-lingual: nudge once if we're overriding the user's engine, and
            // pick Whisper's in-engine translate only when there's no polish backend.
            if crossLingualEnabled, engineKind != .whisper, !didNudgeCrossLingualEngine {
                didNudgeCrossLingualEngine = true
                errorMessage = "Cross-lingual dictation uses the Whisper engine."
            }
            whisperEngine.setTranslateToEnglish(
                CrossLingual.whisperTranslatesInEngine(crossLingual: crossLingualEnabled, hasBackend: activePolishBackend() != nil)
            )

            let events = activeEngine.transcribe(audioStream, vocabulary: engineVocabulary)
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                func postProcess(_ text: String) -> String {
                    var result = applyReplacements(text, rules: replacementsSnapshot)
                    if fuzzySnapshot {
                        result = fuzzyCorrect(result, dictionary: vocabSnapshot)
                    }
                    return result
                }
                do {
                    for try await event in events {
                        switch event {
                        case .partial(let text):
                            if !loggedFirstPartial, let recordingStartedAt = self.recordingStartedAt {
                                loggedFirstPartial = true
                                latencyLog.info("start-to-first-partial: \(recordingStartedAt.duration(to: .now))")
                            }
                            self.volatileTranscript = postProcess(text)
                        case .final(let text):
                            self.finalizedTranscript += postProcess(text)
                            self.volatileTranscript = ""
                        }
                    }
                } catch {
                    log.error("transcriptionTask — engine error: \(error)")
                    self.errorMessage = error.localizedDescription
                }
            }

            if stopRequestedWhilePTTStarting {
                stopRequestedWhilePTTStarting = false
                Task { await stopDictation() }
            }
        } catch {
            log.error("startDictation — audio capture failed: \(error)")
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            dictation = .idle
            overlay.hide()
        }
    }

    func stopDictation() async {
        guard dictation == .recording else {
            log.warning("stopDictation — aborted (state=\(String(describing: self.dictation)))")
            return
        }
        let heldFor: Duration? = pttPressedAt.map { $0.duration(to: .now) }
        let stopRequestedAt = ContinuousClock.now
        // Stay .finalizing through the whole exit flourish (see finishOverlayExit) —
        // the overlay is mount-gated on `dictation != .idle`, so flipping to .idle
        // instantly would unmount the orb with nothing left to animate.
        dictation = .finalizing

        audioCapture.stop()
        await transcriptionTask?.value
        transcriptionTask = nil

        var text = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // errorMessage is nil'd at the top of every startDictation() and only the
        // transcriptionTask's catch block sets it during a session — so non-nil
        // here means the engine genuinely threw, not just "recording was silent."
        let hadEngineError = errorMessage != nil
        let phase = Self.exitPhase(heldFor: heldFor, text: text, hadPartial: hadEngineError)
        overlayPhase = phase

        if phase != .cancelled, soundEnabled {
            SoundPlayer.play(.stop, volume: Float(soundVolume))
        }

        if phase == .pasting {
            switch sessionMode {
            case .smart where !Self.tooShortForPolish(text):
                overlayPhase = .polishing
                text = await polishedText(for: text)
                overlayPhase = phase
            case .brainDump:
                overlayPhase = .polishing
                text = await brainDumpStructured(for: text)
                overlayPhase = phase
            default:
                break
            }
        }

        if phase == .pasting, pasteAfterStop, !onboardingDemoActive {
            if PasteService.hasAccessibilityPermission() {
                PasteService.paste(text)
                latencyLog.info("stop-to-paste: \(stopRequestedAt.duration(to: .now))")
            } else {
                // paste() is what normally puts text on the pasteboard; since we're
                // skipping it here (no Accessibility to post Cmd+V), copy directly
                // so "Text copied" in the message below is actually true.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                errorMessage = "Text copied — grant Accessibility to auto-paste."
            }
        }

        // Recorded independent of pasteAfterStop — history isn't tied to auto-paste,
        // only to "did this session actually produce real text" (phase == .pasting).
        // Skipped during onboarding's demo — the try-it run must not pollute history.
        if phase == .pasting, !onboardingDemoActive {
            let durationSeconds = recordingStartedAt.map { $0.duration(to: .now).seconds } ?? 0
            do {
                try historyStore?.record(text: text, duration: durationSeconds, modelUsed: "Apple SpeechTranscriber")
            } catch {
                log.error("stopDictation — history record failed: \(error)")
            }
        }

        pttPressedAt = nil
        recordingStartedAt = nil
        contextCaptureTask = nil
        sessionMode = .normal
        onboardingDemoActive = false   // demo bracket ends with the session (set on .recording in TryItStep)
        await finishOverlayExit(exitDuration(for: phase))
    }

    // MARK: Reply assist (S4)

    /// Changed after live verification, per explicit user direction: no panel,
    /// no type/blank/speak choice -- double-tap right ⌥ silently auto-drafts
    /// from context and streams straight into the field. Since nothing shows
    /// any OmWhisper UI here, nothing calls NSApp.activate() and the target
    /// app never loses focus -- unlike the original panel-based flow, no
    /// focus-restore workaround is needed.
    func beginReplyAssist() async {
        guard dictation == .idle else { return }  // ReplyAssistMonitor already suppresses this, but stay defensive
        // A double-tap while a draft is already in flight cancels it instead of
        // starting a second one. Claim the flag BEFORE the awaits below (field
        // resolution can take ~1.6s for slow Electron trees): each trigger is
        // its own unserialized Task, so if the flag were set only after those
        // awaits, a fast second double-tap would slip past this guard and start
        // a second concurrent draft that interleaves keystrokes with the first.
        // `defer` clears it on every exit path.
        guard !isReplyAssistDrafting else {
            replyStreamTypist.cancel()
            return
        }
        isReplyAssistDrafting = true
        defer { isReplyAssistDrafting = false }

        // Fire-and-forget: regenerate the writing-tone profile from recent
        // dictation history (on-device only) so later drafts sound like the
        // user. Self-skips when tone.md is fresh or Foundation Models is off;
        // never blocks this draft.
        refreshToneProfileIfStale()

        // The app the user was in when they double-tapped -- the draft must land
        // in THIS app, not wherever focus drifts during the multi-second draft.
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let context = await ReplyContextReader.currentContext() else {
            errorMessage = "Reply assist: couldn't read the focused field."
            return
        }
        let windowContext = ScreenContextReader.captureFrontmostWindowText()
        await draftAndStream(mode: context.mode, intent: "", windowContext: windowContext, targetPID: targetPID)
    }

    private func draftAndStream(mode: ReplyMode, intent: String, windowContext: String?, targetPID: pid_t?) async {
        let tonePrefix = (try? String(contentsOf: ToneProfile.toneFileURL(), encoding: .utf8))
            .map { ToneProfile.promptPrefix(from: $0) }
        let style = Self.draftStyle(mode: mode, windowContext: windowContext, tonePrefix: tonePrefix)
        guard let backend = activePolishBackend() else {
            errorMessage = "Reply assist needs an AI polish backend enabled in AI settings."
            return
        }
        let drafted: String
        do {
            drafted = try await backend.polish(intent, style: style, targetLanguage: nil)
        } catch {
            log.error("draftAndStream — polish failed: \(error)")
            errorMessage = "Reply assist: draft failed (\(error.localizedDescription))."
            return
        }
        // Focus may have moved during the (up to 5s/30s) draft. Only type if the
        // app the user triggered from is still frontmost -- keystrokes post to
        // whatever app is frontmost at type time, so a drifted focus would land
        // the reply in the wrong field.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            log.warning("draftAndStream — frontmost app changed before typing; aborting")
            errorMessage = "Reply assist: focus changed, nothing was typed."
            return
        }
        let result = await replyStreamTypist.stream(drafted)
        if case .declinedSentinel(let sentinel) = result {
            log.warning("draftAndStream — declined on sentinel: \(sentinel)")
            errorMessage = "Reply assist: the draft looked like an error, nothing was typed."
        }
    }

    /// ScreenContextReader.captureFrontmostWindowText() can return up to
    /// 50,000 characters -- fine for S2's local vocabulary extraction, but
    /// including that much raw text in an LLM prompt caused SystemLLM's 5s
    /// timeout to trip on every draft (confirmed live: "Polish timed out"
    /// against a text-heavy markdown file in the background window). The
    /// AX-read draft/selection text is just as uncapped -- if the focused
    /// "field" is a full document editor, its AX value can be the entire
    /// document. Both are capped here for the same reason.
    private static let windowContextCap = 2_000
    private static let fieldTextCap = 2_000

    private static func draftStyle(mode: ReplyMode, windowContext: String?, tonePrefix: String?) -> PolishStyle {
        var instructions = "You draft a reply/message for the user, writing AS the user in first person. Respond with ONLY the drafted text -- no preamble, no quotes, no explanation.\n\n"
        switch mode {
        case .reply:
            instructions += "Draft a new reply appropriate to the conversation context below.\n"
        case .continueDraft(let draft):
            // suffix, not prefix -- continuing a draft cares about its most
            // recent tail, not however it started.
            instructions += "Continue this unfinished draft naturally, in the same voice:\n\(draft.suffix(fieldTextCap))\n"
        case .rewrite(let selection):
            instructions += "Rewrite this selected text, keeping its meaning:\n\(selection.prefix(fieldTextCap))\n"
        }
        if let windowContext {
            // suffix, not prefix -- the window is scraped top-down, so in a chat
            // the newest message (what you're replying to) is at the BOTTOM.
            // Keeping the head fed the model the oldest/scrollback content and
            // truncated away the live message. Tail is right for the dominant
            // chat case; top-posted email threads are the minority we trade off.
            instructions += "\nOn-screen context:\n\(windowContext.suffix(windowContextCap))\n"
        }
        if let tonePrefix { instructions += "\nWriting tone to match:\n\(tonePrefix)\n" }
        return PolishStyle(
            id: UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FB")!,
            name: "Reply Draft",
            prompt: instructions,
            isBuiltIn: true
        )
    }

    /// Fixed-UUID internal style for tone distillation -- never shown in the AI
    /// tab picker, same hidden-style pattern as the reply-draft / chronicle styles.
    private static let toneDistillStyle = PolishStyle(
        id: UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FC")!,
        name: "Tone Distillation",
        prompt: ToneProfile.distillationPrompt,
        isBuiltIn: true
    )

    /// Regenerates tone.md from recent dictation history when it's missing or
    /// >7 days old, so Reply Assist drafts sound like the user (this was the
    /// unimplemented "Task 6" -- until now tone.md was never written and every
    /// draft came out in the model's generic voice). On-device ONLY: distillation
    /// reads the user's whole recent history, so it always uses SystemLLM
    /// regardless of the chosen polish backend -- history never egresses just to
    /// build a tone profile. If Foundation Models is unavailable, drafts stay
    /// generic (unchanged from before). Fire-and-forget; never blocks a draft.
    func refreshToneProfileIfStale() {
        guard SystemLLM.isAvailable(), let historyStore else { return }
        if let url = try? ToneProfile.toneFileURL(),
           let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 7 * 86_400 {
            return   // still fresh
        }
        guard let entries = try? historyStore.fetchPage(offset: 0, limit: ToneProfile.sampleCap),
              !entries.isEmpty else { return }
        let digest = ToneProfile.buildDigest(from: entries)
        guard !digest.isEmpty else { return }
        let llm = systemLLM
        Task {
            guard let tone = try? await llm.polish(digest, style: Self.toneDistillStyle, targetLanguage: nil),
                  !tone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = try? ToneProfile.toneFileURL() else { return }
            try? tone.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Runs the active style through the current backend; returns `original`
    /// unconditionally on any failure (backend Disabled, Foundation Models
    /// unavailable, model error, timeout) — dictated/selected text must never
    /// be silently dropped. Shows the one-time-per-launch Settings nudge
    /// specifically when the cause is Foundation Models being unavailable.
    /// The polish backend the user has configured, or nil when polish shouldn't
    /// run (Disabled, System-but-unavailable, or Ollama with no model chosen).
    /// The single place backend selection happens — both dictation polish and
    /// Reply Assist route through it.
    func activePolishBackend() -> PolishBackend? {
        switch polishBackend {
        case .disabled: return nil
        case .system: return SystemLLM.isAvailable() ? systemLLM : nil
        case .ollama: return ollamaModel.isEmpty ? nil : Ollama(baseURL: ollamaBaseURL, model: ollamaModel)
        case .cloud:
            guard let key = Keychain.loadCloudLLMKey(), !key.isEmpty else { return nil }
            return CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key)
        }
    }

    private func polishedText(for original: String) async -> String {
        // The one-time nudge fires only when System is selected but off — not for
        // Disabled or an unconfigured Ollama, which are deliberate "no polish" states.
        if polishBackend == .system, !SystemLLM.isAvailable() {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to use polish, or pasted raw text for now."
            }
            return original
        }
        guard let backend = activePolishBackend() else { return original }
        let style: PolishStyle
        let target: String?
        if crossLingualEnabled {
            // original is the source-language transcript (backend present → we run
            // the LLM translate here) — or already English if Whisper's .translate
            // fallback ran, in which case a second polish pass is harmless cleanup.
            style = CrossLingual.style(spokenLanguage: spokenLanguageName, activeStyle: activePolishStyle)
            target = nil
        } else {
            guard let active = activePolishStyle else { return original }
            style = active
            target = active.requiresTargetLanguage ? translateTargetLanguage : nil
        }
        do {
            return try await backend.polish(original, style: style, targetLanguage: target)
        } catch {
            log.error("polishedText — polish failed: \(error)")
            return original
        }
    }

    /// Structure a brain-dump ramble into the active shape via the active backend,
    /// grounded in the target app + captured screen terms. Any failure returns the
    /// raw ramble — words are never dropped (same rule as polishedText).
    private func brainDumpStructured(for original: String) async -> String {
        if polishBackend == .system, !SystemLLM.isAvailable() {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to structure brain-dumps, or pasted raw text for now."
            }
            return original
        }
        guard let backend = activePolishBackend(), let shape = activeBrainDumpShape else { return original }
        var parts: [String] = []
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { parts.append("Target app: \(app)") }
        if !sessionScreenTerms.isEmpty { parts.append("On-screen terms: \(sessionScreenTerms.prefix(20).joined(separator: ", "))") }
        let context = parts.isEmpty ? nil : parts.joined(separator: ". ")
        do {
            return try await BrainDumpStructurer.structure(transcript: original, shape: shape, context: context, polish: backend)
        } catch {
            log.error("brainDumpStructured — failed: \(error)")
            return original
        }
    }

    /// Re-runs a past history entry's text through the current polish
    /// backend/style. Callers copy the result to the clipboard -- this never
    /// pastes into the frontmost app the way live dictation's stop-and-paste
    /// does, since there's no "target app" context for a hub-window action.
    func rePolish(_ text: String) async -> String {
        await polishedText(for: text)
    }

    /// Pure decision: what the overlay's exit flourish should be. Evaluated
    /// *after* the transcript drains (not at key-release), so a quick-but-real
    /// utterance isn't wrongly cancelled. `heldFor` is nil for a toggle-stop
    /// (no hold concept — cancel is PTT-only, see OVERLAY_SPEC.md §9).
    nonisolated static func exitPhase(heldFor: Duration?, text: String, hadPartial: Bool) -> OverlayPhase {
        if let heldFor, heldFor < .milliseconds(500), text.isEmpty {
            return .cancelled
        }
        if text.isEmpty {
            return .error(label: hadPartial ? "SOMETHING BROKE — TEXT COPIED" : "NOTHING HEARD")
        }
        return .pasting
    }

    /// True means "skip polish, paste raw" — near-silent/hallucinated
    /// recordings aren't worth an LLM call. Matches the old app's guard.
    nonisolated static func tooShortForPolish(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count < 3
    }

    /// ponytail: fixed per-phase durations, not user-configurable — these are
    /// brand-motion timings from OVERLAY_SPEC.md §4, tune by eye if they ever
    /// feel off, no need for a settings knob.
    private func exitDuration(for phase: OverlayPhase) -> Duration {
        switch phase {
        case .pasting: .milliseconds(420)   // sized to contain the finalize pulse (§5.5); slide (§4) runs alongside
        case .error: .milliseconds(800)
        case .cancelled: .milliseconds(120)
        case .none, .polishing: .zero   // .polishing is transient mid-flight state, restored to phase before this is called
        }
    }

    /// Keeps `dictation == .finalizing` (and the orb mounted) for the exit
    /// flourish's duration, then tears everything down together. Paste already
    /// fired above, before this call — animation never delays it.
    private func finishOverlayExit(_ duration: Duration) async {
        if duration > .zero {
            try? await Task.sleep(for: duration)
        }
        overlay.hide()
        dictation = .idle
        overlayPhase = .none
    }

    // MARK: Permissions

    // nonisolated: these completion handlers can fire on an arbitrary background
    // queue (SFSpeechRecognizer's does, via a TCC XPC callback thread) rather than
    // MainActor — assuming MainActor here trips Swift 6's runtime isolation check
    // and crashes (see AppState.swift concurrency note in CLAUDE.md).
    nonisolated private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Public entry point for onboarding's permissions step. Requests mic then
    /// speech and returns both results for the ✓/denied display. Once granted,
    /// startDictation()'s own requests return immediately (no second prompt).
    func requestDictationPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await requestMicrophonePermission()
        let speech = await requestSpeechPermission()
        return (mic, speech)
    }
}

nonisolated extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

nonisolated enum PolishBackendKind: String, Codable, CaseIterable {
    case disabled, system, ollama, cloud
}

nonisolated enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

nonisolated enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let appearancePreference = "appearancePreference"
    static let polishBackend = "polishBackend"
    static let ollamaBaseURL = "ollamaBaseURL"
    static let ollamaModel = "ollamaModel"
    static let cloudAPIURL = "cloudAPIURL"
    static let cloudModel = "cloudModel"
    static let activePolishStyleID = "activePolishStyleID"
    static let translateTargetLanguage = "translateTargetLanguage"
    static let customPolishStyles = "customPolishStyles"
    static let activeBrainDumpShapeID = "activeBrainDumpShapeID"
    static let brainDumpShapes = "brainDumpShapes"
    static let dictationShortcut = "dictationShortcut"
    static let pttKey = "pttKey"
    static let soundEnabled = "soundEnabled"
    static let soundVolume = "soundVolume"
    static let audioInputDeviceUID = "audioInputDeviceUID"
    static let customVocabulary = "customVocabulary"
    static let wordReplacements = "wordReplacements"
    static let fuzzyVocabCorrection = "fuzzyVocabCorrection"
    static let contextAwareDictationEnabled = "contextAwareDictationEnabled"
    static let hasImportedLegacyHistory = "hasImportedLegacyHistory"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let meetingsEnabled = "meetingsEnabled"
    static let replyAssistEnabled = "replyAssistEnabled"
    static let memoryEnabled = "memoryEnabled"
    static let memoryPaused = "memoryPaused"
    static let memoryRetentionDays = "memoryRetentionDays"
    static let memoryExcludedDomains = "memoryExcludedDomains"
    static let autoDeleteAfterDays = "autoDeleteAfterDays"
    static let mcpAccessEnabled = "mcpAccessEnabled"
    static let engineKind = "engineKind"
    static let parakeetModel = "parakeetModel"
    static let whisperModel = "whisperModel"
    static let whisperLanguage = "whisperLanguage"
    static let crossLingualEnabled = "crossLingualEnabled"
    static let cloudProvider = "cloudProvider"
    static let overlayStyle = "overlayStyle"
}
