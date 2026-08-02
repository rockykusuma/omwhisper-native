//
//  OverlayView.swift
//  OmWhisper
//
//  Router for the dictation HUD's three presentation styles (OVERLAY_SPEC §3):
//  Full (pill + live words), Orb (orb only), Whisper line (micro-ॐ + bars). The
//  view is mounted ONCE for the panel's whole lifetime (see OverlayPanel), so
//  entrance/exit is animated via value-keyed `.animation`, never `.transition`.
//  The active style is frozen per session (sessionOverlayStyle) or driven by the
//  settings Preview (overlayPreview). Minimal styles morph to a labeled capsule
//  on error so failures always surface (§3).
//

import SwiftUI

struct OverlayView: View {
    /// Polish Selected Text shows the HUD WITHOUT starting a dictation session
    /// -- `dictation` stays .idle by design -- so `finalizedTranscript` still
    /// holds whatever was last DICTATED. Rendering it made the HUD look like
    /// that stale text was what was being polished.
    ///
    /// The settings preview also runs at .idle but fills the transcript on
    /// purpose, so it must keep showing: a bare "hide when idle" rule would
    /// silently empty the Preview button's demo.
    nonisolated static func showsTranscript(
        dictation: DictationState, phase: OverlayPhase, isPreview: Bool
    ) -> Bool {
        if isPreview { return true }
        if dictation != .idle { return true }
        return phase != .polishing
    }

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        appState.dictation != .idle || appState.overlayPhase == .polishing || appState.overlayPreview != nil
    }

    private var activeStyle: OverlayStyle {
        appState.overlayPreview ?? appState.sessionOverlayStyle
    }

    /// Minimal styles surface errors as a transient labeled capsule; Full shows
    /// the error inside its own pill.
    private var showsErrorCapsule: Bool {
        guard activeStyle != .full else { return false }
        if case .error = appState.overlayPhase { return true }
        return false
    }

    private var errorLabel: String {
        if case .error(let label) = appState.overlayPhase { return label }
        return ""
    }

    /// Small downward settle on a successful finalize (a modest stand-in for the
    /// spec's full +90pt slide — see the note in OverlayPanel).
    private var exitOffsetY: CGFloat {
        guard case .pasting = appState.overlayPhase else { return 0 }
        return 14
    }

    private var envelopeAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch appState.overlayPhase {
        case .cancelled: return .easeInOut(duration: 0.12)   // §4: 120ms fade, no translate
        default: return .easeInOut(duration: 0.3)
        }
    }

    var body: some View {
        content
            // Center the (variously-sized) style within the fixed-size panel in
            // SwiftUI, so a narrower style (Orb/Whisper-line) lands centered on the
            // very first show after a style change — not on the hosting view's
            // second layout pass, which left the first dictation off-center.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: exitOffsetY)
            .opacity(isVisible ? 1 : 0)
            .animation(envelopeAnimation, value: isVisible)
            .animation(envelopeAnimation, value: appState.overlayPhase)
            .animation(envelopeAnimation, value: activeStyle)
    }

    @ViewBuilder private var content: some View {
        if showsErrorCapsule {
            ErrorCapsule(label: errorLabel)
        } else {
            switch activeStyle {
            case .full:        FullStyleOverlay(appState: appState, isVisible: isVisible)
            case .orb:         OrbStyleOverlay(appState: appState, isVisible: isVisible)
            case .whisperLine: WhisperLineOverlay(appState: appState, isVisible: isVisible)
            }
        }
    }
}

// MARK: - Full style (the default pill — behavior preserved verbatim)

private struct FullStyleOverlay: View {
    let appState: AppState
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusLabel: String {
        switch appState.overlayPhase {
        case .pasting, .cancelled:
            return ""
        case .polishing:
            return "POLISHING"
        case .error(let label):
            return label
        case .none:
            switch appState.dictation {
            case .idle: return ""
            case .starting: return "…"
            case .recording: return "LISTENING"
            case .finalizing: return "FINALIZING"
            }
        }
    }

    private var labelColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        if case .polishing = appState.overlayPhase { return .omTeal }
        switch appState.dictation {
        case .recording: return .omTeal
        case .finalizing: return .omMint
        default: return .omVolatile
        }
    }

    private var borderColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        return .omBorder
    }

    private var transcriptText: Text {
        guard OverlayView.showsTranscript(dictation: appState.dictation,
                                   phase: appState.overlayPhase,
                                   isPreview: appState.overlayPreview != nil)
        else { return Text("") }
        var text = AttributedString(appState.finalizedTranscript)
        text.foregroundColor = .omGlyphCore
        var volatile = AttributedString(appState.volatileTranscript)
        volatile.foregroundColor = Color.omVolatile.opacity(0.5)
        text.append(volatile)
        return Text(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            orbZone
            VStack(alignment: .leading, spacing: 4) {
                if !statusLabel.isEmpty {
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(labelColor)
                }
                if appState.sessionMode == .brainDump, appState.dictation == .recording {
                    brainDumpZone
                } else {
                    transcriptZone
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 480, height: 90, alignment: .leading)
        .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(borderColor.opacity(0.35), lineWidth: 1)
        )
        .clipped()
    }

    private var orbZone: some View {
        ZStack {
            if isVisible {
                OmOrbView(appState: appState)
            }
        }
        .frame(width: 64, height: 64)
    }

    private var transcriptZone: some View {
        transcriptText
            .font(.system(size: 15))
            .multilineTextAlignment(.leading)
            .lineLimit(1...2)
            .truncationMode(.head)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: appState.finalizedTranscript)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: appState.volatileTranscript)
    }

    // Relaxed brain-dump readout — word count + elapsed, not a transcript to watch.
    private var brainDumpZone: some View {
        let words = (appState.finalizedTranscript + " " + appState.volatileTranscript)
            .split(whereSeparator: { $0.isWhitespace }).count
        return TimelineView(.periodic(from: .now, by: 1)) { _ in
            let secs = appState.recordingStartedAt.map { Int($0.duration(to: .now).components.seconds) } ?? 0
            Text("\(words) words · \(secs / 60):\(String(format: "%02d", secs % 60))")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.omGlyphCore)
        }
    }
}

// MARK: - Minimal-style error capsule

private struct ErrorCapsule: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Color.omError)
            .padding(.horizontal, 18)
            .frame(minWidth: 180, minHeight: 38)
            .background(Color.omBackground.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.omError.opacity(0.65), lineWidth: 1))
    }
}

#Preview {
    OverlayView().environment(AppState())
}
