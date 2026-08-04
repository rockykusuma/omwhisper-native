//
//  MeetingDetectionDiagnostics.swift
//  OmWhisper
//
//  DEBUG-only: prints what meeting detection actually sees. Exists because a
//  unit test asserting "something is capturing input" passes on a silent CI
//  runner and proves nothing -- the only real check is running this during a
//  real call. Same stdout-as-evidence-channel convention as MeetingDiagnostics
//  and MeetingAIDiagnostics.
//
//  Run: OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev --diagnose-meeting-detection
//

#if DEBUG
import Foundation

nonisolated enum MeetingDetectionDiagnostics {
    static func run() {
        print("=== meeting detection ===")
        let processes = AudioProcesses.capturingInput()
        print("processes capturing microphone input: \(processes.count)")
        for process in processes {
            print("  \(process.bundleID) pid=\(process.pid)")
        }
        if processes.isEmpty {
            print("  <none> — nothing has the mic open right now")
        }
    }
}
#endif
