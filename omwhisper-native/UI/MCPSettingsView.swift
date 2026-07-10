//
//  MCPSettingsView.swift
//  OmWhisper
//
//  Off by default, like every Smriti-derived feature. The toggle itself has
//  no in-process effect -- it's read fresh by a future `OmWhisper --mcp`
//  subprocess launch (see MCPLauncher.swift), so revoking access here takes
//  effect on that subprocess's next launch, not instantly for an
//  already-running Claude Desktop session.
//

import SwiftUI

struct MCPSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        return PorcelainPage {
            PorcelainSection {
                Toggle("Allow MCP access", isOn: $state.mcpAccessEnabled)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                if state.mcpAccessEnabled {
                    configSection
                }
                Text("Lets Claude Desktop query your captured memory, chronicles, and dictation history through the Model Context Protocol. Read-only, off by default. Revoking access takes effect the next time Claude Desktop launches the connection, not instantly.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add this to Claude Desktop's config (\(configPath)):")
                .font(.callout)
                .foregroundStyle(Color.Porcelain.ink)
            Text(configJSON)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.Porcelain.ink)
                .textSelection(.enabled)
                .padding(8)
                .background(Color.Porcelain.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button("Copy Config") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(configJSON, forType: .string)
            }
        }
    }

    private var configPath: String {
        "~/Library/Application Support/Claude/claude_desktop_config.json"
    }

    private var configJSON: String {
        let binaryPath = Bundle.main.executablePath ?? "/Applications/OmWhisper.app/Contents/MacOS/OmWhisper"
        return """
            {
              "mcpServers": {
                "omwhisper": {
                  "command": "\(binaryPath)",
                  "args": ["--mcp"]
                }
              }
            }
            """
    }
}

#Preview {
    MCPSettingsView().environment(AppState())
}
