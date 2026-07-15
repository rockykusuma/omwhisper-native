//
//  MeetingDiagnostics.swift
//  OmWhisper
//
//  DEBUG-only: runs the diarized-transcript pipeline against an already-recorded
//  meeting directory and prints each stage to stdout. Exists because this app's
//  os_log output is not retrievable on the dev build (`log show` returns zero
//  lines even while it runs), so a stdout subcommand is the only working
//  evidence channel for the file->whisper->diarizer chain. Whole file is
//  #if DEBUG, matching MeetingSelfTest.swift's convention.
//
//  Run: OmWhisper.app/Contents/MacOS/OmWhisper --diagnose-meeting <dir>
//

#if DEBUG
import Foundation

@MainActor
enum MeetingDiagnostics {
    static func run(directory: URL) async {
        print("=== meeting diagnostics: \(directory.lastPathComponent) ===")

        for track in ["me.caf", "them.caf"] {
            let url = directory.appendingPathComponent(track)
            let duration = MeetingTranscriber.audioDuration(url)
            let samples = MeetingTranscriber.read16kMono(url)
            print("\(track): duration=\(String(format: "%.2f", duration))s read16kMono=\(samples.count) samples")
        }

        let whisper = WhisperEngine()
        print("whisper.isReady = \(whisper.isReady)")

        let themSamples = MeetingTranscriber.read16kMono(directory.appendingPathComponent("them.caf"))
        if !themSamples.isEmpty {
            do {
                let segs = try await whisper.transcribeSegments(samples: themSamples)
                print("whisper.transcribeSegments(them) -> \(segs.count) segments")
            } catch {
                print("whisper.transcribeSegments(them) THREW: \(error)")
            }
            do {
                let speakers = try await MeetingDiarizer.diarize(samples: themSamples)
                print("MeetingDiarizer.diarize(them) -> \(speakers.count) speakers: \(Set(speakers.map(\.id)).sorted())")
            } catch {
                print("MeetingDiarizer.diarize(them) THREW: \(error)")
            }
        }

        do {
            let text = try await MeetingTranscriber.diarizedTranscript(directory: directory, whisper: whisper)
            print("diarizedTranscript -> \(text.count) chars")
            print("--- transcript ---\n\(text)")
        } catch {
            print("diarizedTranscript THREW: \(error)")
        }
        print("=== done ===")
    }
}
#endif
