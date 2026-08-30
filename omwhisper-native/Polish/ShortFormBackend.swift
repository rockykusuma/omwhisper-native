//
//  ShortFormBackend.swift
//  OmWhisper
//
//  The short-form half of what LongFormBackends does for meetings, chronicles
//  and brain-dump: resolve a feature's choice against the Default row.
//
//  It exists because that resolution used to fall through to `polishBackend`
//  here and to `defaultBackend` there, so "Default" meant two different things
//  depending on which feature asked, and "Disabled" silenced two features out
//  of five while reading as global.
//

import Foundation

nonisolated enum ShortFormBackend {
    /// nil means "no backend" — either dictation polish is switched off, or
    /// nothing has been chosen at any level. Callers treat nil as a
    /// configuration state, never as a failure.
    static func resolve(feature: AIFeature,
                        choice: FeatureBackend,
                        defaultChoice: FeatureBackend,
                        dictationPolishEnabled: Bool) -> FeatureBackend? {
        // The toggle is dictation polish's own off-switch, not a global one.
        if feature == .dictationPolish, !dictationPolishEnabled { return nil }
        let resolved = (choice == .useDefault) ? defaultChoice : choice
        return resolved == .useDefault ? nil : resolved
    }
}
