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

/// True for Debug builds carrying the forked .dev bundle ID (see
/// docs/superpowers/specs/2026-08-01-dev-build-isolation-design.md). Gates
/// Sparkle: a dev build must never offer to replace itself from the live
/// appcast. Data/Keychain isolation need no gate — they key off the live
/// bundle ID directly.
nonisolated let isDevBuild = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")

/// The name this build shows the user — "OmWhisper-Dev" for the Debug fork,
/// "OmWhisper" for Release. Read from the bundle so in-app branding (sidebar,
/// hub window title) can never disagree with what Cmd-Tab and Finder show.
nonisolated let appDisplayName =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OmWhisper"

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
    case drafting                // Reply Assist composing a reply
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
    /// Put the user's previous clipboard contents back after pasting. Off means
    /// the dictated text simply stays on the clipboard.
    var restoreClipboard: Bool {
        get {
            access(keyPath: \.restoreClipboard)
            return UserDefaults.standard.object(forKey: SettingsKeys.restoreClipboard) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.restoreClipboard) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.restoreClipboard)
            }
        }
    }

    /// How long to wait before that restore. Slow targets — Electron apps, remote
    /// desktops, VMs — can still be reading the pasteboard when a 2s restore
    /// fires, and then they paste the user's OLD clipboard instead of the
    /// dictation. Clamped on read so a stale defaults value can't feed a negative
    /// duration into the paste path.
    var clipboardRestoreDelayMS: Int {
        get {
            access(keyPath: \.clipboardRestoreDelayMS)
            let value = UserDefaults.standard.object(forKey: SettingsKeys.clipboardRestoreDelayMS) as? Int
            return max(0, value ?? 2000)
        }
        set {
            withMutation(keyPath: \.clipboardRestoreDelayMS) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.clipboardRestoreDelayMS)
            }
        }
    }

    /// Single place the two paste sites read the clipboard settings from, so they
    /// can't drift apart.
    private func pasteRespectingClipboardSettings(_ text: String) {
        PasteService.paste(
            text,
            restoreClipboard: restoreClipboard,
            restoreDelay: .milliseconds(clipboardRestoreDelayMS))
    }

    var pasteAfterStop: Bool {
        get {
            access(keyPath: \.pasteAfterStop)
            return UserDefaults.standard.object(forKey: SettingsKeys.pasteAfterStop) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.pasteAfterStop) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.pasteAfterStop)
            }
        }
    }
    /// Hub/menu-bar-panel appearance. `.light` (default, R's call 2026-08-01 —
    /// the Porcelain look IS the app's face; a dark-mode Mac otherwise never
    /// sees it) — `.system`/`.dark` remain explicit choices in the picker.
    /// Drives the window's NSAppearance + SwiftUI colorScheme (see
    /// HubShellView). access/withMutation needed for the same reason as
    /// polishBackend — it backs a Picker that must re-highlight on change.
    var appearancePreference: AppearancePreference {
        get {
            access(keyPath: \.appearancePreference)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.appearancePreference) else { return .light }
            return AppearancePreference(rawValue: raw) ?? .light
        }
        set {
            withMutation(keyPath: \.appearancePreference) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.appearancePreference)
            }
        }
    }
    var soundEnabled: Bool {
        get {
            access(keyPath: \.soundEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.soundEnabled) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.soundEnabled)
            }
        }
    }
    /// Matches the old app's default (`sound_volume: 0.2`).
    var soundVolume: Double {
        get {
            access(keyPath: \.soundVolume)
            return UserDefaults.standard.object(forKey: SettingsKeys.soundVolume) as? Double ?? 0.2
        }
        set {
            withMutation(keyPath: \.soundVolume) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.soundVolume)
            }
        }
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
            access(keyPath: \.customVocabulary)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customVocabulary) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.customVocabulary) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customVocabulary)
            }
        }
    }
    var wordReplacements: [ReplacementRule] {
        get {
            access(keyPath: \.wordReplacements)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.wordReplacements) else { return [] }
            return (try? JSONDecoder().decode([ReplacementRule].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.wordReplacements) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.wordReplacements)
            }
        }
    }
    /// Defaults to ON since 2026-08-10, on measured evidence rather than taste.
    ///
    /// Engine biasing is inert on Apple Speech and Parakeet v2, so with this
    /// off the Vocabulary tab changed nothing at all on the default engine —
    /// a user could type `appcast`, dictate, and get "app cast" every time.
    /// The 2026-08-07 corpus run (docs/wer-corpus/README.md) measured the
    /// correction path instead of the raw engine for the first time: Apple
    /// 8.3% → 5.4%, Parakeet v2 8.3% → 2.4%, Whisper turbo 6.0% → 1.8%.
    ///
    /// Safe to flip because both correction stages are no-ops on an empty
    /// dictionary (pinned by tests), so this reaches only users who typed a
    /// vocabulary term — i.e. who asked for exactly this. `object(forKey:)`
    /// rather than `bool(forKey:)` means anyone who explicitly turned it OFF
    /// has `false` stored and keeps their choice.
    var fuzzyVocabCorrection: Bool {
        get {
            access(keyPath: \.fuzzyVocabCorrection)
            return UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.fuzzyVocabCorrection) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection)
            }
        }
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

    /// nil means the feature has no global shortcut — its hotkey is stopped,
    /// not merely reassigned somewhere unreachable. Dictation deliberately has
    /// no such option: an app with no way to dictate is broken, not configured.
    var smartDictationShortcut: KeyCombo? {
        get {
            access(keyPath: \.smartDictationShortcut)
            return Self.decodeShortcut(SettingsKeys.smartDictationShortcut,
                                       default: Self.defaultSmartDictation)
        }
        set {
            withMutation(keyPath: \.smartDictationShortcut) {
                Self.encodeShortcut(newValue, SettingsKeys.smartDictationShortcut)
            }
            Self.apply(newValue, to: smartDictationHotkey)
        }
    }

    var polishSelectedShortcut: KeyCombo? {
        get {
            access(keyPath: \.polishSelectedShortcut)
            return Self.decodeShortcut(SettingsKeys.polishSelectedShortcut,
                                       default: Self.defaultPolishSelected)
        }
        set {
            withMutation(keyPath: \.polishSelectedShortcut) {
                Self.encodeShortcut(newValue, SettingsKeys.polishSelectedShortcut)
            }
            Self.apply(newValue, to: polishSelectedTextHotkey)
        }
    }

    var brainDumpShortcut: KeyCombo? {
        get {
            access(keyPath: \.brainDumpShortcut)
            return Self.decodeShortcut(SettingsKeys.brainDumpShortcut, default: Self.defaultBrainDump)
        }
        set {
            withMutation(keyPath: \.brainDumpShortcut) {
                Self.encodeShortcut(newValue, SettingsKeys.brainDumpShortcut)
            }
            Self.apply(newValue, to: brainDumpHotkey)
        }
    }

    // These were briefly moved to ⌃⌥ because ⌘⇧B is Notes' "Body" style and ⌘|
    // is Center in every standard AppKit document app, and the old global
    // NSEvent monitor could not consume the keystroke — so the target app ran
    // its menu command on every use. GlobalHotkey's CGEventTap now swallows a
    // matched combo before anyone is offered it, which removes the constraint
    // rather than working around it, so the ⌘⇧ family is back.
    // Caveat: without Accessibility the tap cannot be created and the keystroke
    // does reach the app again — but Polish Selected needs Accessibility to
    // copy and paste at all, so it is broken in that state regardless.
    static let defaultSmartDictation = KeyCombo(
        keyCode: 11, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "B")
    // kVK_ANSI_Backslash. label "|" is what KeyRecorderView captures for this
    // combo (charactersIgnoringModifiers keeps Shift's character), so a
    // hand-written default and a recorded one render identically.
    static let defaultPolishSelected = KeyCombo(
        keyCode: 42, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "|")
    static let defaultBrainDump = KeyCombo(
        keyCode: 2, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "D")

    func defaultShortcut(for slot: ShortcutSlot) -> KeyCombo {
        switch slot {
        case .dictation: .defaultDictation
        case .smartDictation: Self.defaultSmartDictation
        case .polishSelected: Self.defaultPolishSelected
        case .brainDump: Self.defaultBrainDump
        }
    }

    /// Only the slots that currently HAVE a shortcut. Absent = disabled, which
    /// is what lets ShortcutValidation treat two disabled features as
    /// non-conflicting rather than both-nil-therefore-equal.
    var assignedShortcuts: [ShortcutSlot: KeyCombo] {
        var out: [ShortcutSlot: KeyCombo] = [.dictation: dictationShortcut]
        if let combo = smartDictationShortcut { out[.smartDictation] = combo }
        if let combo = polishSelectedShortcut { out[.polishSelected] = combo }
        if let combo = brainDumpShortcut { out[.brainDump] = combo }
        return out
    }

    /// Three states, not two: an explicit "disabled" marker, a stored combo, or
    /// nothing stored yet (first run) which means the built-in default.
    private static let disabledMarker = "disabled"

    private static func decodeShortcut(_ key: String, default fallback: KeyCombo) -> KeyCombo? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == disabledMarker { return nil }
        guard let data = defaults.data(forKey: key) else { return fallback }
        // Corrupt stored JSON falls back to the default rather than leaving the
        // feature permanently unreachable.
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? fallback
    }

    private static func encodeShortcut(_ combo: KeyCombo?, _ key: String) {
        let defaults = UserDefaults.standard
        guard let combo else {
            defaults.set(disabledMarker, forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(combo), forKey: key)
    }

    private static func apply(_ combo: KeyCombo?, to hotkey: GlobalHotkey) {
        guard let combo else {
            hotkey.stop()
            return
        }
        hotkey.reconfigure(keyCode: combo.keyCode, modifiers: combo.flags)
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
        get {
            access(keyPath: \.contextAwareDictationEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.contextAwareDictationEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.contextAwareDictationEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.contextAwareDictationEnabled)
            }
        }
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
            access(keyPath: \.autoDeleteAfterDays)
            let value = UserDefaults.standard.integer(forKey: SettingsKeys.autoDeleteAfterDays)
            return value == 0 ? nil : value
        }
        set {
            withMutation(keyPath: \.autoDeleteAfterDays) {
                UserDefaults.standard.set(newValue ?? 0, forKey: SettingsKeys.autoDeleteAfterDays)
            }
        }
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
                meetingWatcher.onBeginPreRoll = { [weak self] appName, pid in
                    guard let self else { return }
                    preRollRunning = beginRecording(appName: appName, pid: pid, visible: false)
                }
                meetingWatcher.onDiscardPreRoll = { [weak self] in
                    Task { await self?.discardPreRollRecording() }
                }
                meetingWatcher.onStartRecording = { [weak self] appName in
                    guard let self else { return }
                    // Normally the recording is already running from the
                    // pre-roll and consent just makes it visible. Starting one
                    // here is the fallback for a pre-roll that FAILED — in
                    // which case a yes must still produce a recording.
                    if preRollRunning {
                        preRollRunning = false
                        isRecordingMeeting = true
                    } else {
                        beginRecording(appName: appName,
                                       pid: meetingWatcher.recordingPID, visible: true)
                    }
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

    /// Match finished recordings to calendar events for a real title + attendee
    /// names. Off by default; the Meetings UI requests Calendar permission when
    /// this is switched on (denied → the UI flips it back off).
    var meetingsCalendarEnabled: Bool {
        get {
            access(keyPath: \.meetingsCalendarEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.meetingsCalendarEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.meetingsCalendarEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.meetingsCalendarEnabled)
            }
        }
    }

    /// Record the user's own microphone into meetings.
    ///
    /// Default TRUE — today's behaviour. Defaulting this off would silently stop
    /// capturing every existing user's own voice in every meeting, which is the
    /// silent data loss this feature exists to avoid, not cause.
    ///
    /// Read at `start()`, so it governs the pre-roll as well: that begins at
    /// detection, before any consent prompt exists, and is the window a
    /// conference room most needs protected.
    var recordMeetingMic: Bool {
        get {
            access(keyPath: \.recordMeetingMic)
            return UserDefaults.standard.object(forKey: SettingsKeys.recordMeetingMic) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.recordMeetingMic) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.recordMeetingMic)
            }
        }
    }

    /// Live mic state for the recording controls. `meetingRecorder` is not
    /// `@Observable`, so mutating it signals nothing on its own — reading the
    /// version counter here is what makes SwiftUI re-read after mute/discard.
    var meetingMicMuted: Bool {
        _ = meetingMicVersion
        return meetingRecorder.isMicMuted
    }

    private var meetingMicVersion = 0

    /// Whether a recorder is running at all — a visible recording OR a pre-roll,
    /// which is deliberately invisible but is very much writing audio.
    private var meetingCaptureRunning: Bool { isRecordingMeeting || preRollRunning }

    /// Stop capturing the mic for the rest of this recording. One-way.
    func muteMeetingMic() {
        guard meetingCaptureRunning else { return }
        meetingRecorder.muteMic()
        meetingMicVersion &+= 1
    }

    /// Delete this recording's mic track and stop capturing. One-way, and
    /// deliberately unconfirmed — it is reached for during a live meeting, and
    /// a modal would defeat the point.
    ///
    /// The guard is load-bearing, not defensive. `stop()` deliberately leaves
    /// `meetingDirectory` pointing at the finished meeting, so calling this when
    /// nothing is running would delete the PREVIOUS meeting's me.caf while its
    /// stored row still said the mic was captured and still held every `You`
    /// turn — silent, partial data loss with no UI trace. The views hide these
    /// controls, but a stale SwiftUI body is not a safety mechanism.
    func discardMeetingMicAudio() {
        guard meetingCaptureRunning else {
            log.warning("discardMeetingMicAudio ignored — no recording is running")
            return
        }
        meetingRecorder.discardMicTrack()
        meetingMicVersion &+= 1
    }

    /// Default summary template for meetings; nil = Standard. Stored as a UUID
    /// string; an unknown ID (a deleted custom template) resolves to Standard
    /// at use rather than failing the summary.
    var meetingTemplateID: UUID? {
        get {
            access(keyPath: \.meetingTemplateID)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.meetingTemplateID) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            withMutation(keyPath: \.meetingTemplateID) {
                UserDefaults.standard.set(newValue?.uuidString, forKey: SettingsKeys.meetingTemplateID)
            }
        }
    }

    /// User-authored meeting templates — same storage pattern as
    /// customPolishStyles, but a separate list: these shape meeting notes and
    /// never appear in the AI tab's dictation-style picker, or vice versa.
    var customMeetingTemplates: [PolishStyle] {
        get {
            access(keyPath: \.customMeetingTemplates)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customMeetingTemplates) else { return [] }
            return (try? JSONDecoder().decode([PolishStyle].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.customMeetingTemplates) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customMeetingTemplates)
            }
        }
    }

    /// Start the recorder and capture the window title. Shared by the pre-roll,
    /// the post-consent fallback, and the manual toggle. On failure, resets the
    /// watcher so it isn't stuck showing .recording with no audio flowing.
    ///
    /// `pid` is passed rather than read from the watcher: during a pre-roll the
    /// watcher's recordingPID is deliberately still nil (nothing is consented),
    /// and reading it there would fall back to the frontmost app — which is
    /// OmWhisper itself, since Record lives in the hub window.
    ///
    /// `visible` is false for a pre-roll: if isRecordingMeeting were true the
    /// hub button would read "Stop recording" while the consent panel asks
    /// "Record this Teams call?" — two contradictory statements about one
    /// recording.
    @discardableResult
    private func beginRecording(appName: String, pid: pid_t?, visible: Bool) -> Bool {
        do {
            try meetingRecorder.start(appName: appName, preferredMicUID: audioInputDeviceUID,
                                      recordMic: recordMeetingMic)
            meetingStartedAt = Date()
            meetingAppName = appName
            // Frontmost is the last resort, for manual recordings of apps the
            // detector doesn't recognise.
            let resolved = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            meetingWindowTitle = resolved.flatMap {
                CallDetection.callWindowTitle(pid: $0, appName: appName)
            }
            // The window title is not knowable yet at this instant, and pre-roll
            // made that worse by reading it earlier than ever. Keep looking.
            if meetingWindowTitle == nil, let resolved {
                watchForMeetingTitle(pid: resolved, appName: appName)
            }
            isRecordingMeeting = visible
            return true
        } catch {
            log.error("meeting recording failed to start: \(error)")
            meetingWatcher.failedToStartRecording()
            isRecordingMeeting = false
            return false
        }
    }

    /// Is a pre-roll recorder actually running right now?
    ///
    /// Tracked explicitly rather than inferred from
    /// `meetingRecorder.meetingDirectory != nil`, which looks like the obvious
    /// test and is wrong: `stop()` never clears that property (recordFinished-
    /// Meeting reads it AFTER stopping), so it stays non-nil for the rest of
    /// the session once any recording has happened. Inferring from it would
    /// make the post-consent fallback believe a failed pre-roll had succeeded,
    /// and consent would produce a recording that was never started.
    @ObservationIgnored private var preRollRunning = false
    @ObservationIgnored private var titleWatchTask: Task<Void, Never>?

    /// Keep looking for the call window's title until one appears.
    ///
    /// Reading it once at record start is wrong, and pre-roll made it worse by
    /// reading it earlier still: a real 2026-08-06 Teams call was filed as
    /// "Calendar" because that was the nav tab open when the mic opened, and a
    /// 1:1 call window carrying the other person's name did not exist yet.
    ///
    /// `callWindowTitle` returns only titles that survive chrome rejection, so
    /// non-nil IS the stop condition — no second judgement needed here. The AX
    /// walk goes to the cooperative pool rather than running on MainActor every
    /// 2s, which is the shape of the MemoryCapture freeze.
    private func watchForMeetingTitle(pid: pid_t, appName: String) {
        titleWatchTask?.cancel()
        titleWatchTask = Task { [weak self] in
            // ~60s. A call window that hasn't appeared by then isn't going to,
            // and the generated title covers what this can't reach.
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                // The recording ended, or someone already found a title.
                guard meetingAppName != nil, meetingWindowTitle == nil else { return }
                let found = await Task.detached(priority: .utility) {
                    CallDetection.callWindowTitle(pid: pid, appName: appName)
                }.value
                if let found {
                    meetingWindowTitle = found
                    return
                }
            }
        }
    }

    /// Stop an unconsented recording and delete everything it wrote. No row is
    /// inserted, so nothing surfaces in the UI and nothing is left behind.
    private func discardPreRollRecording() async {
        guard preRollRunning else { return }
        preRollRunning = false
        titleWatchTask?.cancel()
        let directory = meetingRecorder.meetingDirectory
        await meetingRecorder.stop()
        isRecordingMeeting = false
        if let directory { try? FileManager.default.removeItem(at: directory) }
        meetingStartedAt = nil
        meetingAppName = nil
        meetingWindowTitle = nil
    }

    /// Stop the recorder, clear the flag, and persist the finished-meeting row.
    private func endRecording() async {
        // Before stop(), so a poll in flight cannot land a title on the next
        // recording's state after this one's row has been written.
        titleWatchTask?.cancel()
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
            return
        }
        // A pre-roll is running and the panel is asking: clicking Record here
        // is the same yes. Without this we would start a second recorder over
        // a live one.
        if preRollRunning, meetingWatcher.isPreRolling, let appName = meetingAppName,
           meetingWatcher.acceptPreRoll(appName: appName) {
            meetingConsentPanel.dismiss()
            preRollRunning = false
            isRecordingMeeting = true
            return
        }
        // The fallback is the frontmost app, but a detected call wins:
        // Record lives in the hub window, so the frontmost app is usually
        // OmWhisper itself.
        let fallback = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Recording"
        let appName = meetingWatcher.enterRecording(fallbackAppName: fallback)
        beginRecording(appName: appName, pid: meetingWatcher.recordingPID, visible: true)
    }

    /// Called after meetingRecorder.stop() flushes me.caf/them.caf: insert a
    /// "Recorded" row so the meeting shows immediately (transcript/summary filled
    /// on demand by transcribeMeeting).
    private func recordFinishedMeeting() {
        guard let store = meetingStore, let dir = meetingRecorder.meetingDirectory else { return }
        let iso = ISO8601DateFormatter()
        // The LONGER of the two tracks, not the mic. Reading me.caf alone meant a
        // recording made with "Record my microphone" off measured 0 and was filed
        // as a failed, untranscribed meeting — while them.caf held the whole call.
        let duration = MeetingTranscriber.recordingDuration(directory: dir)

        // No (meaningful) audio captured — almost always the System Audio Recording
        // permission being denied for this build: the CoreAudio process tap's IO
        // callback silently never fires, so both tracks are empty. Don't leave the
        // user a blank recording they'll wonder about later — save the meeting with
        // a clear explanation AS its transcript, so it surfaces exactly where they
        // look. (Rebuilding the dev app re-signs the binary and resets this grant.)
        var transcript: String?
        if duration < 1.0 {
            log.warning("recordFinishedMeeting — captured no audio (\(duration)s); saving a permission note")
            transcript = """
                ⚠️ No audio was captured for this recording.

                OmWhisper records calls via a system-audio tap, which needs the \
                “System Audio Recording” permission. Grant it in System Settings › \
                Privacy & Security › System Audio Recording, then record again.
                """
            errorMessage = "Recording captured no audio — grant “System Audio Recording” in System Settings."
        }
        var title = meetingWindowTitle.flatMap {
            CallDetection.cleanedMeetingTitle(windowTitle: $0, appName: meetingAppName ?? "Meeting")
        }
        var attendees: [String]?
        if meetingsCalendarEnabled, let started = meetingStartedAt,
           let match = MeetingCalendar.match(start: started, end: Date()) {
            if !match.title.isEmpty { title = match.title }
            if !match.attendees.isEmpty { attendees = match.attendees }
        }
        do {
            let id = try store.insert(Meeting(
                id: nil,
                startedAt: iso.string(from: meetingStartedAt ?? Date()),
                appName: meetingAppName ?? "Meeting",
                directory: dir.path,
                durationSeconds: duration,
                transcript: transcript, summary: nil,
                createdAt: iso.string(from: Date()),
                title: title,
                attendees: attendees,
                // Read after stop() closed the files, so this reflects what is
                // actually on disk rather than the setting that led there.
                micCaptured: meetingRecorder.micCaptured
            ))
            // Transcribe straight away rather than waiting for the user to open the
            // meeting and press a button. Skipped when `transcript` is already set —
            // that's the no-audio permission note, which has nothing to transcribe.
            if transcript == nil {
                autoTranscribe(id: id)
            }
        } catch {
            log.error("recordFinishedMeeting — insert failed: \(error)")
        }
        meetingStartedAt = nil
        meetingAppName = nil
        meetingWindowTitle = nil
    }

    /// Meetings currently being transcribed. Drives the list's "Transcribing…"
    /// status, and its emptying is what tells the open Meetings view to reload —
    /// a background transcribe has no other way to reach a view that already
    /// loaded its rows.
    var transcribingMeetingIDs: Set<Int64> = []

    /// Fire-and-forget transcription of a just-finished recording. Errors are
    /// logged, not surfaced: the row is already saved and the user can always
    /// press Re-transcribe, so a failure here must never interrupt them.
    /// The heavy work is nonisolated (WhisperEngine/MeetingDiarizer), so this
    /// hops off MainActor and leaves the UI responsive.
    func autoTranscribe(id: Int64) {
        transcribingMeetingIDs.insert(id)
        Task { [weak self] in
            defer { self?.transcribingMeetingIDs.remove(id) }
            do { _ = try await self?.transcribeMeeting(id: id) }
            catch { log.error("autoTranscribe(\(id)) failed: \(error)") }
        }
    }

    /// Backends for work with large inputs, in preference order — see
    /// LongFormBackends for why this ignores `polishBackend`. Meetings,
    /// chronicles and brain-dump all come through here.
    ///
    /// Ollama gets `longFormTimeout` (300s), not the 30s dictation timeout:
    /// nobody is waiting on a keystroke here, and a cold model takes ~36s to
    /// load. Cloud is never constructed, so recorded calls and chronicles
    /// cannot egress even as text, whatever the polish backend is.
    ///
    /// The Default row. Ships as `.useDefault`, which means today's automatic
    /// on-device order -- so an existing user sees no change until they
    /// deliberately choose something.
    var defaultBackend: FeatureBackend {
        get {
            access(keyPath: \.defaultBackend)
            let raw = UserDefaults.standard.string(forKey: SettingsKeys.defaultAIBackend) ?? ""
            return FeatureBackend(rawValue: raw) ?? .useDefault
        }
        set {
            withMutation(keyPath: \.defaultBackend) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.defaultAIBackend)
            }
        }
    }

    /// Bumped on every per-feature change. `backend(for:)` is a FUNCTION, so
    /// Observation has no key path of its own to track -- this is the
    /// observable token the Pickers read. Without it the menus would not
    /// re-render, which is the same @Observable gap that made the AI tab's
    /// radio buttons stick in M3.
    private(set) var aiBackendsVersion: Int = 0

    /// One feature's choice. Unrecognised or missing resolves to `.useDefault`
    /// -- never to cloud.
    func backend(for feature: AIFeature) -> FeatureBackend {
        access(keyPath: \.aiBackendsVersion)
        let raw = UserDefaults.standard.string(forKey: feature.settingsKey) ?? ""
        return FeatureBackend(rawValue: raw) ?? .useDefault
    }

    func setBackend(_ choice: FeatureBackend, for feature: AIFeature) {
        withMutation(keyPath: \.aiBackendsVersion) {
            UserDefaults.standard.set(choice.rawValue, forKey: feature.settingsKey)
            aiBackendsVersion &+= 1
        }
    }

    /// `kind` rides along so callers can name whichever candidate won, without
    /// having to type-check a PolishBackend existential.
    ///
    /// Every long-form feature resolves through `LongFormBackends.candidates`,
    /// so the rule that cloud is only ever reached when explicitly chosen lives
    /// in exactly one place rather than at each call site.
    private func backends(for feature: AIFeature,
                          ollamaChunkLimit: Int, systemChunkLimit: Int, cloudChunkLimit: Int)
        -> [(kind: LongFormBackends.Kind, polish: PolishBackend, chunkLimit: Int)] {
        let cloudKey = Keychain.loadCloudLLMKey()
        return LongFormBackends.candidates(
            choice: backend(for: feature),
            defaultChoice: defaultBackend,
            ollamaConfigured: !ollamaModel.isEmpty,
            systemAvailable: SystemLLM.isAvailable(),
            cloudConfigured: !(cloudKey ?? "").isEmpty
        ).compactMap { kind in
            switch kind {
            case .ollama:
                return (kind,
                        Ollama(baseURL: ollamaBaseURL, model: ollamaModel,
                               timeout: Ollama.longFormTimeout),
                        ollamaChunkLimit)
            case .system:
                return (kind, systemLLM, systemChunkLimit)
            case .cloud:
                guard let key = cloudKey, !key.isEmpty else { return nil }
                return (kind, CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key),
                        cloudChunkLimit)
            }
        }
    }

    private func meetingSummaryBackends()
        -> [(kind: LongFormBackends.Kind, polish: PolishBackend, chunkLimit: Int)] {
        backends(for: .meetings,
                 ollamaChunkLimit: MeetingSummarizer.ollamaChunkLimit,
                 systemChunkLimit: MeetingSummarizer.chunkCharLimit,
                 cloudChunkLimit: MeetingSummarizer.cloudChunkLimit)
    }

    /// First candidate that produces a summary, with the name of whichever one
    /// did; nil when all fail or none exist.
    private func generateMeetingSummary(transcript: String,
                                        template: PolishStyle) async -> (summary: String, backend: String)? {
        for candidate in meetingSummaryBackends() {
            if let summary = try? await MeetingSummarizer.generate(
                transcript: transcript, polish: candidate.polish,
                template: template, chunkLimit: candidate.chunkLimit
            ), !summary.isEmpty {
                return (summary, LongFormBackends.displayName(for: candidate.kind,
                                                              ollamaModel: ollamaModel))
            }
        }
        return nil
    }

    /// Name the meeting from its summary when nothing better is known.
    ///
    /// Never overwrites a title the user typed — only a nil or app-chrome one.
    /// Best-effort throughout: a failure leaves the title alone, and the header
    /// falls back to the app name exactly as before.
    private func nameMeetingIfNeeded(id: Int64, summary: String) async {
        guard let store = meetingStore, let meeting = try? store.get(id: id) else { return }
        if let existing = meeting.title,
           !CallDetection.isGenericTitle(existing, appName: meeting.appName) { return }
        for candidate in meetingSummaryBackends() {
            // `try?` on a throwing Optional-returning call flattens to one
            // optional, so a thrown error and an unusable title both fall
            // through to the next candidate — which is what we want anyway.
            guard let generated = try? await MeetingSummarizer.title(
                fromSummary: summary, polish: candidate.polish) else { continue }
            try? store.setTitle(id: id, generated)
            return
        }
    }

    /// The view's path: transcribe both tracks on-device (AppleEngine) and
    /// summarize on-device -- SystemLLM, or Ollama when that's the selected
    /// polish backend; never Cloud, whatever the dictation/polish backend.
    /// Transcript is always saved; summary is best-effort. Returns the meeting.
    func transcribeMeeting(id: Int64) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id) else {
            throw MeetingStoreError.notFound
        }
        let transcript = try await MeetingTranscriber.transcribeMeeting(
            directory: URL(fileURLWithPath: meeting.directory), engine: AppleEngine(), whisper: whisperEngine
        )
        var written: (summary: String, backend: String)?
        if !meetingSummaryBackends().isEmpty {
            written = await generateMeetingSummary(
                transcript: transcript,
                template: MeetingSummarizer.template(id: meetingTemplateID, custom: customMeetingTemplates))
        } else if !didNudgeFoundationModelsUnavailable {
            didNudgeFoundationModelsUnavailable = true
            errorMessage = systemUnavailableMessage("summarize meetings") + " Transcript saved without a summary."
        }
        // Fresh diarization labels are not stable across runs — a mapping made
        // for the old labels would rename the wrong people. Reset it.
        try store.setSpeakerNames(id: id, nil)
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: written?.summary,
                                          summaryBackend: written?.backend)
        if let summary = written?.summary { await nameMeetingIfNeeded(id: id, summary: summary) }
        return try store.get(id: id) ?? meeting
    }

    /// Remove the user's own microphone from a meeting that is already recorded.
    ///
    /// The ORDER is the feature, not an implementation detail. Deleting the
    /// audio alone fixes nothing — the private words are already in the
    /// transcript, which is the searchable, exportable, summarised copy. Each
    /// step is persisted before the next begins, so an interruption anywhere
    /// leaves the recording MORE private, never less.
    @discardableResult
    func deleteMeetingMicAudio(id: Int64) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id) else {
            throw MeetingStoreError.notFound
        }

        // 1. The audio. try? — a directory the user already cleaned out by hand
        //    must not stop the transcript being stripped.
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: meeting.directory).appendingPathComponent("me.caf"))

        // 2. + 3. The transcript, with no summary. One write, so there is no
        //    state where the transcript is clean but the row still claims the
        //    mic was captured.
        let stripped = meeting.transcript.map(MeetingDiarization.removingYouTurns)
        try store.removeMicTrack(id: id, transcript: (stripped?.isEmpty ?? true) ? nil : stripped)

        // 4. Regenerate, best-effort and deliberately LAST. The summary is
        //    already gone by now, so a backend that is unavailable or times out
        //    leaves this meeting with no summary — never the old one, which
        //    quoted what was just removed. The user can press Regenerate
        //    summary whenever they like.
        if let transcript = stripped, !transcript.isEmpty {
            let resolved = MeetingDiarization.applySpeakerNames(
                transcript, names: meeting.speakerNames ?? [:])
            let template = MeetingSummarizer.template(
                id: meetingTemplateID, custom: customMeetingTemplates)
            if let written = await generateMeetingSummary(transcript: resolved, template: template) {
                try? store.setTranscriptAndSummary(id: id, transcript: transcript,
                                                   summary: written.summary,
                                                   summaryBackend: written.backend)
            }
        }
        return try store.get(id: id) ?? meeting
    }

    /// Re-run the summary over the existing transcript with speaker names
    /// resolved — no ASR/diarization. The correct-then-regenerate loop: rename
    /// "Speaker 1" to "Alice", regenerate, and the summary says Alice.
    /// `templateID` nil = the stored default; the detail view passes an explicit
    /// one when the user picks a template for this run only.
    func regenerateSummary(id: Int64, templateID: UUID? = nil) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id),
              let transcript = meeting.transcript else {
            throw MeetingStoreError.notFound
        }
        guard !meetingSummaryBackends().isEmpty else {
            errorMessage = systemUnavailableMessage("summarize on-device")
            return meeting
        }
        let resolved = MeetingDiarization.applySpeakerNames(
            transcript, names: meeting.speakerNames ?? [:])
        let template = MeetingSummarizer.template(
            id: templateID ?? meetingTemplateID, custom: customMeetingTemplates)
        guard let written = await generateMeetingSummary(transcript: resolved, template: template) else {
            errorMessage = "Summary generation failed — see Copy Debug Info in About, or try again."
            return meeting
        }
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: written.summary,
                                          summaryBackend: written.backend)
        // Also the retitle path for meetings recorded before this existed:
        // Regenerate summary on the "Chat" row names it properly.
        await nameMeetingIfNeeded(id: id, summary: written.summary)
        return try store.get(id: id) ?? meeting
    }

    /// One-shot question about a single meeting. Same on-device backend
    /// selection as summaries (Ollama when selected, else SystemLLM, never
    /// Cloud). Returns nil when no backend is available or the call fails —
    /// errorMessage is already set, so the caller just renders nothing.
    func askAboutMeeting(id: Int64, question: String) async -> String? {
        guard let store = meetingStore, let meeting = try? store.get(id: id),
              let transcript = meeting.transcript, !transcript.isEmpty else {
            errorMessage = "That meeting has no transcript to answer from."
            return nil
        }
        guard let candidate = meetingSummaryBackends().first else {
            errorMessage = systemUnavailableMessage("summarize on-device")
            return nil
        }
        let resolved = MeetingDiarization.applySpeakerNames(
            transcript, names: meeting.speakerNames ?? [:])
        do {
            return try await MeetingSummarizer.answer(
                question: question, transcript: resolved,
                polish: candidate.polish, chunkLimit: candidate.chunkLimit)
        } catch {
            errorMessage = "Couldn't answer that — \(error.localizedDescription)"
            return nil
        }
    }

    /// Draft a follow-up email from the meeting's summary, falling back to the
    /// transcript when there's no summary yet. Returns nil on failure.
    func draftFollowUp(id: Int64) async -> String? {
        guard let store = meetingStore, let meeting = try? store.get(id: id) else { return nil }
        let source = meeting.summary ?? MeetingDiarization.applySpeakerNames(
            meeting.transcript ?? "", names: meeting.speakerNames ?? [:])
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Nothing to draft from yet — transcribe the meeting first."
            return nil
        }
        guard let candidate = meetingSummaryBackends().first else {
            errorMessage = systemUnavailableMessage("summarize on-device")
            return nil
        }
        do {
            return try await candidate.polish.polish(
                String(source.prefix(candidate.chunkLimit)),
                style: MeetingSummarizer.followUpStyle, targetLanguage: nil)
        } catch {
            errorMessage = "Couldn't draft the follow-up — \(error.localizedDescription)"
            return nil
        }
    }

    /// Embed whatever snapshots don't have passages yet — the same call serves
    /// the one-time backfill and the per-capture trickle. Fire-and-forget: while
    /// it runs, and if it fails, Memory search simply stays keyword-only, which
    /// is exactly the behaviour before this feature existed.
    ///
    /// `maxBatches` bounds ONE invocation. Passing no bound meant a single call
    /// drained the entire pending queue flat out — the most likely source of
    /// the 175% CPU spike after a relaunch with a backlog. A backlog now drains
    /// across successive capture ticks instead, which is exactly the
    /// self-healing, resumable design MemoryIndexer's own header describes: the
    /// pending query IS the cursor, so there is no new state to persist.
    ///
    /// `catchUp` is the enable-time call, where the user is implicitly waiting
    /// for a first index and a larger bound is the right trade.
    private func indexPendingMemory(catchUp: Bool = false) {
        guard !isIndexingMemory, let store = memoryStore, let indexer = memoryIndexer else { return }
        isIndexingMemory = true
        let maxBatches = catchUp ? 20 : 1
        Task.detached(priority: .utility) { [weak self] in
            do { _ = try indexer.processPending(store: store, maxBatches: maxBatches) }
            catch { log.error("memory indexing failed: \(error)") }
            await MainActor.run { self?.isIndexingMemory = false }
        }
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
                memoryCapture.exclusions = currentMemoryExclusions()
                memoryCapture.onSnapshotStored = { [weak self] in self?.indexPendingMemory() }
                memoryCapture.onDegradation = { [weak self] in
                    self?.escalateDegradationIfNeeded(.memoryCapture)
                }
                memoryCapture.start()
                // Catch up on everything captured before this feature existed.
                indexPendingMemory(catchUp: true)
                chronicleScheduler.store = memoryStore
                chronicleScheduler.generate = { [weak self] day in
                    _ = try await self?.generateChronicle(day: day)
                }
                // Suppressed only when NO backend can write one. This used to be
                // `polishBackend != .system`, which disabled the nightly chronicle
                // for every Ollama user even though Ollama can write it.
                chronicleScheduler.isSuppressed = { [weak self] in
                    self?.chronicleBackends().isEmpty ?? true
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

    /// Bundle IDs whose windows are never captured into memory. Adds to the
    /// hardcoded floor in ScreenContextReader.isExcluded; never replaces it.
    /// Empty by default.
    var memoryExcludedApps: [String] {
        get {
            access(keyPath: \.memoryExcludedApps)
            return UserDefaults.standard.stringArray(forKey: SettingsKeys.memoryExcludedApps) ?? []
        }
        set {
            withMutation(keyPath: \.memoryExcludedApps) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryExcludedApps)
            }
            memoryCapture.exclusions = currentMemoryExclusions(apps: newValue)
        }
    }

    /// Case-insensitive substrings; a window whose title contains any of them is
    /// never captured. Matches the TITLE only, never page content. Empty by default.
    var memoryExcludedTitleKeywords: [String] {
        get {
            access(keyPath: \.memoryExcludedTitleKeywords)
            return UserDefaults.standard.stringArray(forKey: SettingsKeys.memoryExcludedTitleKeywords) ?? []
        }
        set {
            withMutation(keyPath: \.memoryExcludedTitleKeywords) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryExcludedTitleKeywords)
            }
            memoryCapture.exclusions = currentMemoryExclusions(keywords: newValue)
        }
    }

    /// One place that builds the value, so the two setters above cannot drift
    /// (each one only knows its own new value; the other must be read fresh).
    /// Why the on-device model can't do `action`, plus what to do instead.
    /// Built from SystemLLM's real reason rather than assuming "it's switched
    /// off" -- on an unsupported-language Mac, Apple Intelligence IS on, and
    /// telling the user to enable it sends them somewhere that looks correct.
    func systemUnavailableMessage(_ action: String) -> String {
        let cause = SystemLLM.unavailableReason() ?? "The on-device model is unavailable."
        return "\(cause) Select Ollama in Settings › AI to \(action)."
    }

    private func currentMemoryExclusions(apps: [String]? = nil, keywords: [String]? = nil) -> MemoryExclusions {
        MemoryExclusions(
            apps: Set(apps ?? memoryExcludedApps),
            titleKeywords: keywords ?? memoryExcludedTitleKeywords
        )
    }

    /// Chronicle backends in preference order. Cloud is deliberately absent and
    /// must stay absent: memory is the most sensitive store in this app and
    /// never leaves the device, whatever the polish backend is set to.
    private func chronicleBackends()
        -> [(kind: LongFormBackends.Kind, polish: PolishBackend, chunkLimit: Int)] {
        backends(for: .chronicles,
                 ollamaChunkLimit: Chronicler.ollamaChunkLimit,
                 systemChunkLimit: Chronicler.chunkCharLimit,
                 cloudChunkLimit: Chronicler.cloudChunkLimit)
    }

    /// First candidate that writes a chronicle wins. The three failure modes are
    /// deliberately distinguishable: no backend at all, every backend failed, and
    /// nothing captured that day are different problems with different fixes.
    func generateChronicle(day: String) async throws -> Chronicler.ChronicleResult {
        guard let memoryStore else { throw Chronicler.ChroniclerError.noSnapshots }
        let candidates = chronicleBackends()
        guard !candidates.isEmpty else {
            throw Chronicler.ChroniclerError.backendUnavailable(
                systemUnavailableMessage("write chronicles")
            )
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                // Resolved out here: the Task captures self weakly, and reading
                // ollamaModel inside it would capture self strongly.
                let backendName = LongFormBackends.displayName(for: candidate.kind,
                                                               ollamaModel: ollamaModel)
                let task = Task<Chronicler.ChronicleResult, Error> { [weak self] in
                    try await Chronicler.generate(
                        day: day, store: memoryStore, polish: candidate.polish,
                        chunkLimit: candidate.chunkLimit,
                        backendName: backendName,
                        onProgress: { done, total in
                            Task { @MainActor in self?.chronicleProgress = (done, total) }
                        }
                    )
                }
                chronicleTask = task
                defer { chronicleTask = nil; chronicleProgress = nil }
                return try await task.value
            } catch is CancellationError {
                // Not a failure — the user asked it to stop. No error surfaces
                // and no other backend is tried.
                throw CancellationError()
            } catch let error as Chronicler.ChroniclerError {
                // No snapshots is about the day, not the backend -- trying a
                // second backend cannot help and would hide the real reason.
                throw error
            } catch {
                lastError = error
            }
        }
        throw Chronicler.ChroniclerError.backendUnavailable(
            "Couldn't write a chronicle — the on-device model failed. \(lastError?.localizedDescription ?? "")"
                .trimmingCharacters(in: .whitespaces)
        )
    }

    func regenerateChronicle(day: String) async throws -> Chronicler.ChronicleResult {
        try await generateChronicle(day: day)
    }

    /// nil when nothing is generating. A STORED property, so `@Observable`
    /// instruments it automatically — unlike every UserDefaults-backed setting
    /// in this file, which needs access/withMutation. If this is ever converted
    /// to a computed property over external storage it must gain those calls,
    /// or the progress display will silently stop updating.
    private(set) var chronicleProgress: (done: Int, total: Int)?

    /// Stops a run in flight. Cancelling writes nothing: a partial chronicle is
    /// worse than none, and the day can simply be regenerated.
    func cancelChronicle() {
        chronicleTask?.cancel()
        chronicleTask = nil
        chronicleProgress = nil
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

    /// When cross-lingual is on AND a Sarvam key is saved, whether to actually
    /// route through Sarvam (cloud) vs. the on-device Whisper path. Default true
    /// (a saved key implies intent to use it), but decoupled from key presence so
    /// the user can flip to on-device — for privacy, offline, or cost — without
    /// deleting their key.
    var crossLingualUseSarvam: Bool {
        get {
            access(keyPath: \.crossLingualUseSarvam)
            return UserDefaults.standard.object(forKey: SettingsKeys.crossLingualUseSarvam) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.crossLingualUseSarvam) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.crossLingualUseSarvam)
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
        // Cross-lingual + a Sarvam key + Use-Sarvam on → Saaras does speech→English.
        if crossLingualUsesSarvam {
            return SarvamEngine()
        }
        return switch CrossLingual.engineKind(base: engineKind, crossLingual: crossLingualEnabled) {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: CloudEngine(provider: cloudProvider)   // stateless; built per session
        case .whisper: whisperEngine
        }
    }

    /// True when cross-lingual dictation is actually going through Sarvam (audio
    /// to the cloud) rather than the on-device Whisper path — the single source of
    /// truth for engine selection, the polish skip, and the cloud privacy line.
    var crossLingualUsesSarvam: Bool {
        crossLingualEnabled && crossLingualUseSarvam && Keychain.loadSarvamKey() != nil
    }

    /// Any active path that sends data off this Mac — drives the honest privacy
    /// status line. Cross-lingual+Sarvam is the easy one to miss: it overrides
    /// the engine picker without changing `engineKind`.
    var usesCloud: Bool {
        engineKind == .cloud || crossLingualUsesSarvam || polishBackend == .cloud
    }

    /// One line naming what will actually transcribe your voice, and whether that
    /// happens here — for the hub sidebar's footer. Names the engine that would
    /// really run (Sarvam overrides the picked engine when cross-lingual is on),
    /// so it can't claim "on this Mac" while audio is leaving it.
    var engineStatusLine: String {
        if crossLingualUsesSarvam { return "Sarvam · audio leaves this Mac" }
        switch engineKind {
        case .apple: return "Apple Speech · on this Mac"
        case .parakeet: return "Parakeet \(parakeetModel.displayName) · on this Mac"
        case .whisper: return "Whisper \(whisperModel.displayName) · on this Mac"
        case .cloud: return "\(cloudProvider.displayName) · audio leaves this Mac"
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
        keyCode: smartDictationShortcut?.keyCode ?? Self.defaultSmartDictation.keyCode,
        // Read the stored modifiers too — hardcoding [.command, .shift] here
        // meant a custom combo installed with the right key and the WRONG
        // modifiers after every relaunch, and silently never fired.
        modifiers: (smartDictationShortcut ?? Self.defaultSmartDictation).flags
    ) { [weak self] in
        self?.beginSmartDictation()
    }
    /// kVK_ANSI_P — Polish Selected Text: copy the frontmost app's selection,
    /// polish it, paste it back in place. Not a dictation session — dictation
    /// stays .idle throughout; overlayPhase alone drives the brief pill.
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: polishSelectedShortcut?.keyCode ?? Self.defaultPolishSelected.keyCode,
        // Read the stored modifiers too — hardcoding [.command, .shift] here
        // meant a custom combo installed with the right key and the WRONG
        // modifiers after every relaunch, and silently never fired.
        modifiers: (polishSelectedShortcut ?? Self.defaultPolishSelected).flags
    ) { [weak self] in
        self?.beginPolishSelectedText()
    }
    /// kVK_ANSI_D — Brain-dump mode: ramble, then structure into the active shape.
    @ObservationIgnored private lazy var brainDumpHotkey = GlobalHotkey(
        keyCode: brainDumpShortcut?.keyCode ?? Self.defaultBrainDump.keyCode,
        // Read the stored modifiers too — hardcoding [.command, .shift] here
        // meant a custom combo installed with the right key and the WRONG
        // modifiers after every relaunch, and silently never fired.
        modifiers: (brainDumpShortcut ?? Self.defaultBrainDump).flags
    ) { [weak self] in
        self?.beginBrainDump()
    }
    @ObservationIgnored private let meetingWatcher = MeetingWatcher()

    /// The watcher's current state, for Copy Debug Info. Only the state is
    /// exposed, not the watcher: nothing outside AppState should be driving it.
    var meetingWatcherState: String { String(describing: meetingWatcher.state) }
    @ObservationIgnored private let meetingRecorder = MeetingRecorder()
    @ObservationIgnored private let meetingConsentPanel = MeetingConsentPanel()
    @ObservationIgnored private var meetingStartedAt: Date?
    @ObservationIgnored private var meetingAppName: String?
    /// Raw call-window title captured at record start (the window is often gone
    /// by stop time — auto-stop fires BECAUSE it disappeared). Cleaned at insert.
    @ObservationIgnored private var meetingWindowTitle: String?
    /// True whenever a meeting is being recorded — auto-detected OR manual.
    /// Observable (not @ObservationIgnored) so the hub button and mini-panel row
    /// reflect it. Flipped only in beginRecording/endRecording.
    private(set) var isRecordingMeeting = false
    @ObservationIgnored private let replyAssistMonitor = ReplyAssistMonitor()
    @ObservationIgnored private let replyStreamTypist = ReplyStreamTypist()
    @ObservationIgnored private var isReplyAssistDrafting = false
    @ObservationIgnored private let memoryCapture = MemoryCapture()
    /// nil when no embedding model is available — search then stays keyword-only,
    /// which is exactly the pre-semantic behaviour.
    @ObservationIgnored let memoryEmbedder: MemoryEmbedder? = AppleEmbedder()
    @ObservationIgnored private let memoryIndexer = MemoryIndexer()
    /// Guards against overlapping index runs: capture nudges every 5s, and the
    /// first run has thousands of snapshots to get through.
    @ObservationIgnored private var isIndexingMemory = false
    @ObservationIgnored private let chronicleScheduler = ChronicleScheduler()
    @ObservationIgnored private var chronicleTask: Task<Chronicler.ChronicleResult, Error>?

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

        // Delete meeting directories no row points at — a crash mid-recording,
        // or an unconsented pre-roll the app never got to clean up. Guarded by
        // isRunningUnderTests for the same reason every other store daemon is,
        // and off the main thread because it is file I/O. Runs here, before any
        // recorder can have started, so it cannot race a live recording.
        if !isRunningUnderTests, let store = meetingStore, let appSupportDir {
            let root = appSupportDir.appendingPathComponent("meetings", isDirectory: true)
            Task.detached(priority: .utility) { MeetingOrphanSweep.run(store: store, root: root) }
        }

        // Stores are open now -- start input monitors and re-run the enable
        // setters, which wire the (now non-nil) stores into their daemons.
        hotkey.start()
        pushToTalk.start()
        // Guarded: a disabled shortcut must never install a monitor. Also
        // forces the lazy vars to evaluate here, after UserDefaults is
        // readable, so a stored custom combo isn't missed.
        if smartDictationShortcut != nil { smartDictationHotkey.start() }
        if brainDumpShortcut != nil { brainDumpHotkey.start() }
        if polishSelectedShortcut != nil { polishSelectedTextHotkey.start() }
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

    /// ⌘⇧B (default) — identical to toggleDictation() except it flags the session
    /// as smart, so stopDictation() runs the active polish style before pasting.
    /// Toggle-style, like Cmd+Shift+V — no separate PTT variant for this one.
    func beginSmartDictation() {
        toggleOrStop(mode: .smart)
    }

    /// ⌘⇧D — capture a long ramble, then structure it into the active brain-dump
    /// shape on stop. Toggle-style, like the dictation and smart-dictation shortcuts.
    func beginBrainDump() {
        toggleOrStop(mode: .brainDump)
    }

    private func toggleOrStop(mode: SessionMode) {
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            sessionMode = mode
            beginSession()
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
        sessionMode = .normal   // PTT is always normal dictation — never inherit a stale mode
        beginSession()
    }

    /// The synchronous preamble every dictation entry point shares: claim the
    /// state, wipe the last session's text, and put the warming pill on screen
    /// before any permission or capture work.
    ///
    /// **The transcript clear belongs here, not in `startDictation()`.** It used
    /// to live there, and `startDictation()` runs in a Task behind two awaited
    /// permission checks while `overlay.show` happens synchronously -- so the HUD
    /// rendered the PREVIOUS dictation's finalized text for the whole gap, about
    /// a second, before blanking. `stopDictation` can't clear it either: the exit
    /// flourish is still rendering that text as the panel animates away.
    ///
    /// The one place `dictation = .starting` is assigned, pinned by a test, so a
    /// future entry point cannot skip the clear by open-coding the preamble.
    private func beginSession() {
        overlayPreviewTask?.cancel()   // a settings Preview must not clobber a real session
        dictation = .starting
        sessionOverlayStyle = overlayStyle
        finalizedTranscript = ""
        volatileTranscript = ""
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

    /// ⌘⇧\\ (default). Guarded on dictation == .idle so this can't fire mid-session
    /// and race the dictation state machine — press it while dictating and it's
    /// simply ignored. Nothing is selected -> silent no-op (no overlay, no paste).
    func beginPolishSelectedText() {
        guard dictation == .idle else { return }
        Task { await runPolishSelectedText() }
    }

    private func runPolishSelectedText() async {
        // Named, not silent: a copy that doesn't land (nothing selected, or the
        // app didn't answer Cmd+C) is indistinguishable from a broken feature
        // otherwise — which is exactly how this looked when polish itself broke.
        guard let original = await PasteService.copySelection() else {
            await showFailure(label: "NOTHING SELECTED",
                              message: "Polish Selected Text: couldn't read a selection from the frontmost app.")
            return
        }
        overlayPhase = .polishing
        overlay.show(appState: self)
        let (result, failure) = await polishedText(for: original)
        overlay.hide()
        overlayPhase = .none
        pasteRespectingClipboardSettings(result)
        // Paste first, then report: the selection is restored either way, and a
        // 2.2s capsule must not delay putting the text back.
        if let failure { await showFailure(label: "POLISH FAILED", message: failure) }
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

        // Transcripts were cleared in beginSession(), synchronously, before the
        // overlay was shown — clearing them here instead is what made the last
        // sentence flash on screen while the permission checks above awaited.

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
                        // Join before fuzzy: "app cast" has to become a single
                        // token before the token-wise pass can even see it.
                        result = joinSplitTerms(result, dictionary: vocabSnapshot)
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

        // Non-nil only when Smart Dictation's polish genuinely broke — surfaced
        // after the overlay's exit below, so the capsule doesn't fight it.
        var polishFailure: String?
        if phase == .pasting {
            switch sessionMode {
            case .smart where !Self.tooShortForPolish(text):
                overlayPhase = .polishing
                (text, polishFailure) = await polishedText(for: text)
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
                pasteRespectingClipboardSettings(text)
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
        if let polishFailure { await showFailure(label: "POLISH FAILED", message: polishFailure) }
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
        defer {
            isReplyAssistDrafting = false
            overlay.hide()
            overlayPhase = .none
        }

        // Instant acknowledgement. AX resolution alone can take ~1.6s on
        // Electron trees, so showing this after it would answer the wrong
        // question. The HUD is non-activating and click-through, so it cannot
        // take focus from the field being replied into.
        overlayPhase = .drafting
        overlay.show(appState: self)

        // Fire-and-forget: regenerate the writing-tone profile from recent
        // dictation history (on-device only) so later drafts sound like the
        // user. Self-skips when tone.md is fresh or Foundation Models is off;
        // never blocks this draft.
        refreshToneProfileIfStale()

        // The app the user was in when they double-tapped -- the draft must land
        // in THIS app, not wherever focus drifts during the multi-second draft.
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let context = await ReplyContextReader.currentContext() else {
            await failReplyAssist(.noTextField)
            return
        }
        let conversation = ScreenContextReader.captureConversationText()
        // Counts and the app name only -- never the context itself, which is
        // whatever the user has on screen. Without this line a wrong draft
        // gives no evidence at all about why: the "Bake Sheet" invention on
        // 2026-08-06 could only be explained by reading the prompt-assembly
        // code and reasoning backwards.
        log.notice("""
            reply assist — app=\(conversation?.appName ?? "?", privacy: .public) \
            context=\(conversation?.text?.count ?? 0, privacy: .public) chars \
            mode=\(context.mode.logDescription, privacy: .public)
            """)
        guard !ReplyDraftPrompt.hasNothingToWorkFrom(mode: context.mode,
                                                     conversation: conversation?.text) else {
            await failReplyAssist(.noContext)
            return
        }
        await draftAndStream(mode: context.mode, intent: "",
                             conversation: conversation, targetPID: targetPID)
    }

    /// Show the cause in the HUD, record it, and clear after a beat. One path so
    /// no failure can be added later that forgets to surface itself.
    private func failReplyAssist(_ failure: ReplyAssistFailure) async {
        await showFailure(label: failure.overlayLabel, message: failure.message)
    }

    /// The HUD's error capsule for a feature that ran and produced nothing.
    /// Shared by reply assist and by the two shortcuts where polish IS the
    /// deliverable — there the fail-safe's raw text is not a consolation, it is
    /// the whole request silently failing.
    private func showFailure(label: String, message: String) async {
        errorMessage = message
        overlayPhase = .error(label: label)
        overlay.show(appState: self)
        try? await Task.sleep(for: .milliseconds(2200))
        overlay.hide()
        overlayPhase = .none
    }

    private func draftAndStream(mode: ReplyMode, intent: String,
                                conversation: ScreenContextReader.ConversationContext?,
                                targetPID: pid_t?) async {
        let tonePrefix = (try? String(contentsOf: ToneProfile.toneFileURL(), encoding: .utf8))
            .map { ToneProfile.promptPrefix(from: $0) }
        let style = ReplyDraftPrompt.style(mode: mode,
                                           appName: conversation?.appName,
                                           windowTitle: conversation?.windowTitle,
                                           windowContext: conversation?.text,
                                           tonePrefix: tonePrefix)
        guard let backend = activePolishBackend(for: .replyAssist) else {
            await failReplyAssist(.noBackend)
            return
        }
        let drafted: String
        do {
            drafted = try await backend.polish(intent, style: style, targetLanguage: nil)
        } catch {
            log.error("draftAndStream — polish failed: \(error)")
            await failReplyAssist(.draftFailed(error.localizedDescription))
            return
        }
        // Focus may have moved during the (up to 5s/30s) draft. Only type if the
        // app the user triggered from is still frontmost -- keystrokes post to
        // whatever app is frontmost at type time, so a drifted focus would land
        // the reply in the wrong field.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            log.warning("draftAndStream — frontmost app changed before typing; aborting")
            await failReplyAssist(.focusChanged)
            return
        }
        // The arriving text is the success signal; a "DRAFTED" beat would be
        // noise by the fortieth use. Hidden here rather than in the defer so it
        // is gone before the first keystroke lands.
        overlay.hide()
        overlayPhase = .none
        let result = await replyStreamTypist.stream(drafted)
        if case .declinedSentinel(let sentinel) = result {
            log.warning("draftAndStream — declined on sentinel: \(sentinel)")
            // The model saying "this is not a conversation" is a different
            // thing from a draft that looks like an error text, and the user
            // can act on the difference: one means try somewhere else, the
            // other means something broke.
            await failReplyAssist(sentinel == ReplyStreamTypist.noReplyContextSentinel
                                  ? .noContext : .sentinelDeclined)
        }
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
    /// `feature` selects which per-feature choice applies. Dictation polish and
    /// Reply Assist are separate choices for the same reason meetings and
    /// chronicles are: a draft written into someone else's chat window and a
    /// sentence you just dictated are not the same egress decision.
    ///
    /// A feature left on Default falls through to `polishBackend`, which keeps
    /// the AI tab's existing radio group meaning exactly what it means today.
    func activePolishBackend(for feature: AIFeature = .dictationPolish) -> PolishBackend? {
        switch backend(for: feature) {
        case .system:
            return SystemLLM.isAvailable() ? systemLLM : nil
        case .ollama(let model):
            return model.isEmpty ? nil : Ollama(baseURL: ollamaBaseURL, model: model)
        case .cloud:
            guard let key = Keychain.loadCloudLLMKey(), !key.isEmpty else { return nil }
            return CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key)
        case .useDefault:
            break
        }
        switch polishBackend {
        case .disabled: return nil
        case .system: return SystemLLM.isAvailable() ? systemLLM : nil
        case .ollama: return ollamaModel.isEmpty ? nil : Ollama(baseURL: ollamaBaseURL, model: ollamaModel)
        case .cloud:
            guard let key = Keychain.loadCloudLLMKey(), !key.isEmpty else { return nil }
            return CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key)
        }
    }

    /// Returns the text to paste plus, when polish genuinely broke, the message
    /// to show. `failure` is nil for configuration states (backend disabled, no
    /// active style) — the user turned polish off, that is not a fault. It is
    /// non-nil only when polish was asked for and could not run, because the
    /// fail-safe pastes the original and an unannounced fallback is
    /// indistinguishable from a working feature.
    private func polishedText(for original: String) async -> (text: String, failure: String?) {
        // Sarvam already produced English — paste as-is; never run the
        // translate/polish prompt on it, and no polish backend is required.
        if crossLingualUsesSarvam { return (original, nil) }
        // The one-time nudge fires only when System is selected but off — not for
        // Disabled or an unconfigured Ollama, which are deliberate "no polish" states.
        if polishBackend == .system, !SystemLLM.isAvailable() {
            Degradation.record(.polish, reason: SystemLLM.unavailableReason() ?? "on-device model unavailable")
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = systemUnavailableMessage("polish") + " Pasted raw text for now."
            }
            escalateDegradationIfNeeded(.polish)
            return (original, systemUnavailableMessage("polish") + " Pasted raw text.")
        }
        guard let backend = activePolishBackend() else {
            Degradation.recordUnlessConfiguration(.polish, reason: "backend disabled")
            return (original, nil)
        }
        let style: PolishStyle
        let target: String?
        if crossLingualEnabled {
            // original is the source-language transcript (backend present → we run
            // the LLM translate here) — or already English if Whisper's .translate
            // fallback ran, in which case a second polish pass is harmless cleanup.
            style = CrossLingual.style(spokenLanguage: spokenLanguageName, activeStyle: activePolishStyle)
            target = nil
        } else {
            guard let active = activePolishStyle else {
                Degradation.recordUnlessConfiguration(.polish, reason: "no active style")
                return (original, nil)
            }
            style = active
            target = active.requiresTargetLanguage ? translateTargetLanguage : nil
        }
        do {
            let polished = try await backend.polish(original, style: style, targetLanguage: target)
            Degradation.recordSuccess(.polish)
            return (polished, nil)
        } catch {
            log.error("polishedText — polish failed: \(error)")
            Degradation.record(.polish, reason: error.localizedDescription)
            escalateDegradationIfNeeded(.polish)
            return (original, "Polish failed: \(error.localizedDescription) Pasted your original text.")
        }
    }

    /// Raises the one-time alert when a feature has clearly stopped working.
    /// `escalationMessage` marks it warned, so this cannot fire twice for one
    /// streak however often it is called.
    private func escalateDegradationIfNeeded(_ feature: Degradation.Feature) {
        guard let message = Degradation.escalationMessage(feature) else { return }
        errorMessage = message
    }

    /// Structure a brain-dump ramble into the active shape via the active backend,
    /// grounded in the target app + captured screen terms. Any failure returns the
    /// raw ramble — words are never dropped (same rule as polishedText).
    private func brainDumpStructured(for original: String) async -> String {
        if polishBackend == .system, !SystemLLM.isAvailable() {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = systemUnavailableMessage("structure brain-dumps") + " Pasted raw text for now."
            }
            return original
        }
        // Long-form, not dictation: a ramble is large input the user is
        // deliberately waiting on, so it takes Ollama's 12,000-char envelope and
        // 300s timeout rather than the 30s dictation one, which a cold model
        // blows every time.
        let candidates = backends(for: .brainDump,
                                  ollamaChunkLimit: BrainDumpStructurer.ollamaChunkLimit,
                                  systemChunkLimit: BrainDumpStructurer.chunkCharLimit,
                                  cloudChunkLimit: BrainDumpStructurer.cloudChunkLimit)
        guard !candidates.isEmpty, let shape = activeBrainDumpShape else { return original }
        var parts: [String] = []
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { parts.append("Target app: \(app)") }
        if !sessionScreenTerms.isEmpty { parts.append("On-screen terms: \(sessionScreenTerms.prefix(20).joined(separator: ", "))") }
        let context = parts.isEmpty ? nil : parts.joined(separator: ". ")
        // Falls through the list rather than straight to raw text: Ollama being
        // down should cost the bigger envelope, not the structuring entirely.
        for candidate in candidates {
            do {
                return try await BrainDumpStructurer.structure(
                    transcript: original, shape: shape, context: context,
                    polish: candidate.polish, chunkLimit: candidate.chunkLimit)
            } catch {
                log.error("brainDumpStructured — \(String(describing: candidate.kind)) failed: \(error)")
            }
        }
        return original
    }

    /// Re-runs a past history entry's text through the current polish
    /// backend/style. Callers copy the result to the clipboard -- this never
    /// pastes into the frontmost app the way live dictation's stop-and-paste
    /// does, since there's no "target app" context for a hub-window action.
    func rePolish(_ text: String) async -> String {
        await polishedText(for: text).text
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
        // .polishing and .drafting are transient mid-flight states, restored to
        // phase before this is called — neither is an exit flourish.
        case .none, .polishing, .drafting: .zero
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
    static let restoreClipboard = "restoreClipboard"
    static let clipboardRestoreDelayMS = "clipboardRestoreDelayMS"
    static let appearancePreference = "appearancePreference"
    static let polishBackend = "polishBackend"
    static let defaultAIBackend = "defaultAIBackend"
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
    static let smartDictationShortcut = "smartDictationShortcut"
    static let polishSelectedShortcut = "polishSelectedShortcut"
    static let brainDumpShortcut = "brainDumpShortcut"
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
    static let meetingsCalendarEnabled = "meetingsCalendarEnabled"
    static let recordMeetingMic = "recordMeetingMic"
    static let meetingTemplateID = "meetingTemplateID"
    static let customMeetingTemplates = "customMeetingTemplates"
    static let replyAssistEnabled = "replyAssistEnabled"
    static let memoryEnabled = "memoryEnabled"
    static let memoryPaused = "memoryPaused"
    static let memoryRetentionDays = "memoryRetentionDays"
    static let memoryExcludedDomains = "memoryExcludedDomains"
    static let memoryExcludedApps = "memoryExcludedApps"
    static let memoryExcludedTitleKeywords = "memoryExcludedTitleKeywords"
    static let autoDeleteAfterDays = "autoDeleteAfterDays"
    static let mcpAccessEnabled = "mcpAccessEnabled"
    static let engineKind = "engineKind"
    static let parakeetModel = "parakeetModel"
    static let whisperModel = "whisperModel"
    static let whisperLanguage = "whisperLanguage"
    static let crossLingualEnabled = "crossLingualEnabled"
    static let crossLingualUseSarvam = "crossLingualUseSarvam"
    static let cloudProvider = "cloudProvider"
    static let overlayStyle = "overlayStyle"
}
