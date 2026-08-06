//
//  ReplyAssistFailure.swift
//  OmWhisper
//
//  The five ways a reply draft can fail, each with the short label the overlay
//  shows and the longer message AppState records.
//
//  One type rather than five scattered string literals because the user needs
//  to tell them APART: "no text field" and "no AI backend" are both fixable in
//  seconds if named, and indistinguishable if not.
//

import Foundation

nonisolated enum ReplyAssistFailure: Equatable {
    case noTextField
    case noBackend
    case draftFailed(String)
    case focusChanged
    case sentinelDeclined

    /// Short, uppercase, capsule-sized -- matching "NOTHING HEARD".
    var overlayLabel: String {
        switch self {
        case .noTextField:      return "NO TEXT FIELD"
        case .noBackend:        return "NO AI BACKEND"
        case .draftFailed:      return "DRAFT FAILED"
        case .focusChanged:     return "FOCUS CHANGED"
        case .sentinelDeclined: return "DRAFT LOOKED WRONG"
        }
    }

    /// The detail. Kept out of the label, which has to stay short.
    var message: String {
        switch self {
        case .noTextField:
            return "Reply assist: couldn't read the focused field."
        case .noBackend:
            return "Reply assist needs an AI polish backend enabled in AI settings."
        case .draftFailed(let reason):
            return "Reply assist: draft failed (\(reason))."
        case .focusChanged:
            return "Reply assist: focus changed, nothing was typed."
        case .sentinelDeclined:
            return "Reply assist: the draft looked like an error, nothing was typed."
        }
    }
}
