//
//  Degradation.swift
//  OmWhisper
//
//  Records that a feature ran and produced nothing useful, so a feature which
//  quietly stopped working becomes discoverable.
//
//  Exists because several features fail SAFE -- polish pastes the original
//  text, memory capture stores nothing -- which makes a broken feature
//  indistinguishable from a working one. Apple Intelligence never worked on an
//  en-IN Mac (not one of Foundation Models' 23 locales, while `availability`
//  still reports `.available`), so Smart Dictation, Polish Selected,
//  brain-dump and Reply Assist returned raw text for MONTHS with nothing
//  anywhere saying so.
//
//  Occasional fallback stays silent on purpose: a flaky network nagging on
//  every paste teaches people to ignore the alert, which is worse than no
//  alert. Persistent fallback means the feature is dead, and that is the case
//  worth interrupting for.
//

import Foundation

@MainActor
enum Degradation {
    enum Feature: String, CaseIterable {
        case polish
        case memoryCapture

        /// Consecutive failures before saying something. These differ because
        /// the cadences differ: ten dictations is a session, but capture ticks
        /// every 5 seconds so ten would be under a minute of window-switching.
        var threshold: Int {
            switch self {
            case .polish: 10
            case .memoryCapture: 120
            }
        }

        var label: String {
            switch self {
            case .polish: "Polish"
            case .memoryCapture: "Memory capture"
            }
        }

        var streakKey: String { "degradation.\(rawValue).streak" }
        var reasonKey: String { "degradation.\(rawValue).reason" }
        var warnedKey: String { "degradation.\(rawValue).warned" }
    }

    /// Pure: the whole escalation decision, so it is testable without storage.
    nonisolated static func shouldEscalate(streak: Int, threshold: Int, alreadyWarned: Bool) -> Bool {
        !alreadyWarned && streak >= threshold
    }

    /// Reasons that mean "the user turned this off", not "this is broken".
    /// Recording these would fire the alert at people who deliberately
    /// disabled something.
    static let configurationReasons = [
        "backend disabled", "no active style", "nothing to polish",
        "cross-lingual via Sarvam", "paused", "excluded",
    ]

    /// One more consecutive failure. Best-effort: a storage problem must never
    /// stop the thing being observed -- this is telemetry, not the feature.
    static func record(_ feature: Feature, reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: feature.streakKey) + 1, forKey: feature.streakKey)
        defaults.set(reason, forKey: feature.reasonKey)
    }

    /// Records only genuine faults. Configuration states pass through silently
    /// and, like a success, they do not extend an existing streak either.
    static func recordUnlessConfiguration(_ feature: Feature, reason: String) {
        guard !configurationReasons.contains(reason) else { return }
        record(feature, reason: reason)
    }

    /// The feature worked. Clears the streak AND the warned flag, so a later
    /// streak can escalate again rather than staying permanently muted.
    static func recordSuccess(_ feature: Feature) {
        guard UserDefaults.standard.integer(forKey: feature.streakKey) > 0
                || UserDefaults.standard.bool(forKey: feature.warnedKey) else { return }
        reset(feature)
    }

    static func reset(_ feature: Feature) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: feature.streakKey)
        defaults.removeObject(forKey: feature.reasonKey)
        defaults.removeObject(forKey: feature.warnedKey)
    }

    static func state(_ feature: Feature) -> (streak: Int, reason: String?) {
        let defaults = UserDefaults.standard
        return (defaults.integer(forKey: feature.streakKey), defaults.string(forKey: feature.reasonKey))
    }

    /// Non-nil exactly when this call should raise the one-time alert. Marks
    /// the feature warned as a side effect, so callers cannot accidentally
    /// fire it twice for one streak.
    static func escalationMessage(_ feature: Feature) -> String? {
        let defaults = UserDefaults.standard
        let streak = defaults.integer(forKey: feature.streakKey)
        let warned = defaults.bool(forKey: feature.warnedKey)
        guard shouldEscalate(streak: streak, threshold: feature.threshold, alreadyWarned: warned)
        else { return nil }
        defaults.set(true, forKey: feature.warnedKey)
        let reason = defaults.string(forKey: feature.reasonKey) ?? "reason unknown"
        return "\(feature.label) hasn't run in your last \(streak) attempts. \(reason)"
    }

    /// One line per feature for Debug Info. Silent features are omitted, so a
    /// healthy install produces nothing rather than a wall of zeroes.
    static func debugSummary() -> [String] {
        Feature.allCases.compactMap { feature in
            let current = state(feature)
            guard current.streak > 0 else { return nil }
            return "\(feature.label): \(current.streak) consecutive — \(current.reason ?? "reason unknown")"
        }
    }
}
