//
//  GlobalHotkey.swift
//  OmWhisper
//
//  System-wide keyboard shortcut (default: Cmd+Shift+V, toggle dictation) that
//  fires even when OmWhisper isn't the frontmost app — the whole point of a
//  menu-bar dictation tool.
//
//  Uses a CGEventTap rather than NSEvent.addGlobalMonitorForEvents, because a
//  global NSEvent monitor can only OBSERVE: the keystroke still reaches the
//  frontmost app. That is not cosmetic. ⌘⇧P is Page Setup and ⌘| is Center in
//  every standard AppKit document app, so a shortcut bound there ran a menu
//  command in the user's document on every single use — polishing their text
//  and centring the paragraph at the same time. A tap inserted at the head of
//  the session can return nil and the event is never delivered to anyone.
//
//  ONE tap serves every hotkey (four of them today), so a keystroke traverses
//  the chain once and there is a single place to re-enable after the system
//  disables us. The per-app local monitor stays: it costs nothing, and it is
//  what still works when the tap cannot be created because the process is not
//  yet Accessibility-trusted. It cannot double-fire — if the tap exists and
//  swallows the event, WindowServer never delivers it, so the local monitor
//  never sees it.
//
//  Accessibility trust is required for the tap, which the app already needs
//  for CGEventPost paste (see PasteService) — no extra permission burden.
//

import AppKit
import os

// nonisolated: the C tap callback below is nonisolated and logs through this.
private nonisolated let hotkeyLog = Logger(subsystem: "com.omwhisper.mac", category: "GlobalHotkey")

/// C callback. `nonisolated` is load-bearing: this project defaults every
/// declaration to @MainActor, and a @MainActor function cannot be formed into a
/// C function pointer at all. Every CGEvent field is read HERE, in the
/// nonisolated context, so only Sendable values hop to the main actor — CGEvent
/// itself is not Sendable and must not cross.
///
/// The tap is attached to the MAIN run loop, so this genuinely runs on the main
/// thread; `assumeIsolated` traps loudly if that ever stops being true rather
/// than corrupting state quietly.
private nonisolated func globalHotkeyTapCallback(proxy: CGEventTapProxy,
                                                 type: CGEventType,
                                                 event: CGEvent,
                                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // The system disables a tap that ran too slowly or was flooded. Without
    // this the shortcut dies mid-session and looks like a random failure.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        hotkeyLog.warning("tap disabled by system (\(type.rawValue)) — re-enabling")
        MainActor.assumeIsolated { GlobalHotkey.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let rawMods = GlobalHotkey.modifierFlags(from: event.flags).rawValue
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    let swallow = MainActor.assumeIsolated {
        GlobalHotkey.handleTapped(keyCode: keyCode, rawMods: rawMods, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class GlobalHotkey {
    /// kVK_ANSI_V — same virtual keycode PasteService uses to synthesize Cmd+V.
    static let vKeyCode: UInt16 = 9

    private var keyCode: UInt16
    private var modifiers: NSEvent.ModifierFlags
    private let action: () -> Void

    private var localMonitor: Any?

    // MARK: The one shared tap

    /// While a KeyRecorderView is listening, the tap must let every keystroke
    /// through untouched. It swallows a matched combo at the head of the
    /// session, so rebinding a shortcut to one that is already bound would
    /// otherwise never reach the recorder's local monitor — the field would sit
    /// on "Press keys…" showing no conflict while the EXISTING hotkey fired,
    /// starting a dictation the user never asked for. A count, not a flag:
    /// clicking a second recorder before finishing the first is one click away,
    /// and a flag cleared by whichever finishes first re-arms the tap under the
    /// one still listening.
    private static var recordingCount = 0
    static var isRecordingShortcut: Bool { recordingCount > 0 }
    static func beginShortcutRecording() { recordingCount += 1 }
    static func endShortcutRecording() { recordingCount = max(0, recordingCount - 1) }

    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?
    private struct WeakHotkey { weak var hotkey: GlobalHotkey? }
    private static var registry: [WeakHotkey] = []

    /// False when the tap could not be created — which happens when the process
    /// isn't Accessibility-trusted. The shortcut then looks correctly configured
    /// and silently never fires outside OmWhisper's own windows, which is
    /// exactly the failure this app keeps hitting.
    var isInstalled: Bool { Self.tap != nil }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    func start() {
        stop()

        Self.registry.append(WeakHotkey(hotkey: self))
        Self.ensureTap()

        // Local monitor: the fallback when the tap doesn't exist (not yet
        // Accessibility-trusted). Returning nil swallows the event so it can't
        // also type into a focused field. When the tap IS live it swallows
        // first and this never runs.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !Self.isRecordingShortcut else { return event }
            if self.matches(keyCode: event.keyCode,
                            mods: event.modifierFlags.intersection(Self.relevantMask)) {
                if !event.isARepeat { self.action() }
                return nil
            }
            return event
        }

        hotkeyLog.info("start — tap=\(Self.tap != nil), local monitor=\(self.localMonitor != nil)")
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        Self.registry.removeAll { $0.hotkey == nil || $0.hotkey === self }
        if Self.registry.isEmpty { Self.teardownTap() }
    }

    /// Swap the binding and restart (start() stops first). Live shortcut changes.
    func reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        // The KeyRecorder captures the new combo from inside a local keyDown
        // monitor callback, so this runs mid-dispatch of that event. start()'s
        // stop() would removeMonitor a monitor AppKit is still iterating —
        // a use-after-free crash (worst when the new combo == the current one).
        // Defer the rebuild one runloop turn so the current event finishes first.
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    // MARK: Tap lifecycle

    private static func ensureTap() {
        guard tap == nil else { return }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,               // .listenOnly could not swallow — the whole point
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: globalHotkeyTapCallback,
            userInfo: nil
        ) else {
            hotkeyLog.warning("tap creation failed — not Accessibility-trusted? shortcuts are local-only")
            return
        }
        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        // Main run loop explicitly, so the C callback's assumeIsolated holds.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private static func teardownTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    fileprivate static func reenableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns whether to swallow the keystroke. Autorepeat is swallowed too but
    /// never fires the action: holding the combo must not leak a stream of
    /// keystrokes into the frontmost app, which is the whole reason this is a tap.
    fileprivate static func handleTapped(keyCode: UInt16, rawMods: UInt, isRepeat: Bool) -> Bool {
        guard !isRecordingShortcut else { return false }   // the recorder needs to see this key
        let mods = NSEvent.ModifierFlags(rawValue: rawMods)
        guard let hotkey = registry.compactMap(\.hotkey).first(where: { $0.matches(keyCode: keyCode, mods: mods) })
        else { return false }
        if !isRepeat {
            hotkeyLog.info("hotkey matched — firing action")
            // Off the tap's own callback: a slow action would make the system
            // disable the tap.
            Task { @MainActor in hotkey.action() }
        }
        return true
    }

    // MARK: Matching

    static let relevantMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    /// Pure: CGEventFlags → NSEvent.ModifierFlags, mapped bit by bit rather than
    /// by reinterpreting the raw value. The two types happen to share bit
    /// positions today; a shortcut that silently stops matching is the cost of
    /// relying on that.
    nonisolated static func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var mods: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand)   { mods.insert(.command) }
        if flags.contains(.maskShift)     { mods.insert(.shift) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskControl)   { mods.insert(.control) }
        return mods
    }

    private func matches(keyCode: UInt16, mods: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && mods == modifiers
    }
}
