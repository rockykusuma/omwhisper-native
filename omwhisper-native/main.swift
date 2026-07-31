//
//  main.swift
//  OmWhisper
//
//  Replaces @main on OmWhisperApp so CommandLine.arguments can be inspected
//  before SwiftUI's lifecycle starts. App.main() is the same static function
//  @main would have synthesized a call to -- calling it explicitly here is
//  the standard way to branch ahead of it.
//

import Foundation
import SwiftUI

#if DEBUG
if let flag = CommandLine.arguments.firstIndex(of: "--diagnose-meeting"),
   flag + 1 < CommandLine.arguments.count {
    await MeetingDiagnostics.run(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--wer"),
   flag + 1 < CommandLine.arguments.count {
    await WERBenchmark.run(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
}
#endif

if CommandLine.arguments.contains("--mcp") {
    MCPLauncher.run()
} else {
    // GUI branch only — the --mcp subprocess is meant to run alongside the app.
    SingleInstance.enforce()
    OmWhisperApp.main()
}
