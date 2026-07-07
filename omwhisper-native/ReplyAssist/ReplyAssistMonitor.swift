//
//  ReplyAssistMonitor.swift
//  OmWhisper
//
//  Detects a double-tap of the RIGHT Option key anywhere (global) or while
//  OmWhisper itself is frontmost (local), and fires onTriggered. Modeled
//  directly on PushToTalkMonitor.swift's NSEvent.flagsChanged monitor pattern
//  -- NOT smriti's 30ms CGEventSource polling, which exists there specifically
//  because smriti runs as a launchd-spawned daemon ("event taps and NSEvent
//  global monitors are unreliable for launchd-spawned agents"). OmWhisper is a
//  normal app bundle; PushToTalkMonitor already proves NSEvent monitors work
//  reliably here for exactly this kind of modifier-only gesture.
//
//  Right vs. left Option is distinguished via NSEvent.keyCode (61 = right
//  Option) -- the higher-level API this app already relies on, simpler than
//  smriti's raw NX_DEVICERALTKEYMASK device-bit check.
//
//  Requires Accessibility trust for the global monitor, like PushToTalkMonitor
//  and GlobalHotkey -- no new permission burden.
//

import AppKit

@MainActor
final class ReplyAssistMonitor {
    private static let rightOptionKeyCode: UInt16 = 61

    var onTriggered: (() -> Void)?
    /// Checked before firing onTriggered -- AppState sets this to
    /// `{ self.dictation != .idle }`, matching MeetingWatcher.isSuppressed's
    /// contract exactly: a double-tap during dictation must never even
    /// register as a pending trigger, not just be ignored downstream.
    var isSuppressed: () -> Bool = { false }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var isRightOptionDown = false
    private var detector = DoubleTapDetector()

    func start() {
        stop()
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        // Any regular keystroke (e.g. the "4" in ⌥4→€) interrupts a pending
        // tap so it's never mistaken for the second half of a double-tap.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.detector.interrupt()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.detector.interrupt()
            return event
        }
    }

    func stop() {
        for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        isRightOptionDown = false
        detector.interrupt()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let isDown = event.modifierFlags.contains(.option)
        guard isDown != isRightOptionDown else { return }
        isRightOptionDown = isDown
        guard isDown else { return }  // only the press counts as a tap, not the release
        // Cmd/Ctrl/Shift held alongside right-⌥ means this is part of some
        // other shortcut, not a reply-assist trigger -- and it interrupts any
        // pending pair rather than silently ignoring it.
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift) else {
            detector.interrupt()
            return
        }
        guard detector.tapDetected(at: event.timestamp) else { return }
        guard !isSuppressed() else { return }
        onTriggered?()
    }
}
