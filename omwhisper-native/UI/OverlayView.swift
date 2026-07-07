//
//  OverlayView.swift
//  OmWhisper
//
//  Content of the floating recording overlay: a status dot + the live
//  transcript, with finalized text solid and the trailing volatile hypothesis
//  dimmed/italic (replaced in place as SpeechTranscriber refines it).
//

import SwiftUI

struct OverlayView: View {
    @Environment(AppState.self) private var appState

    private var statusColor: Color {
        switch appState.dictation {
        case .recording: return .red
        case .finalizing: return .yellow
        case .idle, .starting: return .gray   // overlay isn't shown until .recording; .starting is cosmetic
        }
    }

    /// Finalized (solid) + volatile (dimmed/italic) as one AttributedString —
    /// `Text + Text` concatenation is deprecated on macOS 26; this is the
    /// replacement for combining differently-styled runs (not the same case as
    /// the deprecation's own "use string interpolation" suggestion, which only
    /// fits plain uniformly-styled text).
    private var transcriptText: Text {
        var text = AttributedString(appState.finalizedTranscript)
        text.foregroundColor = .primary

        var volatile = AttributedString(appState.volatileTranscript)
        volatile.foregroundColor = .secondary
        volatile.inlinePresentationIntent = .emphasized

        text.append(volatile)
        return Text(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            Group {
                if appState.finalizedTranscript.isEmpty && appState.volatileTranscript.isEmpty {
                    Text(appState.dictation == .finalizing ? "Finishing up…" : "Listening…")
                        .foregroundStyle(.secondary)
                } else {
                    transcriptText
                }
            }
            .font(.system(size: 14))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8)
    }
}

#Preview {
    OverlayView().environment(AppState())
}
