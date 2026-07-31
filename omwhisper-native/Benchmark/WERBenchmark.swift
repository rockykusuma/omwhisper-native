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
            rows.append(await measure(label: label, engine: engine, entries: entries))
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

    private static func measure(label: String, engine: TranscriptionEngine, entries: [Entry]) async -> Row {
        var results: [WER.Result] = []
        var failures: [String] = []
        let started = Date()

        for entry in entries {
            do {
                let hypothesis = try await MeetingTranscriber.transcribeFile(entry.audio, engine: engine)
                let result = WER.compare(reference: entry.reference, hypothesis: hypothesis)
                results.append(result)
                print(String(format: "    %-10s %5.1f%%  (S%d D%d I%d)  \"%@\"",
                             (entry.name as NSString).utf8String ?? "",
                             result.rate * 100,
                             result.substitutions, result.deletions, result.insertions,
                             hypothesis.isEmpty ? "<empty>" : String(hypothesis.prefix(60))))
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
                print("    \(entry.name): FAILED — \(error.localizedDescription)")
            }
        }

        return Row(engine: label,
                   result: WER.aggregate(results),
                   seconds: Date().timeIntervalSince(started),
                   audioSeconds: entries.reduce(0) { $0 + $1.duration },
                   failures: failures)
    }

    // MARK: report

    private static func report(_ rows: [Row], entries: [Entry]) {
        guard !rows.isEmpty else { print("No engine produced a result."); return }

        print("┌─────────────────────────┬────────┬───────┬───────┬───────┬────────┐")
        print("│ engine                  │    WER │  subs │  dels │   ins │    RTF │")
        print("├─────────────────────────┼────────┼───────┼───────┼───────┼────────┤")
        for row in rows.sorted(by: { $0.result.rate < $1.result.rate }) {
            let rtf = row.audioSeconds > 0 ? row.seconds / row.audioSeconds : 0
            print(String(format: "│ %-23@ │ %5.1f%% │ %5d │ %5d │ %5d │ %5.2fx │",
                         row.engine as NSString,
                         row.result.rate * 100,
                         row.result.substitutions,
                         row.result.deletions,
                         row.result.insertions,
                         rtf))
        }
        print("└─────────────────────────┴────────┴───────┴───────┴───────┴────────┘")
        print("")
        print("WER = (subs + dels + ins) / reference words, pooled across samples. Lower is better.")
        print("RTF = processing time / audio duration. Below 1.00x is faster than real time.")

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
