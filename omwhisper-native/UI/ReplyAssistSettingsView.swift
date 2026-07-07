//
//  ReplyAssistSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct ReplyAssistSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Toggle("Reply assist (double-tap right ⌥)", isOn: $state.replyAssistEnabled)
            Text("Double-tap right ⌥ in any text field to draft a reply, continue a draft, or rewrite a selection — silently from context, or by holding to speak. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ReplyAssistSettingsView().environment(AppState())
}
