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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Version", value: appVersionString)
                        .foregroundStyle(Color.Porcelain.ink)
                    Text("Powered by Apple's on-device Speech framework.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                }
                .padding(16)
                .omCard()

                VStack(alignment: .leading) {
                    Link("Documentation", destination: URL(string: "https://rockykusuma.github.io/omwhisper/")!)
                        .foregroundStyle(Color.Porcelain.emerald)
                }
                .padding(16)
                .omCard()

                Text("Made with ॐ by Rakesh Kusuma")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Porcelain.bg)
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
