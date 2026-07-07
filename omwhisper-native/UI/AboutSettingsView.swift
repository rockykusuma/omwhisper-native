//
//  AboutSettingsView.swift
//  OmWhisper
//
//  Version/attribution only — no analytics/crash-reporting toggles (no such
//  backend exists in this app), no feedback form (needs email infra the old
//  app had via Resend, not ported), no update UI (Sparkle's job, M2 pending).
//

import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: appVersionString)
                Text("Powered by Apple's on-device Speech framework.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Link("Documentation", destination: URL(string: "https://rockykusuma.github.io/omwhisper/")!)
            }
            Section {
                Text("Made with ॐ by Rakesh Kusuma")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(shortVersion) (\(build))"
    }
}

#Preview {
    AboutSettingsView()
}
