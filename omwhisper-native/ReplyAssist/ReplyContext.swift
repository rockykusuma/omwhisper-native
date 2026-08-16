//
//  ReplyContext.swift
//  OmWhisper
//
//  Classifies the focused text field into reply/continue/rewrite, and
//  resolves that focused element via AX. Focused-element resolution and the
//  placeholder-vs-value gotcha are ported directly from smriti's
//  AssistListener.swift (same author, MIT, read-only reference) -- both are
//  hard-won against real Electron/web app behavior, not guessed:
//
//  - Web/Electron fields return their placeholder text as the AX *value*
//    when the field is actually empty. classify() strips a value that
//    exactly matches the placeholder before deciding the mode, or an empty
//    field gets mistaken for a non-empty draft.
//  - Electron/Chromium apps report NoValue for kAXFocusedUIElementAttribute
//    until their accessibility tree is switched on -- flipping
//    AXManualAccessibility/AXEnhancedUserInterface and retrying (big trees
//    like Claude/Teams can take over a second) is required, not optional.
//
//  Concurrency: focusedElement()/currentContext() are @MainActor (AXUIElement
//  calls have no documented off-main-thread guarantee, unlike the
//  NSWorkspace-only reads in ScreenContextReader), and use Task.sleep instead
//  of smriti's blocking usleep so the retry loop never freezes the app.
//

import AppKit
import ApplicationServices

nonisolated enum ReplyMode: Equatable {
    case reply
    case continueDraft(String)
    case rewrite(String)

    /// For the log: the mode and how much material it carries, never the
    /// material itself. `String(describing:)` truncated to a fixed width was
    /// the first attempt and it printed exactly "continueDraft(" — a
    /// diagnostic that stops where the interesting part starts. The character
    /// count is the number that matters: an empty compose box classified as a
    /// continuation is a misclassification, and only the length reveals it.
    var logDescription: String {
        switch self {
        case .reply:                 return "reply"
        case .continueDraft(let d):  return "continue(\(d.count) chars)"
        case .rewrite(let s):        return "rewrite(\(s.count) chars)"
        }
    }
}

nonisolated struct ReplyContext {
    let mode: ReplyMode
}

nonisolated enum ReplyContextReader {
    static func classify(value: String?, placeholder: String?, selection: String?) -> ReplyMode {
        if let selection, selection.count > 3 {
            return .rewrite(selection)
        }
        let effectiveValue: String?
        if let value, let placeholder, value == placeholder {
            effectiveValue = nil
        } else {
            effectiveValue = value
        }
        if let effectiveValue, !effectiveValue.isEmpty {
            return .continueDraft(effectiveValue)
        }
        return .reply
    }

    @MainActor
    static func currentContext() async -> ReplyContext? {
        guard let element = await focusedElement() else { return nil }
        let value = axStringValue(element, kAXValueAttribute as String)
        let placeholder = axStringValue(element, kAXPlaceholderValueAttribute as String)
        let selection = axStringValue(element, kAXSelectedTextAttribute as String)
        return ReplyContext(mode: classify(value: value, placeholder: placeholder, selection: selection))
    }

    @MainActor
    static func focusedElement(maxRetries: Int = 8, retryDelay: Duration = .milliseconds(200)) async -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let appElement = AX.appElement(pid: app.processIdentifier) else { return nil }

        if let focused = copyElement(appElement, kAXFocusedUIElementAttribute as String) {
            return focused
        }

        // The system-wide element often reports focus when the per-app query
        // returns NoValue (some Electron builds).
        let systemWide = AX.systemWideElement()
        if let focused = copyElement(systemWide, kAXFocusedUIElementAttribute as String) {
            return focused
        }

        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        for _ in 0..<maxRetries {
            try? await Task.sleep(for: retryDelay)
            if let focused = copyElement(appElement, kAXFocusedUIElementAttribute as String)
                ?? copyElement(systemWide, kAXFocusedUIElementAttribute as String) {
                return focused
            }
        }

        // Last resort: walk the focused window for the element that claims
        // keyboard focus (AXFocused == true).
        if let window = copyElement(appElement, kAXFocusedWindowAttribute as String),
           let focused = findFocusDescendant(window, depth: 0) {
            return focused
        }
        return nil
    }

    private static func findFocusDescendant(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if let focused = copyAttribute(element, kAXFocusedAttribute as String) as? Bool, focused,
           isEditable(element) {
            return element
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findFocusDescendant(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let role = (copyAttribute(element, kAXRoleAttribute as String) as? String) ?? ""
        if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole {
            return true
        }
        // Web content (e.g. LinkedIn comment boxes) often reports a generic
        // role but still supports selected-text editing.
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return settable.boolValue
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axStringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }
}
