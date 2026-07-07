//
//  OverlayView.swift
//  OmWhisper
//
//  The Om Orb overlay content — see docs/OVERLAY_SPEC.md. This phase ships the
//  static pill: correct palette/layout/label states, driven entirely by
//  `AppState.dictation`/`overlayPhase`. The view is mounted ONCE for the
//  panel's whole lifetime (see OverlayPanel — it caches one NSHostingView),
//  so entrance/exit is animated via value-keyed `.animation`, never
//  `.transition` (which only fires on insert/remove, and this view never
//  unmounts).
//
//  ponytail: entrance spring-overshoot (§4) is a plain fade here, and the exit
//  slide (§8) is a modest 14pt settle rather than the full +90pt — sliding that
//  far inside a ~100pt panel clips at the edge unless the panel gets extra
//  headroom, which is exactly the kind of thing to size by eye against the
//  running app, not guess at here. True per-word entrance + common-prefix
//  diffing (§7) would need a custom flowing-text layout (SwiftUI has no
//  built-in per-run-animated wrapping text); the whole-block crossfade below
//  gets most of the visual benefit (no hard-cut recolor) at a fraction of the
//  engineering cost — upgrade to per-word only if the block-level crossfade
//  reads as jittery once seen live.
//

import SwiftUI

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool { appState.dictation != .idle }

    private var statusLabel: String {
        switch appState.overlayPhase {
        case .pasting, .cancelled:
            return ""
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
        switch appState.dictation {
        case .recording: return .omTeal
        case .finalizing: return .omMint
        default: return .omVolatile
        }
    }

    /// Border flashes omError during the error exit flourish (§4: "border +
    /// label flash omError"); the resting brand border otherwise.
    private var borderColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        return .omBorder
    }

    /// Small downward settle on a successful finalize — see the ponytail note
    /// above on why this isn't the spec's full +90pt slide.
    private var exitOffsetY: CGFloat {
        guard case .pasting = appState.overlayPhase else { return 0 }
        return 14
    }

    private var pillAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch appState.overlayPhase {
        case .cancelled: return .easeInOut(duration: 0.12)   // §4: 120ms fade, no translate
        default: return .easeInOut(duration: 0.3)
        }
    }

    /// Finalized (solid core) + volatile (dimmed mint) as one AttributedString.
    /// No italic (dropped `.emphasized` per §7 — color alone carries the meaning,
    /// and italic + color double-encodes and jitters as words re-render).
    private var transcriptText: Text {
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
                transcriptZone
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Height must fit its own content: the 64pt orb zone + 12pt padding on
        // each side needs 88pt minimum — the spec's own "~82pt" anatomy figure
        // was 6pt short of that, which was starving the transcript column of
        // its requested space and corrupting the 2-line clip/mask below.
        .frame(width: 480, height: 90, alignment: .leading)
        .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(borderColor.opacity(0.35), lineWidth: 1)
        )
        .clipped()   // defensive: nothing (orb, text) can bleed past the pill's own bounds
        .offset(y: exitOffsetY)
        .opacity(isVisible ? 1 : 0)
        .animation(pillAnimation, value: isVisible)
        .animation(pillAnimation, value: appState.overlayPhase)
    }

    private var orbZone: some View {
        ZStack {
            // Mount-gated on dictation != .idle (not merely hidden) so the
            // TimelineView driving OmOrbView's Canvas doesn't tick at all while
            // the panel is ordered out — see OVERLAY_SPEC.md §10.
            if isVisible {
                OmOrbView(appState: appState)
            }
        }
        .frame(width: 64, height: 64)
    }

    private var transcriptZone: some View {
        let lineHeight: CGFloat = 15 * 1.55
        // No "Listening…"/"Finishing up…" placeholder here — the status label
        // above already says LISTENING/FINALIZING; repeating it in the
        // transcript zone too just says the same thing twice. Blank until real
        // words arrive reads fine given the label + reactive orb are already
        // communicating the state.
        return transcriptText
            .font(.system(size: 15))
        // No .lineLimit here on purpose: it would truncate to the FIRST N lines
        // (tail-cut with an ellipsis), which is the opposite of what we want —
        // freezing the view once text exceeds 2 lines instead of scrolling.
        .multilineTextAlignment(.leading)
        // Without this, Text can use the frame's PROPOSED height (not just
        // width) to decide how many lines to even lay out — silently limiting
        // it to what fits, rather than growing past it for .clipped() below to
        // trim. fixedSize forces Text to report its full natural height
        // (still wrapping to the proposed WIDTH) regardless of what height the
        // frame constrains it to — this is what actually makes "grow, then
        // clip the overflow" work instead of "truncate invisibly."
        .fixedSize(horizontal: false, vertical: true)
        // maxHeight (not a fixed height) so a single line hugs the label
        // directly instead of always reserving a phantom second line's worth
        // of empty space above it — the cap still kicks in once content grows
        // past 2 lines, clipping/scrolling exactly as before.
        .frame(maxHeight: lineHeight * 2, alignment: .bottom)
        .clipped()
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 8)
                Color.black
            }
        )
        // Whole-block crossfade on every transcript change — see the type's
        // header comment on why this is block-level, not per-word.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: appState.finalizedTranscript)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: appState.volatileTranscript)
    }
}

#Preview {
    OverlayView().environment(AppState())
}
