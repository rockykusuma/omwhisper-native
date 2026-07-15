//
//  MeetingDiarization.swift
//  OmWhisper
//
//  Pure logic to turn timestamped ASR segments + speaker diarization segments
//  into an interleaved, per-speaker markdown transcript. No WhisperKit/FluidAudio
//  here — those effectful pieces live in MeetingDiarizer / WhisperEngine and
//  hand plain tuples to these functions, which are fully unit-tested.
//  See docs/superpowers/specs/2026-07-14-meetings-autostop-diarization-design.md.
//

import Foundation

nonisolated struct TranscriptSegment: Equatable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String
}

nonisolated enum MeetingDiarization {
    /// Seconds of overlap between two [start,end) intervals (0 if disjoint).
    static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// Label each ASR text segment with the speaker whose diarization segment
    /// overlaps it most; when nothing overlaps, use the speaker nearest by midpoint.
    static func alignSpeakers(
        texts: [(text: String, start: Double, end: Double)],
        speakers: [(id: String, start: Double, end: Double)]
    ) -> [TranscriptSegment] {
        texts.map { t in
            let mostOverlap = speakers.max { a, b in
                overlap(t.start, t.end, a.start, a.end) < overlap(t.start, t.end, b.start, b.end)
            }
            let label: String
            if let best = mostOverlap, overlap(t.start, t.end, best.start, best.end) > 0 {
                label = best.id
            } else {
                let mid = (t.start + t.end) / 2
                label = speakers.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.id
                    ?? "Speaker 1"
            }
            return TranscriptSegment(text: t.text, start: t.start, end: t.end, speaker: label)
        }
    }

    /// Words, lowercased, punctuation-stripped — the unit echo matching compares.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// How much two texts say the same thing: shared distinct words over the
    /// shorter one's distinct-word count. 1 = one is a subset of the other.
    /// Deliberately word-set based, not edit distance: the two tracks are
    /// transcribed independently, so an echo comes back with different word
    /// errors ("For the Internet" vs "or the internet") but nearly the same words.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(words(a)), y = Set(words(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    /// Remove mic-track segments that are just the speakers bleeding back into
    /// the mic. When the user is on laptop speakers, me.caf picks up whatever
    /// them.caf is playing, so the same sentence lands on both tracks and the
    /// transcript says it twice — once as "You", once as the real speaker.
    ///
    /// A "You" segment is echo when it overlaps a system-track segment in time
    /// AND says nearly the same thing. The user's own speech is never on the
    /// system track (the tap captures output only), so real speech can't match
    /// and is never dropped — headphones simply mean nothing matches at all.
    ///
    /// ponytail: a genuinely simultaneous identical short utterance (both sides
    /// say "yeah" at once) is credited to the speaker, not you. Needs the audio
    /// itself (echo is a delayed, attenuated copy) to do better — not worth it.
    static func dropEchoed(
        you: [TranscriptSegment],
        others: [TranscriptSegment],
        minSimilarity: Double = 0.6
    ) -> [TranscriptSegment] {
        you.filter { mine in
            !others.contains { theirs in
                overlap(mine.start, mine.end, theirs.start, theirs.end) > 0
                    && similarity(mine.text, theirs.text) >= minSimilarity
            }
        }
    }

    /// Map raw diarization speaker ids (any strings) to "Speaker 1", "Speaker 2", …
    /// in order of first appearance. "You" is left untouched.
    static func relabelOthers(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapping: [String: String] = [:]
        var next = 1
        return segments.map { seg in
            if seg.speaker == "You" { return seg }
            let label: String
            if let existing = mapping[seg.speaker] {
                label = existing
            } else {
                label = "Speaker \(next)"
                mapping[seg.speaker] = label
                next += 1
            }
            var out = seg
            out.speaker = label
            return out
        }
    }

    /// Sort by start time (stable).
    static func mergeByTime(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { l, r in
            l.element.start != r.element.start ? l.element.start < r.element.start : l.offset < r.offset
        }.map(\.element)
    }

    /// Fold consecutive same-speaker segments into one turn (text space-joined).
    static func collapseTurns(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segments {
            if var last = out.last, last.speaker == seg.speaker {
                last.text += " " + seg.text
                last.end = seg.end
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    /// Markdown: **Speaker:**\ntext, blank line between turns.
    static func renderInterleaved(_ turns: [TranscriptSegment]) -> String {
        turns.map { "**\($0.speaker):**\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }
}
