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

    /// A plain HStack, deliberately NOT a NavigationSplitView: this view already
    /// lives inside HubShellView's NavigationSplitView, and macOS reads the nested
    /// pair as a three-column layout — it reserved a wide empty band between the
    /// list and the transcript that no padding could remove.
    private var browser: some View {
        HStack(spacing: 0) {
            meetingList
            Divider()
            detail
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(meetings) { meeting in
                        Button { selectedID = meeting.id } label: {
                            meetingRow(meeting)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(meeting.appName), \(shortDate(meeting.startedAt))")
                        .accessibilityAddTraits(selectedID == meeting.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(9)
            }
        }
        .frame(width: 248)
        .background(Color.Porcelain.bg)
    }

    private var searchField: some View {
        PorcelainSearchField(text: $searchText, prompt: "Search meetings")
            .padding(11)
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.appName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Porcelain.ink)
            Text("\(shortDate(meeting.startedAt)) · \(durationText(meeting.durationSeconds))")
                .font(.system(size: 11))
                .foregroundStyle(Color.Porcelain.dim)
            statusPill(meeting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selectedID == meeting.id ? Color.Porcelain.accentTint : Color.Porcelain.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(selectedID == meeting.id ? Color.Porcelain.emerald.opacity(0.45) : Color.Porcelain.hair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    /// A recording that captured nothing reads as a failure, not a state — it
    /// carries the permission note as its transcript, so "Summarized" would be a lie.
    private func statusPill(_ meeting: Meeting) -> some View {
        let failed = meeting.durationSeconds < 1
        return Text(failed ? "No audio" : status(meeting).uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(failed ? Color.Porcelain.dim : Color.Porcelain.emerald)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(failed ? Color.Porcelain.panel2 : Color.Porcelain.accentTint2)
            .clipShape(RoundedRectangle(cornerRadius: 5))
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

    private var turns: [TranscriptTurn] {
        AppMarkdown.turns(from: meeting.transcript ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let summary = meeting.summary, !summary.isEmpty {
                        summaryCard(summary)
                    }
                    transcriptBody
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(Color.omError)
                    }
                }
                // Transcripts are for reading: hold the text to a comfortable
                // measure instead of letting lines run the full window width.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
            }
        }
        .background(Color.Porcelain.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.Porcelain.dim)
                    .frame(width: 38, height: 38)
                    .background(Color.Porcelain.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.appName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.Porcelain.ink)
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Porcelain.dim)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button(busy ? "Working…" : (meeting.transcript == nil ? "Transcribe & Summarize" : "Re-transcribe")) { run() }
                    .disabled(busy)
                if !turns.isEmpty {
                    Button("Copy transcript") { copyTranscript() }
                }
                Button("Delete", role: .destructive) { delete() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(Color.Porcelain.panel)
    }

    /// Only states we can actually stand behind: speaker count comes from the
    /// parsed transcript, and meetings always transcribe on-device regardless of
    /// the dictation/polish backend — but which engine wrote an existing
    /// transcript isn't recorded, so it isn't claimed.
    private var metaLine: String {
        var parts = [shortDate(meeting.startedAt), durationText(meeting.durationSeconds)]
        let speakers = Set(turns.map(\.speaker)).count
        if speakers > 1 { parts.append("\(speakers) speakers") }
        parts.append("Transcribed on this Mac")
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if !turns.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                PorcelainEyebrow("Transcript")
                VStack(spacing: 0) {
                    ForEach(turns) { TranscriptTurnRow(turn: $0) }
                }
            }
        } else if let transcript = meeting.transcript, !transcript.isEmpty {
            // No speaker labels — the no-audio permission note, or a transcript
            // from a format this can't parse. Show it rather than an empty pane.
            VStack(alignment: .leading, spacing: 10) {
                PorcelainEyebrow("Transcript")
                Text(transcript)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Porcelain.ink)
                    .textSelection(.enabled)
            }
        } else if busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing on this Mac…")
                    .font(.system(size: 13)).foregroundStyle(Color.Porcelain.dim)
            }
        } else {
            Text("Not transcribed yet — press Transcribe & Summarize.")
                .font(.system(size: 13)).foregroundStyle(Color.Porcelain.dim)
        }
    }

    private func summaryCard(_ summary: String) -> some View {
        MarkdownSections(markdown: summary, fallbackTitle: "Summary")
            .padding(18)
            .omCard()
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.transcript ?? "", forType: .string)
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

/// One speaker turn, interview-transcript style: who + when in a right-aligned
/// gutter, words in a single column you can read straight down. The layout every
/// serious transcript tool converges on, because a transcript is scanned for
/// "who said that" far more often than it's read start to finish.
///
/// Only "You" is accented. Per-speaker colors were considered and rejected: the
/// palette is closed (design skill §1/§6), and a color scheme stops scaling once
/// a call has more voices than the palette has hues — name plus position doesn't.
private struct TranscriptTurnRow: View {
    let turn: TranscriptTurn

    var body: some View {
        // .firstTextBaseline, not .top: the label is 12.5pt and the body 15pt, so
        // aligning their top *edges* leaves the baselines ~2pt apart and the name
        // visibly floating above its first line. Baseline alignment is what makes
        // text of two sizes read as one row.
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(turn.speaker)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(turn.isYou ? Color.Porcelain.emerald : Color.Porcelain.ink)
                    .multilineTextAlignment(.trailing)
                if let timecode = turn.timecode {
                    Text(timecode)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.Porcelain.dim)
                }
            }
            .frame(width: 104, alignment: .trailing)

            Text(turn.text)
                .font(.system(size: 15))
                .lineSpacing(5)  // ~1.55 line height (design skill §3)
                .foregroundStyle(Color.Porcelain.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.speaker)\(turn.timecode.map { " at \($0)" } ?? ""): \(turn.text)")
    }
}
