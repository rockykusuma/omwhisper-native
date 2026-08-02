//
//  MemoryChroniclesView.swift
//  OmWhisper
//
//  Day list (left) + chronicle detail (right). SwiftUI-native replacement
//  for smriti's raw AppKit ChronicleTimelineSection -- that file is layout
//  reference only, per this project's established "UI sections: rebuild,
//  smriti is wireframe reference" convention (see S1's port map).
//

import SwiftUI

struct MemoryChroniclesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.hubNavigate) private var hubNavigate

    @State private var chronicles: [MemoryChronicle] = []
    @State private var selectedDay: String?
    @State private var isRegenerating = false
    @State private var errorMessage: String?
    /// Whether the failure was "no usable AI backend" rather than, say, "no
    /// snapshots that day". Only then is an AI-settings shortcut relevant --
    /// offering it for every error would send people somewhere that can't help.
    @State private var errorIsBackend = false

    /// A plain HStack, deliberately NOT a NavigationSplitView — the same fix as
    /// Meetings: this already sits inside HubShellView's NavigationSplitView, and
    /// macOS reads the nested pair as a three-column layout, reserving a dead band
    /// between the day list and the chronicle.
    var body: some View {
        HStack(spacing: 0) {
            dayList
            Divider()
            detail
        }
        .task { load() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            // The message names the backend to switch to; this opens the place
            // to switch it, rather than telling the user to go and find it.
            if errorIsBackend {
                Button("Open AI settings") {
                    errorMessage = nil
                    hubNavigate(.aiPolish)
                }
            }
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var dayList: some View {
        VStack(spacing: 0) {
            // Always visible (not just when a chronicle is selected) -- with zero
            // chronicles generated yet (the normal first-run state), this is the
            // only way to ever produce the first one. Also doubles as "regenerate
            // today" since Chronicler.generate always overwrites.
            // ponytail: only regenerates today, not an arbitrary past day --
            // add a per-day action if users need to fix an older chronicle.
            Button {
                generateTodaysChronicle()
            } label: {
                HStack(spacing: 6) {
                    if isRegenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 11))
                    }
                    Text(isRegenerating ? "Generating…" : "Generate today")
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(isRegenerating)
            .padding(11)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(chronicles) { chronicle in
                        Button { selectedDay = chronicle.day } label: {
                            chronicleRow(chronicle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chronicle.day), \(chronicle.snapshotCount) snapshots")
                        .accessibilityAddTraits(selectedDay == chronicle.day ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(9)
            }
        }
        .frame(width: 200)
        .background(Color.Porcelain.bg)
    }

    private func chronicleRow(_ chronicle: MemoryChronicle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chronicle.day)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Porcelain.ink)
            Text("\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Color.Porcelain.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selectedDay == chronicle.day ? Color.Porcelain.accentTint : Color.Porcelain.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(selectedDay == chronicle.day ? Color.Porcelain.emerald.opacity(0.45) : Color.Porcelain.hair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private var detail: some View {
        if chronicles.isEmpty {
            emptyState
        } else if let selectedDay, let chronicle = chronicles.first(where: { $0.day == selectedDay }) {
            VStack(spacing: 0) {
                chronicleHeader(chronicle)
                Divider()
                ScrollView {
                    // A chronicle is prose to read, not a form: same measure as a
                    // meeting transcript, and its "## " headings become real
                    // eyebrows rather than literal text.
                    MarkdownSections(markdown: chronicle.summary, fallbackTitle: "Chronicle")
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 22)
                }
            }
            .background(Color.Porcelain.bg)
        } else {
            Text("Select a day")
                .foregroundStyle(Color.Porcelain.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Porcelain.bg)
        }
    }

    private func chronicleHeader(_ chronicle: MemoryChronicle) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 15))
                .foregroundStyle(Color.Porcelain.dim)
                .frame(width: 38, height: 38)
                .background(Color.Porcelain.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(chronicle.day)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text("\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")  ·  Written on this Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(Color.Porcelain.panel)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("📅").font(.system(size: 40))
            Text("Chronicles appear here once a day, generated automatically. Use \"Generate Today's Chronicle\" above to create the first one now.")
                .foregroundStyle(Color.Porcelain.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Porcelain.bg)
    }

    private func load() {
        guard let store = appState.memoryStore else { return }
        do {
            chronicles = try store.listChronicles(limit: 60)
            if selectedDay == nil { selectedDay = chronicles.first?.day }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateTodaysChronicle() {
        isRegenerating = true
        Task {
            defer { isRegenerating = false }
            do {
                let result = try await appState.regenerateChronicle(day: Chronicler.dayString())
                load()
                selectedDay = result.day
            } catch {
                if case Chronicler.ChroniclerError.backendUnavailable = error {
                    errorIsBackend = true
                } else {
                    errorIsBackend = false
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    MemoryChroniclesView().environment(AppState())
}
