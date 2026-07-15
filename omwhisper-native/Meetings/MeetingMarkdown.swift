//
//  MeetingMarkdown.swift
//  OmWhisper
//
//  Parses the markdown a meeting is STORED as back into structure the UI can
//  present properly. Meetings keep one markdown string in the DB (it's what the
//  summarizer reads and what FTS indexes), but rendering it with
//  Text(.init(markdown)) gives a wall of text: SwiftUI's markdown does no
//  headings at all (so "## Summary" showed up literally) and speaker labels
//  become bold runs you can't scan.
//
//  turns(from:) is the inverse of MeetingDiarization.renderInterleaved — change
//  one and you must change the other. It also reads the older
//  "**You:**" / "**Others:**" transcripts, which simply carry no timecode.
//

import Foundation

nonisolated struct TranscriptTurn: Equatable, Identifiable {
    let id: Int
    var speaker: String
    /// "0:03" — nil for transcripts written before timecodes, and for the
    /// non-diarized You/Others fallback.
    var timecode: String?
    var text: String

    /// The person who recorded, as labelled by MeetingTranscriber. Drives the
    /// one accent in the transcript.
    var isYou: Bool { speaker == "You" }
}

nonisolated enum MeetingMarkdown {
    /// Seconds → "0:03" / "12:05" / "1:02:33".
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "**You:** [0:03]" → (speaker, timecode). nil when the line isn't a label.
    private static func parseLabel(_ line: String) -> (speaker: String, timecode: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("**"), let close = trimmed.range(of: ":**") else { return nil }
        let speaker = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
        guard !speaker.isEmpty else { return nil }

        var timecode: String?
        let rest = trimmed[close.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            timecode = String(rest.dropFirst().dropLast())
        }
        return (speaker, timecode)
    }

    /// Stored transcript markdown → turns. Text before any label is ignored;
    /// a transcript with no labels at all (e.g. the no-audio permission note)
    /// yields no turns, and the caller should fall back to rendering it plainly.
    static func turns(from markdown: String) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var body: [String] = []

        func flush() {
            guard !turns.isEmpty else { return }
            turns[turns.count - 1].text = body
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            if let label = parseLabel(line) {
                flush()
                turns.append(TranscriptTurn(
                    id: turns.count, speaker: label.speaker, timecode: label.timecode, text: ""
                ))
            } else if !turns.isEmpty {
                body.append(line)
            }
        }
        flush()
        return turns.filter { !$0.text.isEmpty }
    }

    /// A "## Title" section of the summary and its lines. Anything before the
    /// first heading becomes an untitled leading section, so a summary the model
    /// wrote without headings still renders.
    struct Section: Equatable, Identifiable {
        let id: Int
        var title: String?
        var lines: [String]
    }

    /// Splits summary markdown on "## " headings. SwiftUI renders no headings,
    /// so the view draws its own eyebrow per section instead of showing "##".
    static func sections(from markdown: String) -> [Section] {
        var sections: [Section] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                // Models like to write "## Summary —"; keep just the title.
                let title = String(line.dropFirst(3))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " —-–:"))
                sections.append(Section(id: sections.count, title: title, lines: []))
            } else if !line.isEmpty {
                if sections.isEmpty {
                    sections.append(Section(id: 0, title: nil, lines: []))
                }
                sections[sections.count - 1].lines.append(line)
            }
        }
        return sections.filter { !$0.lines.isEmpty }
    }

    /// True for a summary line the model wrote as a bullet; the view draws its
    /// own bullet, so the marker is stripped.
    static func bulletBody(_ line: String) -> String? {
        for marker in ["* ", "- ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
