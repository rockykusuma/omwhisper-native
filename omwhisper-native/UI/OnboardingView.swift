//
//  OnboardingView.swift
//  OmWhisper
//
//  First-run flow. Dark identity only (see CLAUDE.md scope rule). The "Try it"
//  step runs a REAL dictation session with onboardingDemoActive set, so nothing
//  is pasted or written to history — the field just mirrors the live transcript.
//

import SwiftUI

nonisolated enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, tryIt, aiPolish, done

    /// Advances to the following step; clamps at `.done`.
    var next: OnboardingStep { OnboardingStep(rawValue: rawValue + 1) ?? self }
    var isLast: Bool { self == .done }
}

/// Words-per-minute for the try-it readout. Pure so it's unit-testable.
nonisolated func wordsPerMinute(wordCount: Int, seconds: Double) -> Int {
    guard seconds > 0 else { return 0 }
    return max(0, Int((Double(wordCount) / (seconds / 60)).rounded()))
}

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            Color.omBackground.ignoresSafeArea()

            currentStep
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(48)

            VStack {
                HStack {
                    Spacer()
                    Button("Skip setup") { finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.omGlyphCore.opacity(0.4))
                        .padding(20)
                }
                Spacer()
                HStack(spacing: 9) {
                    ForEach(OnboardingStep.allCases, id: \.self) { s in
                        Circle()
                            .fill(s.rawValue <= step.rawValue ? Color.omEmerald : Color.omGlyphCore.opacity(0.15))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(width: 840, height: 620)
        .porcelainWindow(colorScheme: .dark)
    }

    @ViewBuilder private var currentStep: some View {
        switch step {
        case .welcome:     WelcomeStep { step = .permissions }
        case .permissions: PermissionsStep { step = .tryIt }
        case .tryIt:       TryItStep { step = .aiPolish }
        case .aiPolish:    AIPolishStep { step = .done }
        case .done:        DoneStep(onFinish: finish)
        }
    }

    private func finish() {
        appState.hasCompletedOnboarding = true
        dismissWindow(id: "onboarding")
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(AppState.self) private var appState
    let onBegin: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            OmOrbView(appState: appState)
                .frame(width: 190, height: 190)
                .padding(.bottom, 6)
            Text("OmWhisper")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            Text("Speak. It types.")
                .font(.system(size: 16))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
            Label("Your voice never leaves this Mac.", systemImage: "laptopcomputer")
                .font(.system(size: 14))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                .padding(.top, 10)
            OnboardingButton("Begin", action: onBegin).padding(.top, 22)
        }
    }
}

private struct PermissionsStep: View {
    @Environment(AppState.self) private var appState
    let onContinue: () -> Void
    @State private var result: (mic: Bool, speech: Bool)?
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 14) {
            KickerText("Sense 1 of 2 · Hearing")
            Text("Let it hear you")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            Text("One permission now. Audio is transcribed on this Mac and discarded — nothing stored, nothing sent.")
                .font(.system(size: 15))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow("Microphone", granted: result.mic)
                    permissionRow("Speech Recognition", granted: result.speech)
                }
                .padding(.top, 6)
                if !result.mic || !result.speech {
                    Text("The magic needs ears — you can enable these later in System Settings › Privacy & Security.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.omMint.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                }
                OnboardingButton("Continue", action: onContinue).padding(.top, 12)
            } else {
                OnboardingButton(requesting ? "Requesting…" : "Grant microphone & speech") {
                    requesting = true
                    Task {
                        result = await appState.requestDictationPermissions()
                        requesting = false
                    }
                }
                .disabled(requesting)
                .padding(.top, 12)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Color.omEmerald : Color.omError)
            Text(name).foregroundStyle(Color.omGlyphCore)
        }
        .font(.system(size: 14))
    }
}

private struct TryItStep: View {
    @Environment(AppState.self) private var appState
    let onNext: () -> Void
    @State private var sessionStart: Date?
    @State private var elapsed: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            KickerText("This is the overlay you'll see every day")
            VStack(spacing: 8) {
                Text("Hold to talk, then release")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.omGlyphCore)
                HStack(spacing: 6) {
                    Text("Hold").foregroundStyle(Color.omGlyphCore.opacity(0.6))
                    KeyCap("Fn")
                    Text("(Globe) — or").foregroundStyle(Color.omGlyphCore.opacity(0.6))
                    KeyCap("⌘⇧V")
                    Text("— and speak").foregroundStyle(Color.omGlyphCore.opacity(0.6))
                }
                .font(.system(size: 14))
            }

            transcriptField

            let text = appState.finalizedTranscript
            if appState.dictation == .idle, !text.isEmpty {
                let wpm = wordsPerMinute(
                    wordCount: text.split(whereSeparator: \.isWhitespace).count,
                    seconds: elapsed
                )
                Text("\(wpm) words / min")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.omMint)
                OnboardingButton("Feels fast →", action: onNext)
            } else {
                Button(appState.dictation == .recording ? "Stop" : "Start") {
                    appState.toggleDictation()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.omMint)
                .padding(.top, 4)
                if appState.dictation == .idle {
                    Button("Skip this step →") { onNext() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.omGlyphCore.opacity(0.4))
                        .padding(.top, 2)
                }
            }
        }
        .onChange(of: appState.dictation) { _, newValue in
            switch newValue {
            case .recording:
                // Set the demo flag per session (not on appear) so it is active exactly
                // from record-start through stopDictation's end (which clears it). A
                // session that outlives this step (e.g. Skip setup mid-record) is still
                // suppressed, and a visit with no dictation never sets the flag at all.
                appState.onboardingDemoActive = true
                sessionStart = Date()
            case .idle:
                if let start = sessionStart {
                    elapsed = Date().timeIntervalSince(start)
                    sessionStart = nil
                }
            default:
                break
            }
        }
    }

    private var transcriptField: some View {
        let display = (appState.finalizedTranscript + " " + appState.volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(display.isEmpty ? "Your words will appear here…" : display)
            .font(.system(size: 16))
            .foregroundStyle(display.isEmpty ? Color.omGlyphCore.opacity(0.3) : Color.omGlyphCore)
            .frame(width: 500, height: 90, alignment: .topLeading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.omEmerald.opacity(0.25)))
    }
}

private struct DoneStep: View {
    @Environment(AppState.self) private var appState
    let onFinish: () -> Void

    var body: some View {
        @Bindable var state = appState
        return VStack(spacing: 14) {
            OmOrbView(appState: appState)
                .frame(width: 150, height: 150)
            Text("It lives in your menu bar now")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            HStack(spacing: 24) {
                hotkey(["⌘", "⇧", "V"], caption: "toggle dictation")
                hotkey(["Fn"], caption: "hold to talk")
            }
            .padding(.top, 8)
            Toggle("Launch OmWhisper when I log in", isOn: $state.launchAtLogin)
                .toggleStyle(.checkbox)
                .tint(Color.omEmerald)
                .foregroundStyle(Color.omGlyphCore)
                .padding(.top, 8)
            OnboardingButton("Start dictating", action: onFinish).padding(.top, 12)
        }
    }

    private func hotkey(_ keys: [String], caption: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Color.omGlyphCore.opacity(0.5))
        }
    }
}

/// Offers the two ON-DEVICE backends. Cloud is deliberately absent: it needs an
/// API key, costs money and sends text off the Mac, none of which belongs in a
/// first-run wizard.
///
/// Writes `dictationPolish` and nothing else. `FeatureBackend.ollama(model:)`
/// carries the model inline, so there is no second write to keep in sync, and
/// leaving the Default row alone keeps the other four features at
/// `.useDefault` without needing a guard.
private struct AIPolishStep: View {
    @Environment(AppState.self) private var appState
    let onNext: () -> Void

    @State private var ollama: OllamaState?
    @State private var picked = ""

    var body: some View {
        VStack(spacing: 12) {
            // Smaller than Welcome's 190 and Done's 150: this is the only step
            // carrying two cards, and the orb is here to anchor the step to the
            // rest of the flow, not to be the subject of it.
            OmOrbView(appState: appState)
                .frame(width: 96, height: 96)
            KickerText("OPTIONAL")
            Text("Want your words cleaned up?")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            Text("Both of these run on this Mac. Nothing is sent anywhere.")
                .font(.system(size: 13))
                .foregroundStyle(Color.omGlyphCore.opacity(0.6))

            appleCard
            ollamaCard

            Button("Not now", action: onNext)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.omGlyphCore.opacity(0.65))
                .padding(.top, 2)
            Text("You can change this any time in Settings → AI Models.")
                .font(.system(size: 11))
                .foregroundStyle(Color.omGlyphCore.opacity(0.4))
        }
        // Re-runs whenever the user comes back to this step; Refresh below
        // re-runs it on demand after they pull a model in Terminal.
        .task { await refresh() }
    }

    private func refresh() async {
        let state = await OllamaPresence.detect(baseURL: appState.ollamaBaseURL)
        ollama = state
        // Preselect the recommended model when it is installed — but never
        // overwrite a choice already made, so Refresh cannot undo a selection.
        if case .ready(let models) = state, picked.isEmpty {
            picked = OllamaPresence.recommended(in: models) ?? ""
        }
    }

    // MARK: Apple Intelligence

    @ViewBuilder private var appleCard: some View {
        OnboardingCard(title: "Apple Intelligence") {
            // unavailableReason() names the REAL cause, including the en-IN case
            // where availability reports .available and every generation throws.
            // Summarising it here would reintroduce the bug it was written for.
            if let reason = SystemLLM.unavailableReason() {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
            } else {
                Text("Built into macOS. No download.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                OnboardingButton("Use Apple Intelligence") {
                    appState.setBackend(.system, for: .dictationPolish)
                    onNext()
                }
            }
        }
    }

    // MARK: Ollama

    @ViewBuilder private var ollamaCard: some View {
        OnboardingCard(title: "Ollama") {
            switch ollama {
            case nil:
                Text("Checking…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))

            case .ready(let models):
                // A 3B model makes polish and summaries look broken, and the
                // picker otherwise presents it as an equal choice. The pull
                // command's recommendation is invisible to anyone who already
                // has models installed — which is most people who get here.
                Picker("", selection: $picked) {
                    Text("Choose a model").tag("")
                    ForEach(models, id: \.self) { model in
                        Text(OllamaPresence.isRecommended(model) ? "\(model) — recommended" : model)
                            .tag(model)
                    }
                }
                .labelsHidden()
                .tint(Color.omEmerald)
                OnboardingButton("Use Ollama") {
                    appState.setBackend(.ollama(model: picked), for: .dictationPolish)
                    onNext()
                }
                // .disabled propagates to the inner Button, but OnboardingButton
                // paints its own gradient capsule and will NOT dim — it would
                // look enabled while doing nothing. Fade it explicitly.
                .disabled(picked.isEmpty)
                .opacity(picked.isEmpty ? 0.45 : 1)

            case .runningNoModels:
                Text("Ollama is running, but has no models yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                commandRow
                refreshButton

            case .installedNotRunning:
                Text("Ollama is installed but not running.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                HStack(spacing: 10) {
                    linkButton("Open Ollama") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
                    }
                    refreshButton
                }

            case .notInstalled:
                Text("Ollama isn’t installed. It’s a free local model runner.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                HStack(spacing: 10) {
                    linkButton("Get Ollama") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                    }
                    refreshButton
                }
                commandRow
            }
        }
    }

    private var commandRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(OllamaPresence.pullCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.85))
                linkButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OllamaPresence.pullCommand, forType: .string)
                }
            }
            // The size is stated because recommending a model on answer quality
            // without checking whether the hardware can hold it is a mistake
            // this project has already made once.
            Text("\(OllamaPresence.recommendedModelSize) download · needs at least 16 GB of memory")
                .font(.system(size: 11))
                .foregroundStyle(Color.omGlyphCore.opacity(0.4))
        }
    }

    private var refreshButton: some View {
        linkButton("Refresh") { Task { await refresh() } }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.omEmerald)
    }
}

/// A bordered panel on the dark onboarding ground. Local to onboarding on
/// purpose — `omCard()` is a Porcelain component and follows the appearance
/// picker, which every onboarding step ignores.
private struct OnboardingCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.omGlyphCore.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.omGlyphCore.opacity(0.12)))
        .frame(maxWidth: 380)
    }
}

// MARK: - Local styling helpers (dark identity)

private struct OnboardingButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(white: 0.03))
                .padding(.vertical, 13)
                .padding(.horizontal, 34)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [Color.omEmerald, Color.omTeal],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.omMint)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.omEmerald.opacity(0.3)))
    }
}

private struct KickerText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .medium))
            .tracking(2)
            .foregroundStyle(Color.omEmerald.opacity(0.9))
    }
}
