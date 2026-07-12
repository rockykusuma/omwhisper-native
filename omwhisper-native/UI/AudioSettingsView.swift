//
//  AudioSettingsView.swift
//  OmWhisper
//
//  Mic input device + recording sound cues. Mirrors the old app's "Audio" tab
//  (Settings.tsx) — no live level meter here, since the old app didn't have
//  one in Settings either (only in the recording overlay).
//

import SwiftUI

struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Microphone") {
                Picker("Input Device", selection: $state.audioInputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            }

            PorcelainSection(eyebrow: "Sound") {
                Toggle("Recording sounds", isOn: $state.soundEnabled)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $state.soundVolume, in: 0...1, step: 0.05) {
                        Text("Sound Volume")
                    }
                    .tint(Color.Porcelain.emerald)
                    Text("Chime volume · \(Int(state.soundVolume * 100))%")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                }
                .disabled(!state.soundEnabled)
            }
        }
        .task { devices = await AudioCapture.loadInputDevices() }
    }
}

#Preview {
    AudioSettingsView().environment(AppState())
}
