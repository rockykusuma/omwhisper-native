//
//  ReplyAssistSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct ReplyAssistSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Reply assist (double-tap right ⌥)", isOn: $state.replyAssistEnabled)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Double-tap right ⌥ in any text field to silently draft a reply, continue a draft, or rewrite a selection from context, and type it straight in. Off by default.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            .padding(16)
            .omCard()
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Porcelain.bg)
    }
}

#Preview {
    ReplyAssistSettingsView().environment(AppState())
}
