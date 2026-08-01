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
import UniformTypeIdentifiers

struct HubMeetingsSectionView: View {
    @Environment(AppState.self) private var appState

    @State private var meetings: [Meeting] = []
    @State private var selectedID: Int64?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var showTemplates = false

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
        // On the outer VStack, not `browser`: the settings bar (calendar-denied
        // error) renders even when the list is empty and browser isn't shown.
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showTemplates) {
            MeetingTemplatesSheet().environment(appState)
        }
    }

    private func settingsBar(state: AppState) -> some View {
        HStack {
            Toggle("Detect and record meetings", isOn: Binding(
                get: { state.meetingsEnabled }, set: { state.meetingsEnabled = $0 }
            ))
            .tint(Color.Porcelain.emerald)
            .foregroundStyle(Color.Porcelain.ink)
            Toggle("Match calendar events", isOn: Binding(
                get: { state.meetingsCalendarEnabled },
                set: { on in
                    guard on else { state.meetingsCalendarEnabled = false; return }
                    Task {
                        if await MeetingCalendar.requestAccess() {
                            state.meetingsCalendarEnabled = true
                        } else {
                            state.meetingsCalendarEnabled = false
                            errorMessage = "Calendar access was denied — grant it in System Settings › Privacy & Security › Calendars."
                        }
                    }
                }
            ))
            .tint(Color.Porcelain.emerald)
            .foregroundStyle(Color.Porcelain.ink)
            Button("Templates…") { showTemplates = true }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Porcelain.mint)
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
                        .accessibilityLabel("\(meeting.title ?? meeting.appName), \(shortDate(meeting.startedAt))")
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
            Text(meeting.title ?? meeting.appName)
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
            // Land on the newest meeting rather than an empty pane. Also covers the
            // selection falling out of the list — deleted, or filtered out by a
            // search — which would otherwise strand "Select a meeting" next to
            // results that are right there.
            if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
                selectedID = meetings.first?.id
            }
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
    @State private var editingSummary = false
    @State private var summaryDraft = ""
    @State private var editingDetails = false
    @State private var titleDraft = ""
    @State private var attendeesDraft = ""

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
                    Text(meeting.title ?? meeting.appName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.Porcelain.ink)
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Porcelain.dim)
                    if let attendees = meeting.attendees, !attendees.isEmpty {
                        Text("With \(attendees.joined(separator: ", "))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Porcelain.dim)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button(busy ? "Working…" : (meeting.transcript == nil ? "Transcribe & Summarize" : "Re-transcribe")) { run() }
                    .disabled(busy)
                if meeting.transcript != nil {
                    // Click = the default template; the menu picks one for this
                    // run only, without changing the default.
                    Menu("Regenerate summary") {
                        ForEach(allTemplates) { template in
                            Button(template.name) { regenerate(templateID: template.id) }
                        }
                    } primaryAction: {
                        regenerate(templateID: nil)
                    }
                    .disabled(busy)
                    .fixedSize()
                }
                if !turns.isEmpty {
                    Menu("Share") {
                        Button("Copy transcript") { copyTranscript() }
                        Button("Copy summary") { copySummary() }
                        Divider()
                        Button("Export as Markdown…") { exportMeeting(.markdown, ext: "md") }
                        Button("Export as Text…") { exportMeeting(.text, ext: "txt") }
                    }
                    .fixedSize()
                }
                Button("Edit details") { beginEditingDetails() }
                    .disabled(busy)
                    .popover(isPresented: $editingDetails, arrowEdge: .bottom) {
                        detailsEditor
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
        // Once a real title takes the headline, the app still deserves a mention.
        if meeting.title != nil { parts.insert(meeting.appName, at: 0) }
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
                    ForEach(turns) { turn in
                        TranscriptTurnRow(
                            turn: turn,
                            displayName: speakerNames[turn.speaker] ?? turn.speaker,
                            suggestions: meeting.attendees ?? [],
                            onRename: turn.isYou ? nil : { rename(turn.speaker, to: $0) }
                        )
                    }
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

    /// Editing is raw markdown in monospace, deliberately: markdown IS the
    /// stored format (it's what FTS indexes and what the summarizer writes), so
    /// a rich editor would just be a lossy layer over it. Regenerate overwrites
    /// edits — no merge logic, same as every other tool in this space.
    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if editingSummary {
                TextEditor(text: $summaryDraft)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                HStack(spacing: 8) {
                    Button("Cancel") { editingSummary = false }
                    Button("Save") { saveSummary() }.keyboardShortcut(.defaultAction)
                }
            } else {
                MarkdownSections(markdown: summary, fallbackTitle: "Summary")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") {
                    summaryDraft = summary
                    editingSummary = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Porcelain.mint)
            }
        }
        .padding(18)
        .omCard()
    }

    /// Prefill from what's stored, so editing corrects rather than retypes. An
    /// unset title prefills empty, not appName — appName is a display fallback,
    /// not a value the user chose, and pre-filling it would silently turn every
    /// edit into "the app name is now the title".
    private func beginEditingDetails() {
        titleDraft = meeting.title ?? ""
        attendeesDraft = (meeting.attendees ?? []).joined(separator: ", ")
        editingDetails = true
    }

    private var detailsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
            TextField("Title", text: $titleDraft)
                .frame(width: 260)
                .onSubmit { saveDetails() }
            TextField("Attendees, comma separated", text: $attendeesDraft)
                .frame(width: 260)
                .onSubmit { saveDetails() }
            Text("Attendees appear as one-tap names when renaming speakers.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.Porcelain.dim)
                .frame(width: 260, alignment: .leading)
            HStack {
                Button("Cancel") { editingDetails = false }
                    .controlSize(.small)
                Spacer()
                Button("Save") { saveDetails() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private func saveDetails() {
        editingDetails = false
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        do {
            try store.setDetails(
                id: id,
                title: titleDraft,
                attendees: MeetingDetails.parseAttendees(attendeesDraft))
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await onChanged() }
    }

    private func saveSummary() {
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        let trimmed = summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try store.setSummary(id: id, trimmed.isEmpty ? nil : trimmed) }
        catch { errorMessage = error.localizedDescription }
        editingSummary = false
        Task { await onChanged() }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            MeetingDiarization.applySpeakerNames(
                meeting.transcript ?? "", names: speakerNames),
            forType: .string)
    }

    private var allTemplates: [PolishStyle] {
        MeetingSummarizer.builtInTemplates + appState.customMeetingTemplates
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.summary ?? "", forType: .string)
    }

    /// Same NSSavePanel shape as HistoryView.export — one established pattern
    /// for "write a file the user names".
    private func exportMeeting(_ format: MeetingExportFormat, ext: String) {
        let content = MeetingDetails.export(meeting, format: format)
        let panel = NSSavePanel()
        let base = (meeting.title ?? meeting.appName).replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    private func regenerate(templateID: UUID?) {
        guard let id = meeting.id else { return }
        working = true
        errorMessage = nil
        Task {
            do { _ = try await appState.regenerateSummary(id: id, templateID: templateID) }
            catch { errorMessage = error.localizedDescription }
            await onChanged()
            working = false
        }
    }

    private var speakerNames: [String: String] { meeting.speakerNames ?? [:] }

    private func rename(_ raw: String, to name: String) {
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        var names = speakerNames
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { names.removeValue(forKey: raw) } else { names[raw] = trimmed }
        try? store.setSpeakerNames(id: id, names.isEmpty ? nil : names)
        Task { await onChanged() }
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

/// Default-template picker + custom-template CRUD. Deliberately plain: a custom
/// template is a name and a reduce-stage prompt — the same PolishStyle shape and
/// storage pattern as the AI tab's custom styles, but a separate list, since a
/// meeting-notes structure is not a dictation style.
private struct MeetingTemplatesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newPrompt = ""

    private var allTemplates: [PolishStyle] {
        MeetingSummarizer.builtInTemplates + appState.customMeetingTemplates
    }

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 16) {
            Text("Summary templates")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)

            Picker("Default", selection: Binding(
                get: { state.meetingTemplateID ?? MeetingSummarizer.meetingWriteStyle.id },
                set: { state.meetingTemplateID = $0 == MeetingSummarizer.meetingWriteStyle.id ? nil : $0 }
            )) {
                ForEach(allTemplates) { Text($0.name).tag($0.id) }
            }
            .tint(Color.Porcelain.emerald)

            if !appState.customMeetingTemplates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.customMeetingTemplates) { template in
                        HStack {
                            Text(template.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.Porcelain.ink)
                            Spacer()
                            Button("Delete", role: .destructive) { remove(template) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("New template")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                TextField("Name", text: $newName)
                    .porcelainField()
                TextField("How should the notes be structured?", text: $newPrompt, axis: .vertical)
                    .lineLimit(3...6)
                    .porcelainField()
                Button("Add template") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                        || newPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color.Porcelain.bg)
    }

    private func add() {
        appState.customMeetingTemplates.append(PolishStyle(
            id: UUID(),
            name: newName.trimmingCharacters(in: .whitespaces),
            prompt: newPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false))
        newName = ""
        newPrompt = ""
    }

    /// Deleting the default falls the default back to Standard, rather than
    /// leaving a dangling ID (which resolves to Standard anyway, but silently).
    private func remove(_ template: PolishStyle) {
        appState.customMeetingTemplates.removeAll { $0.id == template.id }
        if appState.meetingTemplateID == template.id { appState.meetingTemplateID = nil }
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
    /// speakerNames-resolved label; equals turn.speaker when unmapped.
    let displayName: String
    /// Calendar attendees, offered as one-tap rename suggestions.
    let suggestions: [String]
    /// nil = not renameable ("You" — the recorder's own accent depends on it).
    let onRename: ((String) -> Void)?

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        // .firstTextBaseline, not .top: the label is 12.5pt and the body 15pt, so
        // aligning their top *edges* leaves the baselines ~2pt apart and the name
        // visibly floating above its first line. Baseline alignment is what makes
        // text of two sizes read as one row.
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .trailing, spacing: 1) {
                speakerLabel
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
        .accessibilityLabel("\(displayName)\(turn.timecode.map { " at \($0)" } ?? ""): \(turn.text)")
    }

    /// The non-renameable branch is exactly the "You" case and keeps the emerald
    /// accent; renameable speakers keep ink, as before the rename affordance.
    @ViewBuilder
    private var speakerLabel: some View {
        if let onRename {
            Button {
                draft = displayName == turn.speaker ? "" : displayName
                renaming = true
            } label: {
                Text(displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(displayName)")
            .popover(isPresented: $renaming, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rename \(turn.speaker)")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { commit() }
                    if !suggestions.isEmpty {
                        // Calendar attendees as one-tap suggestions.
                        HStack(spacing: 6) {
                            ForEach(suggestions.prefix(4), id: \.self) { name in
                                Button(name) { draft = name; commit() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Button("Clear") { draft = ""; commit() }
                            .controlSize(.small)
                        Spacer()
                        Button("Save") { commit() }
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.small)
                    }
                }
                .padding(14)
            }
        } else {
            Text(displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.Porcelain.emerald)
                .multilineTextAlignment(.trailing)
        }
    }

    private func commit() {
        renaming = false
        onRename?(draft)
    }
}
