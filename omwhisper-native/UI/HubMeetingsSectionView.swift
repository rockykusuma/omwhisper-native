//
//  HubMeetingsSectionView.swift
//  OmWhisper
//
//  The hub's Meetings section: the detect-and-record toggle over a browse UI
//  (searchable list + transcript/summary detail with a per-meeting
//  "Transcribe & Summarize" button). Replaces the toggle-only MeetingsSettingsView.
//  On-device transcription/summary via AppState.transcribeMeeting.
//

import SwiftUI

struct HubMeetingsSectionView: View {
    @Environment(AppState.self) private var appState

    @State private var meetings: [Meeting] = []
    @State private var selectedID: Int64?
    @State private var searchText = ""
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            settingsBar(state: state)
            Divider()
            if state.meetingsEnabled || !meetings.isEmpty {
                browser
            } else {
                disabledEmptyState
            }
        }
        .background(Color.Porcelain.bg)
        .task(id: searchText) { await reload() }
        // A recording that finished while this view is open transcribes in the
        // background; picking up its transcript needs a reload once it lands.
        .task(id: appState.transcribingMeetingIDs) { await reload() }
    }

    private func settingsBar(state: AppState) -> some View {
        HStack {
            Toggle("Detect and record meetings", isOn: Binding(
                get: { state.meetingsEnabled }, set: { state.meetingsEnabled = $0 }
            ))
            .tint(Color.Porcelain.emerald)
            .foregroundStyle(Color.Porcelain.ink)
            Spacer()
            Button { state.toggleMeetingRecording() } label: {
                HStack(spacing: 6) {
                    if state.isRecordingMeeting {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Stop recording")
                    } else {
                        Image(systemName: "waveform")
                        Text("Start recording")
                    }
                }
            }
            .tint(Color.Porcelain.emerald)
        }
        .padding(12)
    }

    private var browser: some View {
        NavigationSplitView {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(meetings) { meeting in
                        Button { selectedID = meeting.id } label: {
                            meetingRow(meeting)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(meeting.appName), \(shortDate(meeting.startedAt))")
                        .accessibilityAddTraits(selectedID == meeting.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(12)
            }
            .background(Color.Porcelain.bg)
            .searchable(text: $searchText, prompt: "Search meetings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.appName).fontWeight(.medium).foregroundStyle(Color.Porcelain.ink)
            Text("\(shortDate(meeting.startedAt)) · \(durationText(meeting.durationSeconds)) · \(status(meeting))")
                .font(.caption).foregroundStyle(Color.Porcelain.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .omRowCard()
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedID, let meeting = meetings.first(where: { $0.id == selectedID }) {
            MeetingDetailView(meeting: meeting, onChanged: { await reload() })
        } else {
            Text("Select a meeting")
                .foregroundStyle(Color.Porcelain.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Porcelain.bg)
        }
    }

    private var disabledEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("👥").font(.system(size: 40))
            Text("Turn on meeting recording above. When a call app is active you'll be asked for consent, and recordings stay on this Mac.")
                .foregroundStyle(Color.Porcelain.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        guard let store = appState.meetingStore else { return }
        do {
            let trimmed = searchText.trimmingCharacters(in: .whitespaces)
            meetings = trimmed.isEmpty ? try store.fetchPage(offset: 0, limit: 100) : try store.search(trimmed, limit: 100)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func status(_ meeting: Meeting) -> String {
        if let id = meeting.id, appState.transcribingMeetingIDs.contains(id) { return "Transcribing…" }
        if meeting.summary != nil { return "Summarized" }
        if meeting.transcript != nil { return "Transcribed" }
        return "Recorded"
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private func durationText(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

private struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    let onChanged: () async -> Void

    @State private var working = false
    @State private var errorMessage: String?

    /// Busy for either reason: this view kicked off a transcribe, or the meeting
    /// is still being auto-transcribed from when its recording stopped.
    private var busy: Bool {
        working || (meeting.id.map { appState.transcribingMeetingIDs.contains($0) } ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(meeting.appName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)

                HStack(spacing: 10) {
                    Button(busy ? "Working…" : (meeting.transcript == nil ? "Transcribe & Summarize" : "Re-transcribe")) {
                        run()
                    }
                    .disabled(busy)
                    Button("Delete", role: .destructive) { delete() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }

                if let summary = meeting.summary, !summary.isEmpty {
                    section("Summary", markdown: summary)
                }
                if let transcript = meeting.transcript, !transcript.isEmpty {
                    section("Transcript", markdown: transcript)
                } else if !busy {
                    Text("Not transcribed yet — tap Transcribe & Summarize.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.Porcelain.bg)
    }

    private func section(_ title: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Color.Porcelain.dim)
            Text(.init(markdown)).textSelection(.enabled).foregroundStyle(Color.Porcelain.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .omCard()
    }

    private func run() {
        guard let id = meeting.id else { return }
        working = true
        errorMessage = nil
        Task {
            do { _ = try await appState.transcribeMeeting(id: id) }
            catch { errorMessage = error.localizedDescription }
            await onChanged()
            working = false
        }
    }

    private func delete() {
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        try? store.delete(id: id)
        Task { await onChanged() }
    }
}
