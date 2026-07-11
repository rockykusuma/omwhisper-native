//
//  AboutSettingsView.swift
//  OmWhisper
//
//  Version/attribution + a Check for Updates button (Sparkle) — relocated here
//  when the status-bar right-click menu was removed. No analytics/crash-reporting
//  toggles (no such backend exists), no feedback form (needs email infra the old
//  app had via Resend, not ported).
//

import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        PorcelainPage {
            PorcelainSection {
                LabeledContent("Version", value: appVersionString)
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Powered by Apple's on-device Speech framework.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }

            PorcelainSection {
                Link("Documentation", destination: URL(string: "https://rockykusuma.github.io/omwhisper/")!)
                    .foregroundStyle(Color.Porcelain.emerald)
                Button("Check for Updates…") {
                    (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Porcelain.emerald)
            }

            Text("Made with ॐ by Rakesh Kusuma")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
                .frame(maxWidth: .infinity, alignment: .center)
        }
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
