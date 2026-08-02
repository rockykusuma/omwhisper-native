//
//  MeetingAIDiagnostics.swift
//  OmWhisper
//
//  DEBUG-only: exercises SP2/SP3's post-meeting AI paths against a real stored
//  meeting and prints each result. Those paths -- summary templates, one-shot
//  Q&A, follow-up drafting, export -- shipped in 2.0.5 with unit tests over
//  their pure pieces but no run against a real backend, because every entry
//  point is behind a button.
//
//  Same rationale as MeetingDiagnostics: os_log output is not retrievable on
//  the dev build, so stdout is the only working evidence channel. Whole file
//  is #if DEBUG, matching MeetingSelfTest.swift's convention.
//
//  Run: OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev --diagnose-meeting-ai [id]
//

#if DEBUG
import Foundation

@MainActor
enum MeetingAIDiagnostics {
    static func run(meetingID: Int64?) async {
        print("=== meeting AI diagnostics ===")

        guard let dir = AppSupportDirectory.resolve(),
              let store = try? MeetingStore.open(atPath: dir.appendingPathComponent("meetings.db").path)
        else {
            print("FAIL: could not open meetings.db")
            return
        }
        guard let meeting = pick(store: store, id: meetingID) else {
            print("FAIL: no meeting found (pass an id, or record one first)")
            return
        }

        let transcript = MeetingDiarization.applySpeakerNames(
            meeting.transcript ?? "", names: meeting.speakerNames ?? [:])
        print("meeting id=\(meeting.id ?? -1) app=\(meeting.appName) transcript=\(transcript.count) chars")
        guard !transcript.isEmpty else {
            print("FAIL: that meeting has no transcript — nothing to exercise")
            return
        }

        guard let backend = backend() else {
            print("FAIL: no on-device backend. Ollama isn't selected/configured and")
            print("      SystemLLM says: \(SystemLLM.unavailableReason() ?? "available?")")
            return
        }
        print("backend=\(backend.label) chunkLimit=\(backend.chunkLimit)\n")

        await exportChecks(meeting)
        await templateChecks(transcript: transcript, backend: backend)
        await askChecks(transcript: transcript, backend: backend)
        await followUpCheck(meeting: meeting, transcript: transcript, backend: backend)

        print("\n=== done ===")
    }

    // MARK: - Checks

    /// Pure, so this is the one section that can't be blamed on a model.
    private static func exportChecks(_ meeting: Meeting) async {
        print("--- export ---")
        for format in [MeetingExportFormat.markdown, .text] {
            let out = MeetingDetails.export(meeting, format: format)
            let hasTranscript = out.contains(meeting.transcript?.prefix(40) ?? "")
            print("\(format): \(out.count) chars, contains transcript: \(hasTranscript)")
            if format == .text, out.contains("## ") {
                print("  WARN: plain text still contains markdown headings")
            }
        }
        print("")
    }

    /// Every built-in template must produce a DIFFERENT summary. Identical
    /// output would mean the template parameter is being accepted and ignored,
    /// which no unit test over `chunk()` would catch.
    private static func templateChecks(transcript: String, backend: Backend) async {
        print("--- summary templates ---")
        var seen: [String: String] = [:]
        for template in MeetingSummarizer.builtInTemplates {
            do {
                let summary = try await MeetingSummarizer.generate(
                    transcript: transcript, polish: backend.polish,
                    template: template, chunkLimit: backend.chunkLimit)
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let headings = trimmed.split(separator: "\n")
                    .filter { $0.hasPrefix("#") }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                print("\(template.name): \(trimmed.count) chars, headings: \(headings)")
                if trimmed.isEmpty { print("  FAIL: empty summary") }
                // The bug that rendered a blank card: body text on the heading line.
                for line in trimmed.split(separator: "\n") where line.hasPrefix("#") {
                    if line.contains(" — ") || line.contains(": ") {
                        print("  WARN: content on a heading line -> \(line)")
                    }
                }
                if let other = seen.first(where: { $0.value == trimmed })?.key {
                    print("  FAIL: byte-identical to \(other) — template ignored?")
                }
                seen[template.name] = trimmed
            } catch {
                print("\(template.name): THREW \(error)")
            }
        }
        print("")
    }

    /// Both directions: a question the transcript can answer, and one it can't.
    /// Only the second proves the model isn't inventing an answer.
    private static func askChecks(transcript: String, backend: Backend) async {
        print("--- ask ---")
        let answerable = "What was being worked on?"
        let unanswerable = "What did we decide about the Antarctic penguin migration budget?"

        for question in [answerable, unanswerable] {
            do {
                let answer = try await MeetingSummarizer.answer(
                    question: question, transcript: transcript,
                    polish: backend.polish, chunkLimit: backend.chunkLimit)
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                print("Q: \(question)")
                print("A: \(trimmed.prefix(300))")
                if question == unanswerable {
                    let refused = trimmed.localizedCaseInsensitiveContains("wasn't discussed")
                        || trimmed.localizedCaseInsensitiveContains("was not discussed")
                    print("   refused-to-speculate: \(refused)\(refused ? "" : "  <-- CHECK: invented an answer?")")
                }
            } catch {
                print("Q: \(question) -> THREW \(error)")
            }
        }
        print("")
    }

    private static func followUpCheck(meeting: Meeting, transcript: String, backend: Backend) async {
        print("--- follow-up email ---")
        let source = meeting.summary ?? transcript
        do {
            let draft = try await backend.polish.polish(
                source, style: MeetingSummarizer.followUpStyle, targetLanguage: nil)
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            print(trimmed.prefix(600))
            if !trimmed.localizedCaseInsensitiveContains("subject:") {
                print("  WARN: no Subject: line — the prompt asks for one")
            }
        } catch {
            print("THREW \(error)")
        }
        print("")
    }

    // MARK: - Plumbing

    private struct Backend {
        let polish: PolishBackend
        let chunkLimit: Int
        let label: String
    }

    /// Mirrors AppState.meetingSummaryBackends() -- Ollama when configured, then
    /// SystemLLM. Cloud is never a meeting backend and isn't reachable here
    /// either. Read straight from UserDefaults so this runs without AppState,
    /// which would open every store and start the daemons.
    private static func backend() -> Backend? {
        let defaults = UserDefaults.standard
        let kind = defaults.string(forKey: "polishBackend")
        let model = defaults.string(forKey: "ollamaModel") ?? ""
        if kind == "ollama", !model.isEmpty {
            let baseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
            return Backend(polish: Ollama(baseURL: baseURL, model: model),
                           chunkLimit: MeetingSummarizer.ollamaChunkLimit,
                           label: "Ollama(\(model))")
        }
        if SystemLLM.isAvailable() {
            return Backend(polish: SystemLLM(), chunkLimit: MeetingSummarizer.chunkCharLimit,
                           label: "SystemLLM")
        }
        return nil
    }

    private static func pick(store: MeetingStore, id: Int64?) -> Meeting? {
        if let id { return try? store.get(id: id) }
        return (try? store.fetchPage(offset: 0, limit: 1))?.first
    }
}
#endif
