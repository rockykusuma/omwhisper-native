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

if CommandLine.arguments.contains("--mcp") {
    MCPLauncher.run()
} else {
    OmWhisperApp.main()
}
