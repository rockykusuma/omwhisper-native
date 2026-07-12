//
//  KeyRecorderView.swift
//  OmWhisper
//
//  Records a keyboard shortcut for a KeyCombo binding. Click → "Press keys…" →
//  the next keyDown (captured by a LOCAL NSEvent monitor, so it never leaks into
//  a field) becomes the combo, provided it has a ⌘/⌃/⌥ modifier. Esc cancels.
//

import SwiftUI
import AppKit

struct KeyRecorderView: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? "Press keys…" : combo.display) {
                recording ? stop() : startRecording()
            }
            .buttonStyle(.bordered)
            .tint(Color.Porcelain.emerald)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func startRecording() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // swallow keystrokes while recording
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }   // Esc = cancel, keep old combo
        let mods = event.modifierFlags.intersection(KeyCombo.relevantMask)
        let candidate = KeyCombo(
            keyCode: event.keyCode,
            modifiers: mods.rawValue,
            label: (event.charactersIgnoringModifiers ?? "").uppercased())
        guard candidate.hasRequiredModifier, !candidate.label.isEmpty else {
            hint = "Use at least one of ⌘ ⌃ ⌥."
            return   // stay recording
        }
        combo = candidate
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
