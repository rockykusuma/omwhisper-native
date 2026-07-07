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
import Foundation
import Observation
import os
import ScreenCaptureKit
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

    // MARK: Settings (persisted; keep keys stable — see SettingsKeys)
    var pasteAfterStop: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.pasteAfterStop) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.pasteAfterStop) }
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
        get { UserDefaults.standard.string(forKey: SettingsKeys.audioInputDeviceUID) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.audioInputDeviceUID) }
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
    /// Off by default — every Smriti-derived feature in this project ships off
    /// by default. Reads the frontmost window's visible text at dictation start
    /// to bias engine vocabulary; nothing is stored. See S2 design spec.
    var contextAwareDictationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.contextAwareDictationEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.contextAwareDictationEnabled) }
    }
    /// SMAppService is itself the source of truth (macOS's login-item registry) —
    /// unlike the other settings above, nothing is mirrored into UserDefaults.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
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
                    Task {
                        do {
                            try await self?.meetingRecorder.start(appName: appName)
                        } catch let error as SCStreamError where error.code == .userDeclined {
                            log.error("meeting recording failed to start: Screen Recording not granted")
                            self?.errorMessage = "Grant Screen Recording for OmWhisper in System Settings, then relaunch to record meetings."
                            self?.meetingWatcher.failedToStartRecording()
                        } catch {
                            log.error("meeting recording failed to start: \(error)")
                            self?.meetingWatcher.failedToStartRecording()
                        }
                    }
                }
                meetingWatcher.onStopRecording = { [weak self] in
                    Task { await self?.meetingRecorder.stop() }
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

    // MARK: Core loop collaborators
    private let audioCapture = AudioCapture()
    private let engine: TranscriptionEngine = AppleEngine()
    private let overlay = OverlayPanel()
    // @ObservationIgnored: hotkey is a collaborator, not observable UI state, and
    // @Observable can't instrument a `lazy` stored property (it rewrites stored
    // vars into computed ones). lazy is needed because the initializer captures self.
    @ObservationIgnored private lazy var hotkey = GlobalHotkey(
        keyCode: GlobalHotkey.vKeyCode,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.toggleDictation()
    }
    @ObservationIgnored private lazy var pushToTalk = PushToTalkMonitor(
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
    @ObservationIgnored private let meetingWatcher = MeetingWatcher()
    @ObservationIgnored private let meetingRecorder = MeetingRecorder()
    @ObservationIgnored private let meetingConsentPanel = MeetingConsentPanel()

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
    private var recordingStartedAt: ContinuousClock.Instant?

    /// Fired the instant dictation=.starting is claimed (S2 context-aware
    /// dictation), concurrently with permission checks/audioCapture.start() so
    /// the AX read doesn't add latency on top of work already happening. Awaited
    /// once, right before engine.transcribe(). nil when the feature is off.
    private var contextCaptureTask: Task<[String], Never>?

    private let systemLLM = SystemLLM()

    /// Set at the start of a session in beginSmartDictation()/toggleDictation(),
    /// read in stopDictation() to decide whether to run polish before pasting.
    /// Reset alongside the other per-session flags at the end of stopDictation().
    private var isSmartDictationSession = false

    /// Per-app-launch, not persisted — the Foundation-Models-unavailable nudge
    /// (errorMessage) only needs to fire once per run, not every polish attempt.
    private var didNudgeFoundationModelsUnavailable = false

    /// nil if the DB failed to open — history then becomes a silent no-op rather
    /// than crashing the app (matches the project's "engine error -> toast, not
    /// crash" principle). HistoryView reads/writes through this directly rather
    /// than AppState proxying every HistoryStore method.
    private(set) var historyStore: HistoryStore?

    var hasAccessibilityPermission: Bool {
        PasteService.hasAccessibilityPermission()
    }

    /// Mic input level (0–1), for the overlay's voice-reactive orb. Safe to read
    /// every render-loop tick — AudioCapture isn't @Observable, so this registers
    /// no Observation dependency and can't trigger invalidation storms.
    var audioLevel: Float {
        audioCapture.level
    }

    init() {
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
            smartDictationHotkey.start()
            polishSelectedTextHotkey.start()
            if meetingsEnabled { meetingsEnabled = true }  // re-runs the setter's wiring/start path
            if !PasteService.hasAccessibilityPermission() {
                PasteService.requestAccessibilityPrompt()
            }
        }

        guard !isRunningUnderTests else {
            historyStore = nil
            return
        }

        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("com.omwhisper.mac", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            historyStore = try .open(atPath: dir.appendingPathComponent("history.db").path)
        } catch {
            log.error("init — HistoryStore failed to open: \(error)")
            historyStore = nil
        }
        if let historyStore {
            runHistoryStartupTasks(store: historyStore, autoDeleteAfterDays: autoDeleteAfterDays)
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
        toggleOrStop(smart: false)
    }

    /// Cmd+Shift+B — identical to toggleDictation() except it flags the session
    /// as smart, so stopDictation() runs the active polish style before pasting.
    /// Toggle-style, like Cmd+Shift+V — no separate PTT variant for this one.
    func beginSmartDictation() {
        toggleOrStop(smart: true)
    }

    private func toggleOrStop(smart: Bool) {
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            isSmartDictationSession = smart
            dictation = .starting
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
        stopRequestedWhilePTTStarting = false
        pttPressedAt = .now
        dictation = .starting
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
            // risk profile than soft engine biasing.
            let screenTerms = await contextCaptureTask?.value ?? []
            let engineVocabulary = vocabSnapshot + screenTerms.filter { term in
                !vocabSnapshot.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            }

            let events = engine.transcribe(audioStream, vocabulary: engineVocabulary)
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

        if phase == .pasting, isSmartDictationSession, !Self.tooShortForPolish(text) {
            overlayPhase = .polishing
            text = await polishedText(for: text)
            overlayPhase = phase
        }

        if phase == .pasting, pasteAfterStop {
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
        if phase == .pasting {
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
        isSmartDictationSession = false
        await finishOverlayExit(exitDuration(for: phase))
    }

    /// Runs the active style through the current backend; returns `original`
    /// unconditionally on any failure (backend Disabled, Foundation Models
    /// unavailable, model error, timeout) — dictated/selected text must never
    /// be silently dropped. Shows the one-time-per-launch Settings nudge
    /// specifically when the cause is Foundation Models being unavailable.
    private func polishedText(for original: String) async -> String {
        guard polishBackend == .system, let style = activePolishStyle else { return original }
        guard SystemLLM.isAvailable() else {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to use polish, or pasted raw text for now."
            }
            return original
        }
        do {
            let target = style.requiresTargetLanguage ? translateTargetLanguage : nil
            return try await systemLLM.polish(original, style: style, targetLanguage: target)
        } catch {
            log.error("polishedText — polish failed: \(error)")
            return original
        }
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
}

nonisolated extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

nonisolated enum PolishBackendKind: String, Codable, CaseIterable {
    case disabled, system
    // Sub-project 2 adds: case ollama, cloud
}

nonisolated enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let polishBackend = "polishBackend"
    static let activePolishStyleID = "activePolishStyleID"
    static let translateTargetLanguage = "translateTargetLanguage"
    static let customPolishStyles = "customPolishStyles"
    static let soundEnabled = "soundEnabled"
    static let soundVolume = "soundVolume"
    static let audioInputDeviceUID = "audioInputDeviceUID"
    static let customVocabulary = "customVocabulary"
    static let wordReplacements = "wordReplacements"
    static let fuzzyVocabCorrection = "fuzzyVocabCorrection"
    static let contextAwareDictationEnabled = "contextAwareDictationEnabled"
    static let hasImportedLegacyHistory = "hasImportedLegacyHistory"
    static let meetingsEnabled = "meetingsEnabled"
    static let autoDeleteAfterDays = "autoDeleteAfterDays"
}
