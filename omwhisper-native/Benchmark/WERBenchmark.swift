//
//  WERBenchmark.swift
//  OmWhisper
//
//  DEBUG-only cross-engine accuracy run: `OmWhisper --wer <corpus-dir>`.
//  Closes the M4 item deferred since the beginning — no accuracy number has
//  ever existed for Apple vs. Parakeet vs. Whisper vs. the cloud providers,
//  which is why the website could not make an accuracy claim honestly.
//
//  A corpus directory holds pairs: `<name>.<audio-ext>` beside `<name>.txt`
//  containing exactly what was said. Any audio AVAudioFile can open works
//  (.wav .m4a .caf .mp3 .aiff) — QuickTime's "New Audio Recording" output is
//  fine. See docs/wer-corpus/README.md.
//
//  Corpus-agnostic on purpose: point it at your own dictation recordings, or
//  at LibriSpeech, or at anything else. Which corpus you use decides what the
//  number means, and that belongs to whoever runs it, not to this file.
//
//  Reuses MeetingTranscriber.transcribeFile — the file->engine drive already
//  proven by meeting transcription — rather than writing a second one.
//

#if DEBUG

import AVFoundation
import Foundation

nonisolated enum WERBenchmark {

    private struct Entry {
        let name: String
        let audio: URL
        let reference: String
        let duration: TimeInterval
    }

    private struct Row {
        let engine: String
        let result: WER.Result
        let seconds: Double
        let audioSeconds: Double
        let failures: [String]
        /// Same hypothesis, after the post-processing a real dictation gets.
        /// nil when the corpus supplies nothing to correct with.
        var corrected: WER.Result?
        /// Same engine, same audio, with custom vocabulary passed. nil when the
        /// corpus has no vocabulary.txt.
        var biased: WER.Result?
        /// The number that describes a real user with a vocabulary list:
        /// biasing on AND post-processing applied.
        var biasedCorrected: WER.Result?
    }

    private struct Measured {
        let raw: WER.Result
        let corrected: WER.Result
        let seconds: Double
        let audioSeconds: Double
        let failures: [String]
    }

    static func run(directory: URL) async {
        print("")
        print("OmWhisper — cross-engine WER")
        print("corpus: \(directory.path)")
        print("")

        let entries = loadCorpus(directory)
        guard !entries.isEmpty else {
            print("No samples found.")
            print("Expected pairs like 01.wav + 01.txt (the .txt holding exactly what was said).")
            return
        }
        let totalAudio = entries.reduce(0) { $0 + $1.duration }
        print(String(format: "%d samples, %.1fs of audio, %d reference words",
                     entries.count,
                     totalAudio,
                     entries.reduce(0) { $0 + WER.normalize($1.reference).count }))
        print("")

        // Optional: a vocabulary.txt of one term per line turns the run into an
        // A/B — same engine, same audio, biasing off then on. Engines are given
        // no vocabulary otherwise, which measures them with their biasing
        // switched off and is not what a user with a vocab list experiences.
        let vocabulary = loadVocabulary(directory)
        let replacements = loadReplacements(directory)
        let correct = corpusCorrection(vocabulary: vocabulary, replacements: replacements)
        let hasCorrections = !vocabulary.isEmpty || !replacements.isEmpty
        if vocabulary.isEmpty {
            print("No vocabulary.txt — measuring engines with biasing OFF.")
        } else {
            print("vocabulary.txt: \(vocabulary.count) term(s) — each engine runs twice, off then on.")
            print("  \(vocabulary.joined(separator: ", "))")
        }
        if !replacements.isEmpty {
            print("replacements.txt: \(replacements.count) rule(s).")
        }
        if hasCorrections {
            print("Post-processing (replacements + fuzzy correction) is scored alongside raw output.")
        }
        print("")

        var rows: [Row] = []
        for (label, engine, skip) in engines() {
            if let skip {
                // Never silently omit an engine — a missing row would read as
                // "not applicable" when it actually means "not measured".
                print("· \(label): SKIPPED — \(skip)")
                continue
            }
            guard let engine else { continue }
            print("· \(label): running…")
            let plain = await measure(label: label, engine: engine, entries: entries, correct: correct)
            var row = Row(engine: label, result: plain.raw, seconds: plain.seconds,
                          audioSeconds: plain.audioSeconds, failures: plain.failures,
                          corrected: hasCorrections ? plain.corrected : nil)
            if !vocabulary.isEmpty {
                print("· \(label): running with vocabulary…")
                let biased = await measure(label: label, engine: engine, entries: entries,
                                           vocabulary: vocabulary, correct: correct)
                row.biased = biased.raw
                row.biasedCorrected = hasCorrections ? biased.corrected : nil
            }
            rows.append(row)
        }

        print("")
        report(rows, entries: entries)
    }

    // MARK: corpus

    private static func loadCorpus(_ directory: URL) -> [Entry] {
        let audioExts: Set<String> = ["wav", "m4a", "caf", "mp3", "aiff", "aif", "flac"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        return files
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio -> Entry? in
                let txt = audio.deletingPathExtension().appendingPathExtension("txt")
                guard let raw = try? String(contentsOf: txt, encoding: .utf8) else {
                    print("· \(audio.lastPathComponent): no matching .txt — skipped")
                    return nil
                }
                let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reference.isEmpty else {
                    print("· \(audio.lastPathComponent): reference is empty — skipped")
                    return nil
                }
                var duration: TimeInterval = 0
                if let file = try? AVAudioFile(forReading: audio) {
                    duration = Double(file.length) / file.processingFormat.sampleRate
                }
                return Entry(name: audio.deletingPathExtension().lastPathComponent,
                             audio: audio, reference: reference, duration: duration)
            }
    }

    /// One term per line; blank lines and `#` comments ignored.
    private static func loadVocabulary(_ directory: URL) -> [String] {
        let url = directory.appendingPathComponent("vocabulary.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// `from -> to` (or `from → to`) per line; blank lines and `#` comments
    /// ignored. A line without a usable arrow and both sides is SKIPPED rather
    /// than half-parsed: a benchmark that quietly invents a rule reports a
    /// change the app would not have made.
    static func parseReplacements(_ raw: String) -> [ReplacementRule] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> ReplacementRule? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.components(separatedBy: "→").count > 1
                ? trimmed.components(separatedBy: "→")
                : trimmed.components(separatedBy: "->")
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return ReplacementRule(from: from, to: to)
        }
    }

    private static func loadReplacements(_ directory: URL) -> [ReplacementRule] {
        let url = directory.appendingPathComponent("replacements.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseReplacements(raw)
    }

    /// The post-processing a real dictation receives, in the same order
    /// AppState applies it: replacements, then fuzzy correction. Returns
    /// identity when the corpus supplies neither, so a corpus without
    /// vocabulary.txt still measures the raw engine and stays comparable with
    /// every number published before this existed.
    static func corpusCorrection(vocabulary: [String],
                                 replacements: [ReplacementRule]) -> (String) -> String {
        guard !vocabulary.isEmpty || !replacements.isEmpty else { return { $0 } }
        return { text in
            var result = applyReplacements(text, rules: replacements)
            if !vocabulary.isEmpty {
                result = fuzzyCorrect(result, dictionary: vocabulary)
            }
            return result
        }
    }

    // MARK: engines

    /// (label, engine, skip-reason). Exactly one of engine/skip is non-nil.
    /// Models are never downloaded here: a benchmark that silently pulls
    /// multiple gigabytes is not a benchmark you can run casually.
    private static func engines() -> [(String, TranscriptionEngine?, String?)] {
        var list: [(String, TranscriptionEngine?, String?)] = [
            ("Apple Speech", AppleEngine(), nil)
        ]

        for model in ParakeetModel.allCases {
            if ParakeetEngine.isDownloaded(model) {
                let engine = ParakeetEngine()
                engine.setModel(model)
                list.append(("Parakeet \(model.rawValue)", engine, nil))
            } else {
                list.append(("Parakeet \(model.rawValue)", nil, "model not downloaded"))
            }
        }

        for model in WhisperModel.allCases {
            if WhisperEngine.isDownloaded(model) {
                let engine = WhisperEngine()
                engine.setModel(model)
                list.append(("Whisper \(model.rawValue)", engine, nil))
            } else {
                list.append(("Whisper \(model.rawValue)", nil, "model not downloaded"))
            }
        }

        for provider in CloudProviderKind.allCases {
            if Keychain.loadSTTKey(provider) != nil {
                list.append(("Cloud · \(provider.displayName)", CloudEngine(provider: provider), nil))
            } else {
                list.append(("Cloud · \(provider.displayName)", nil, "no API key in Keychain"))
            }
        }
        return list
    }

    // MARK: measurement

    private static func measure(label: String, engine: TranscriptionEngine, entries: [Entry],
                                vocabulary: [String] = [],
                                correct: @escaping (String) -> String) async -> Measured {
        var rawResults: [WER.Result] = []
        var correctedResults: [WER.Result] = []
        var failures: [String] = []
        let started = Date()

        for entry in entries {
            do {
                let hypothesis = try await MeetingTranscriber.transcribeFile(
                    entry.audio, engine: engine, vocabulary: vocabulary)
                let fixed = correct(hypothesis)
                let raw = WER.compare(reference: entry.reference, hypothesis: hypothesis)
                rawResults.append(raw)
                correctedResults.append(WER.compare(reference: entry.reference, hypothesis: fixed))
                // Full hypothesis, never truncated. A 60-char preview here caused a
                // real misreading on the first run: every engine's line was cut off
                // mid-sentence, so which word actually failed was invisible and the
                // wrong word got blamed.
                print(String(format: "    %-18@ %5.1f%%  (S%d D%d I%d)",
                             entry.name as NSString, raw.rate * 100,
                             raw.substitutions, raw.deletions, raw.insertions))
                print("        \(hypothesis.isEmpty ? "<empty>" : hypothesis)")
                // Only when correction actually changed something -- an
                // unchanged echo on every line would bury the ones that matter.
                if fixed != hypothesis { print("        → \(fixed)") }
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
                print("    \(entry.name): FAILED — \(error.localizedDescription)")
            }
        }

        return Measured(raw: WER.aggregate(rawResults),
                        corrected: WER.aggregate(correctedResults),
                        seconds: Date().timeIntervalSince(started),
                        audioSeconds: entries.reduce(0) { $0 + $1.duration },
                        failures: failures)
    }

    // MARK: report

    private static func report(_ rows: [Row], entries: [Entry]) {
        guard !rows.isEmpty else { print("No engine produced a result."); return }

        let hasBiased = rows.contains { $0.biased != nil }
        let hasCorrected = rows.contains { $0.corrected != nil }

        func pct(_ r: WER.Result?) -> String {
            guard let r else { return "     —" }
            return String(format: "%5.1f%%", r.rate * 100)
        }

        if hasBiased {
            print("engine                    off   off+fix     on    on+fix     RTF")
            print("──────────────────────────────────────────────────────────────────")
            // Sorted by the number that describes a real user: biasing on with
            // post-processing applied, falling back as those are unavailable.
            func headline(_ r: Row) -> WER.Result { r.biasedCorrected ?? r.biased ?? r.corrected ?? r.result }
            for row in rows.sorted(by: { headline($0).rate < headline($1).rate }) {
                let rtf = row.audioSeconds > 0 ? row.seconds / row.audioSeconds : 0
                print(String(format: "%-22@ %@  %@  %@  %@   %5.2fx",
                             row.engine as NSString, pct(row.result), pct(row.corrected),
                             pct(row.biased), pct(row.biasedCorrected), rtf))
            }
        } else if hasCorrected {
            print("engine                        WER   WER+fix     RTF")
            print("────────────────────────────────────────────────────")
            for row in rows.sorted(by: { ($0.corrected ?? $0.result).rate < ($1.corrected ?? $1.result).rate }) {
                let rtf = row.audioSeconds > 0 ? row.seconds / row.audioSeconds : 0
                print(String(format: "%-24@  %6.1f%%   %6.1f%%   %5.2fx",
                             row.engine as NSString, row.result.rate * 100,
                             (row.corrected ?? row.result).rate * 100, rtf))
            }
        } else {
            print("engine                        WER   subs   dels    ins     RTF")
            print("──────────────────────────────────────────────────────────────")
            for row in rows.sorted(by: { $0.result.rate < $1.result.rate }) {
                let rtf = row.audioSeconds > 0 ? row.seconds / row.audioSeconds : 0
                print(String(format: "%-24@  %6.1f%%  %5d  %5d  %5d   %5.2fx",
                             row.engine as NSString, row.result.rate * 100,
                             row.result.substitutions, row.result.deletions,
                             row.result.insertions, rtf))
            }
        }
        print("")
        print("WER = (subs + dels + ins) / reference words, pooled across samples. Lower is better.")
        print("RTF = processing time / audio duration, biasing-off pass. Below 1.00x beats real time.")
        if hasBiased {
            print("off/on = engine biasing (a vocabulary list passed to the engine) off, then on.")
        }
        if hasCorrected {
            print("+fix = after the post-processing a real dictation gets (replacements, then fuzzy")
            print("       correction). This is the column that describes a user; the others do not.")
        }

        let failed = rows.filter { !$0.failures.isEmpty }
        if !failed.isEmpty {
            print("")
            print("Failures (these engines' numbers cover fewer samples):")
            for row in failed {
                for failure in row.failures { print("  \(row.engine) — \(failure)") }
            }
        }

        if entries.count < 5 {
            print("")
            print("NOTE: \(entries.count) sample(s). Too few to separate engines that land close")
            print("together — treat a small gap here as noise, not a ranking.")
        }
    }
}

#endif
