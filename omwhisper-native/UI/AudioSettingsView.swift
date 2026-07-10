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
    @State private var devices = AudioCapture.availableInputDevices()

    var body: some View {
        @Bindable var state = appState
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MICROPHONE").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
                    Picker("Input Device", selection: $state.audioInputDeviceUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                }
                .padding(16)
                .omCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("SOUND").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
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
                .padding(16)
                .omCard()
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Porcelain.bg)
        .onAppear { devices = AudioCapture.availableInputDevices() }
    }
}

#Preview {
    AudioSettingsView().environment(AppState())
}
