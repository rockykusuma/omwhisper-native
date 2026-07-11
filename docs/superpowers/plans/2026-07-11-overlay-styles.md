# Overlay 3-Style System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OVERLAY_SPEC §3's Orb and Whisper-line overlay presentations alongside the existing Full pill, selectable via an `overlayStyle` setting with a Porcelain "Recording overlay" picker.

**Architecture:** One fixed transparent click-through `NSPanel` (unchanged); `OverlayView` becomes a router that dispatches on the session-frozen style to `FullStyleOverlay` (today's pill, extracted verbatim) / `OrbStyleOverlay` / `WhisperLineOverlay`, all reusing `OmOrbView`. Minimal styles morph to a labeled capsule on error. A Preview button plays a canned HUD demo without touching the real dictation state machine.

**Tech Stack:** Swift 6 (MainActor-by-default), SwiftUI, AppKit (`NSPanel`), Swift Testing.

## Global Constraints

- **Overlay views are hard-dark**: use only named `Color.om*` tokens (`omBackground`, `omBorder`, `omEmerald`, `omTeal`, `omMint`, `omGlyphCore`, `omVolatile`, `omError`) — never adaptive/Porcelain colors. **`Color(hex:)` is `private` to `OmColors.swift`** — do not use it anywhere.
- **Settings picker is Porcelain**: the "Recording overlay" section uses `Color.Porcelain.*` tokens and `PorcelainSection`, matching the other General-settings sections. The mini-previews inside the cards are dark HUD chips (`om*` tokens) on the light cards — that contrast is intended (mockup).
- **Style is frozen per session**: the overlay renders from `sessionOverlayStyle` (captured when the overlay is shown), never live `overlayStyle` — spec §3 "applies next dictation only, never mid-session."
- **`@Observable`-over-UserDefaults pattern**: `overlayStyle` wraps its get in `access(keyPath:)` and set in `withMutation(keyPath:)` (see `engineKind`/`mcpAccessEnabled`).
- **Do not hand-edit `project.pbxproj`** — Xcode groups are file-system-synchronized.
- **Leave untouched** (pre-existing uncommitted local files): `docs/OVERLAY_SPEC.md`, `omwhisper-native.xcodeproj/project.pbxproj`, `docs/COMPETITOR_FLUIDVOICE.md`.
- Build/test command (the ONLY source of truth — this project's editor emits false "cannot find X" / "No such module" / "unable to type-check in reasonable time" SourceKit alarms; trust `xcodebuild`): `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`. Full-suite baseline: 270 tests.

---

### Task 1: `OverlayStyle` enum + AppState wiring

**Files:**
- Create: `omwhisper-native/UI/OverlayStyle.swift`
- Modify: `omwhisper-native/AppState.swift` (SettingsKeys; new Live-session props; overlayStyle setting; two overlay-show call sites)
- Test: `omwhisper-nativeTests/OverlayStyleTests.swift`

**Interfaces:**
- Produces: `nonisolated enum OverlayStyle: String, CaseIterable, Identifiable` with `title`/`caption`; `AppState.overlayStyle: OverlayStyle`, `AppState.sessionOverlayStyle: OverlayStyle` (private(set)), `AppState.overlayPreview: OverlayStyle?`.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/OverlayStyleTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct OverlayStyleTests {
    @Test func allCasesInOrder() {
        #expect(OverlayStyle.allCases == [.full, .orb, .whisperLine])
    }

    @Test func titles() {
        #expect(OverlayStyle.full.title == "Full")
        #expect(OverlayStyle.orb.title == "Orb")
        #expect(OverlayStyle.whisperLine.title == "Whisper line")
    }

    @Test func captionsAreNonEmptyAndDistinct() {
        let captions = OverlayStyle.allCases.map(\.caption)
        #expect(captions.allSatisfy { !$0.isEmpty })
        #expect(Set(captions).count == captions.count)
    }

    @Test func rawValueRoundTrips() {
        #expect(OverlayStyle(rawValue: "orb") == .orb)
        #expect(OverlayStyle(rawValue: "bogus") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: FAIL — "cannot find 'OverlayStyle' in scope".

- [ ] **Step 3: Create the enum**

Create `omwhisper-native/UI/OverlayStyle.swift`:

```swift
//
//  OverlayStyle.swift
//  OmWhisper
//
//  The three dictation-overlay presentations (OVERLAY_SPEC §3 / docs/overlay-styles.html).
//  Full = orb + live words; Orb = orb only; Whisper line = micro-ॐ + amplitude bars.
//

import Foundation

nonisolated enum OverlayStyle: String, CaseIterable, Identifiable {
    case full, orb, whisperLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full"
        case .orb: "Orb"
        case .whisperLine: "Whisper line"
        }
    }

    /// One-line card description (verbatim from the mockup).
    var caption: String {
        switch self {
        case .full: "Orb + live words as you speak. See everything land."
        case .orb: "Just the orb, breathing with your voice. No text."
        case .whisperLine: "A tiny pulse of sound. Barely there."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: PASS (274 total: 270 + 4 new).

- [ ] **Step 5: Add the SettingsKey**

In `AppState.swift`, in `nonisolated enum SettingsKeys`, after `static let engineKind = "engineKind"`:

```swift
    static let overlayStyle = "overlayStyle"
```

- [ ] **Step 6: Add the Live-session state**

In `AppState.swift`, in the `// MARK: Live session` block, after `var onboardingDemoActive = false`:

```swift
    /// Overlay presentation for the CURRENT session — captured from `overlayStyle`
    /// when the overlay is shown, so a mid-session settings change never reshapes a
    /// live overlay (OVERLAY_SPEC §3: "applies next dictation only").
    private(set) var sessionOverlayStyle: OverlayStyle = .full
    /// Non-nil only while the settings "Preview" demo runs (see previewOverlay).
    var overlayPreview: OverlayStyle?
```

- [ ] **Step 7: Add the overlayStyle setting**

In `AppState.swift`, alongside the other settings (e.g. after the `engineKind` property):

```swift
    /// Which overlay presentation to use. Bound by the "Recording overlay" picker;
    /// read into sessionOverlayStyle at dictation start. access/withMutation so the
    /// picker re-highlights on change.
    var overlayStyle: OverlayStyle {
        get {
            access(keyPath: \.overlayStyle)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.overlayStyle),
                  let style = OverlayStyle(rawValue: raw) else { return .full }
            return style
        }
        set {
            withMutation(keyPath: \.overlayStyle) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.overlayStyle)
            }
        }
    }
```

- [ ] **Step 8: Capture the session style at both overlay-show sites**

In `AppState.swift`, in `toggleOrStop(smart:)`'s `.idle` case, immediately before `overlay.show(appState: self)`:

```swift
            sessionOverlayStyle = overlayStyle
```

And in `beginPushToTalk()`, immediately before its `overlay.show(appState: self)`:

```swift
        sessionOverlayStyle = overlayStyle
```

- [ ] **Step 9: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, 274 passing.

- [ ] **Step 10: Commit**

```bash
git add omwhisper-native/UI/OverlayStyle.swift omwhisper-nativeTests/OverlayStyleTests.swift omwhisper-native/AppState.swift
git commit -m "feat(overlay): OverlayStyle enum + setting + session capture (Task 1)"
```

---

### Task 2: The two new style views + WhisperBars

Standalone views (wired into the router in Task 3). `barHeight` is a pure, tested helper.

**Files:**
- Create: `omwhisper-native/UI/OrbStyleOverlay.swift`
- Create: `omwhisper-native/UI/WhisperLineOverlay.swift` (holds `WhisperLineOverlay`, `WhisperBars`, and the `barHeight` helper)
- Test: `omwhisper-nativeTests/WhisperBarsTests.swift`

**Interfaces:**
- Consumes: `OmOrbView(appState:)`, `OmGlyph()` (a `Shape`), `Color.om*`, `AppState.audioLevel`.
- Produces: `struct OrbStyleOverlay: View` (`appState`, `isVisible`), `struct WhisperLineOverlay: View` (`appState`, `isVisible`), `struct WhisperBars: View` (`appState`), `nonisolated func barHeight(amplitude:index:phase:) -> CGFloat`.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/WhisperBarsTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import OmWhisper

struct WhisperBarsTests {
    @Test func staysWithinBounds() {
        for amp: Float in [-1, 0, 0.3, 1, 5] {
            for i in 0..<5 {
                let h = barHeight(amplitude: amp, index: i, phase: 0.3)
                #expect(h >= 5 && h <= 20)
            }
        }
    }

    @Test func risesWithAmplitude() {
        // Same index + phase → higher amplitude yields a taller (or equal) bar.
        #expect(barHeight(amplitude: 0.9, index: 2, phase: 1.0) > barHeight(amplitude: 0.2, index: 2, phase: 1.0))
    }

    @Test func differsPerIndex() {
        // The per-index phase offset makes bars ripple independently.
        #expect(barHeight(amplitude: 1.0, index: 0, phase: 0.0) != barHeight(amplitude: 1.0, index: 3, phase: 0.0))
    }

    @Test func neverFullyDead() {
        // A floor keeps the bars alive at zero amplitude (the settings-card preview
        // has no live audio) — still >= the 5pt minimum, and above it for most phases.
        #expect(barHeight(amplitude: 0, index: 1, phase: 0.5) >= 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: FAIL — "cannot find 'barHeight' in scope".

- [ ] **Step 3: Create `WhisperLineOverlay.swift` (helper + bars + lozenge)**

Create `omwhisper-native/UI/WhisperLineOverlay.swift`:

```swift
//
//  WhisperLineOverlay.swift
//  OmWhisper
//
//  The ultra-minimal overlay style (OVERLAY_SPEC §3): a small lozenge with a
//  vector micro-ॐ + 5 amplitude bars. No status label, no transcript.
//

import SwiftUI

/// Height (pt) of whisper-line bar `index` at animation `phase` (seconds), for
/// amplitude 0…1. A per-index phase offset makes the bars ripple; a small floor
/// keeps them alive when there's no live audio (the settings-card preview). Pure.
nonisolated func barHeight(amplitude: Float, index: Int, phase: Double) -> CGFloat {
    let minH: CGFloat = 5, maxH: CGFloat = 20
    let floor: CGFloat = 0.15   // never fully dead — matches the overlay's listening floor
    let amp = max(floor, min(1, CGFloat(amplitude)))
    let ripple = 0.6 + 0.4 * sin(phase * 7 + Double(index) * 1.1)   // 0.2…1.0
    let h = minH + (maxH - minH) * amp * CGFloat(ripple)
    return max(minH, min(maxH, h))
}

struct WhisperBars: View {
    let appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Static soft state (spec §11): fixed gentle bars, no animation.
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule().fill(Color.omMint.opacity(0.6)).frame(width: 3, height: 10)
                }
            }
        } else {
            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .fill(Color.omMint)
                            .frame(width: 3, height: barHeight(amplitude: appState.audioLevel, index: i, phase: phase))
                    }
                }
            }
        }
    }
}

struct WhisperLineOverlay: View {
    let appState: AppState
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 7) {
            OmGlyph()
                .fill(Color.omEmerald)
                .frame(width: 16, height: 16)
                .shadow(color: Color.omEmerald.opacity(0.6), radius: 4)
            if isVisible {
                WhisperBars(appState: appState)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 132, height: 38)
        .background(Color.omBackground.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: PASS (278 total).

- [ ] **Step 5: Create `OrbStyleOverlay.swift`**

Create `omwhisper-native/UI/OrbStyleOverlay.swift`:

```swift
//
//  OrbStyleOverlay.swift
//  OmWhisper
//
//  The compact overlay style (OVERLAY_SPEC §3): just the orb, no label or text.
//

import SwiftUI

struct OrbStyleOverlay: View {
    let appState: AppState
    let isVisible: Bool

    var body: some View {
        ZStack {
            // Gate the ticking Canvas on visibility so it stops when the panel is
            // ordered out (spec §10), matching FullStyleOverlay's orbZone.
            if isVisible {
                OmOrbView(appState: appState)
                    .frame(width: 84, height: 84)
            }
        }
        .frame(width: 96, height: 96)
        .background(Color.omBackground.opacity(0.92), in: Circle())
        .overlay(Circle().strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
    }
}
```

- [ ] **Step 6: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, 278 passing. (These views aren't wired into the panel yet — that's Task 3. SourceKit "type-check time" noise on the nested stacks is a false alarm; trust the build.)

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/UI/OrbStyleOverlay.swift omwhisper-native/UI/WhisperLineOverlay.swift omwhisper-nativeTests/WhisperBarsTests.swift
git commit -m "feat(overlay): Orb + Whisper-line style views + barHeight helper (Task 2)"
```

---

### Task 3: Refactor `OverlayView` into a style router

Extract the current pill into `FullStyleOverlay` (verbatim — no behavior change), add the router that dispatches on the session style, the shared entrance/exit envelope, and the minimal-style error capsule.

**Files:**
- Modify: `omwhisper-native/UI/OverlayView.swift` (full rewrite of the file's structure; Full content preserved)

**Interfaces:**
- Consumes: `OverlayStyle`, `AppState.sessionOverlayStyle`/`overlayPreview`/`dictation`/`overlayPhase`/`finalizedTranscript`/`volatileTranscript` (Task 1), `OrbStyleOverlay`/`WhisperLineOverlay` (Task 2), `OmOrbView`.

- [ ] **Step 1: Rewrite `OverlayView.swift`**

Replace the entire contents of `omwhisper-native/UI/OverlayView.swift` with:

```swift
//
//  OverlayView.swift
//  OmWhisper
//
//  Router for the dictation HUD's three presentation styles (OVERLAY_SPEC §3):
//  Full (pill + live words), Orb (orb only), Whisper line (micro-ॐ + bars). The
//  view is mounted ONCE for the panel's whole lifetime (see OverlayPanel), so
//  entrance/exit is animated via value-keyed `.animation`, never `.transition`.
//  The active style is frozen per session (sessionOverlayStyle) or driven by the
//  settings Preview (overlayPreview). Minimal styles morph to a labeled capsule
//  on error so failures always surface (§3).
//

import SwiftUI

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        appState.dictation != .idle || appState.overlayPhase == .polishing || appState.overlayPreview != nil
    }

    private var activeStyle: OverlayStyle {
        appState.overlayPreview ?? appState.sessionOverlayStyle
    }

    /// Minimal styles surface errors as a transient labeled capsule; Full shows
    /// the error inside its own pill.
    private var showsErrorCapsule: Bool {
        guard activeStyle != .full else { return false }
        if case .error = appState.overlayPhase { return true }
        return false
    }

    private var errorLabel: String {
        if case .error(let label) = appState.overlayPhase { return label }
        return ""
    }

    /// Small downward settle on a successful finalize (a modest stand-in for the
    /// spec's full +90pt slide — see the note in OverlayPanel).
    private var exitOffsetY: CGFloat {
        guard case .pasting = appState.overlayPhase else { return 0 }
        return 14
    }

    private var envelopeAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch appState.overlayPhase {
        case .cancelled: return .easeInOut(duration: 0.12)   // §4: 120ms fade, no translate
        default: return .easeInOut(duration: 0.3)
        }
    }

    var body: some View {
        content
            .offset(y: exitOffsetY)
            .opacity(isVisible ? 1 : 0)
            .animation(envelopeAnimation, value: isVisible)
            .animation(envelopeAnimation, value: appState.overlayPhase)
            .animation(envelopeAnimation, value: activeStyle)
    }

    @ViewBuilder private var content: some View {
        if showsErrorCapsule {
            ErrorCapsule(label: errorLabel)
        } else {
            switch activeStyle {
            case .full:        FullStyleOverlay(appState: appState, isVisible: isVisible)
            case .orb:         OrbStyleOverlay(appState: appState, isVisible: isVisible)
            case .whisperLine: WhisperLineOverlay(appState: appState, isVisible: isVisible)
            }
        }
    }
}

// MARK: - Full style (the default pill — behavior preserved verbatim)

private struct FullStyleOverlay: View {
    let appState: AppState
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusLabel: String {
        switch appState.overlayPhase {
        case .pasting, .cancelled:
            return ""
        case .polishing:
            return "POLISHING"
        case .error(let label):
            return label
        case .none:
            switch appState.dictation {
            case .idle: return ""
            case .starting: return "…"
            case .recording: return "LISTENING"
            case .finalizing: return "FINALIZING"
            }
        }
    }

    private var labelColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        if case .polishing = appState.overlayPhase { return .omTeal }
        switch appState.dictation {
        case .recording: return .omTeal
        case .finalizing: return .omMint
        default: return .omVolatile
        }
    }

    private var borderColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        return .omBorder
    }

    private var transcriptText: Text {
        var text = AttributedString(appState.finalizedTranscript)
        text.foregroundColor = .omGlyphCore
        var volatile = AttributedString(appState.volatileTranscript)
        volatile.foregroundColor = Color.omVolatile.opacity(0.5)
        text.append(volatile)
        return Text(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            orbZone
            VStack(alignment: .leading, spacing: 4) {
                if !statusLabel.isEmpty {
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(labelColor)
                }
                transcriptZone
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 480, height: 90, alignment: .leading)
        .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(borderColor.opacity(0.35), lineWidth: 1)
        )
        .clipped()
    }

    private var orbZone: some View {
        ZStack {
            if isVisible {
                OmOrbView(appState: appState)
            }
        }
        .frame(width: 64, height: 64)
    }

    private var transcriptZone: some View {
        transcriptText
            .font(.system(size: 15))
            .multilineTextAlignment(.leading)
            .lineLimit(1...2)
            .truncationMode(.head)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: appState.finalizedTranscript)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: appState.volatileTranscript)
    }
}

// MARK: - Minimal-style error capsule

private struct ErrorCapsule: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Color.omError)
            .padding(.horizontal, 18)
            .frame(minWidth: 180, minHeight: 38)
            .background(Color.omBackground.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.omError.opacity(0.65), lineWidth: 1))
    }
}

#Preview {
    OverlayView().environment(AppState())
}
```

- [ ] **Step 2: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, 278 passing. (The default `overlayStyle` is `.full`, so `sessionOverlayStyle` stays `.full` and every existing dictation renders exactly as before — the suite staying green is the regression proof for the Full-path extraction.)

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/OverlayView.swift
git commit -m "feat(overlay): route OverlayView by style; extract FullStyleOverlay + ErrorCapsule (Task 3)"
```

---

### Task 4: Preview path (`AppState.previewOverlay`)

Back the settings Preview button with a canned HUD demo that never touches the real dictation state machine.

**Files:**
- Modify: `omwhisper-native/AppState.swift` (a preview Task + amplitude override + the `audioLevel` getter + `previewOverlay`)

**Interfaces:**
- Consumes: `overlay.show/hide`, `overlayPreview`/`sessionOverlayStyle` (Task 1), `overlayPhase`, `finalizedTranscript`/`volatileTranscript`, `audioLevel`.
- Produces: `AppState.previewOverlay(_ style: OverlayStyle)`.

- [ ] **Step 1: Add the preview state + amplitude override**

In `AppState.swift`, near the other private core-loop collaborators/state (e.g. after `private let overlay = OverlayPanel()`):

```swift
    private var overlayPreviewTask: Task<Void, Never>?
    /// While a Preview demo runs, `audioLevel` returns this instead of the mic
    /// level, so the orb/bars look lively without real audio.
    private var previewAmplitude: Float?
```

- [ ] **Step 2: Route `audioLevel` through the override**

In `AppState.swift`, change the `audioLevel` property from:

```swift
    var audioLevel: Float {
        audioCapture.level
    }
```
to:
```swift
    var audioLevel: Float {
        if let previewAmplitude { return previewAmplitude }
        return audioCapture.level
    }
```

- [ ] **Step 3: Add `previewOverlay`**

In `AppState.swift`, near the overlay/dictation actions (e.g. after `runPolishSelectedText()`), add:

```swift
    /// Play a one-off canned demo of `style` in the real HUD so the settings
    /// picker's choice is visible without starting a real dictation. Guarded on
    /// idle; never touches `dictation`, so no history/paste/sounds/menu-icon
    /// side effects. A second call cancels the in-flight demo first.
    func previewOverlay(_ style: OverlayStyle) {
        guard dictation == .idle else { return }
        overlayPreviewTask?.cancel()
        overlayPreviewTask = Task { await runOverlayPreview(style) }
    }

    private func runOverlayPreview(_ style: OverlayStyle) async {
        sessionOverlayStyle = style
        overlayPreview = style
        overlayPhase = .none
        finalizedTranscript = ""
        volatileTranscript = ""
        previewAmplitude = 0.12
        overlay.show(appState: self)
        do {
            try await Task.sleep(for: .milliseconds(450))         // warming beat
            previewAmplitude = 0.5                                 // "listening" liveliness
            finalizedTranscript = "The overlay should match how much attention you want to give it."
            try await Task.sleep(for: .milliseconds(1500))         // listening w/ sample text
            overlayPhase = .pasting                                // finalize beat
            previewAmplitude = 0.12
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            // Cancelled by a second Preview press — fall through to cleanup.
        }
        overlay.hide()
        overlayPhase = .none
        overlayPreview = nil
        previewAmplitude = nil
        finalizedTranscript = ""
        volatileTranscript = ""
    }
```

- [ ] **Step 4: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, 278 passing. (No new tests — this is overlay/session wiring, verified live per project convention.)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "feat(overlay): previewOverlay canned HUD demo for the settings button (Task 4)"
```

---

### Task 5: The "Recording overlay" settings picker

**Files:**
- Modify: `omwhisper-native/UI/GeneralSettingsView.swift` (new Porcelain section + a private card view)

**Interfaces:**
- Consumes: `OverlayStyle` (Task 1), `AppState.overlayStyle`/`previewOverlay` (Tasks 1, 4), `OmOrbView`, `WhisperBars` (Task 2), `PorcelainSection`, `Color.Porcelain.*`, `Color.om*`.

- [ ] **Step 1: Add the picker section + card view**

In `omwhisper-native/UI/GeneralSettingsView.swift`, add a new `PorcelainSection` inside the `PorcelainPage`, immediately after the existing `PorcelainSection(eyebrow: "Appearance") { ... }` block:

```swift
            PorcelainSection(eyebrow: "Recording overlay") {
                Text("How OmWhisper appears while you dictate. Every style shows warming, listening, and errors — minimal styles just skip the live words.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
                HStack(spacing: 10) {
                    ForEach(OverlayStyle.allCases) { style in
                        OverlayStyleCard(
                            style: style,
                            appState: appState,
                            isSelected: state.overlayStyle == style,
                            onSelect: { state.overlayStyle = style }
                        )
                    }
                }
                Button("Preview") { appState.previewOverlay(appState.overlayStyle) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.mint)
            }
```

Then add this private view at the bottom of the file (after the `GeneralSettingsView` struct, before `#Preview` if present):

```swift
private struct OverlayStyleCard: View {
    let style: OverlayStyle
    let appState: AppState
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                miniPreview.frame(height: 44)
                Text(style.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text(style.caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.Porcelain.emerald.opacity(0.06) : Color.Porcelain.panel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.Porcelain.emerald : Color.Porcelain.hair,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.title) overlay style")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // Dark HUD chips on the light card (intended contrast, per the mockup).
    @ViewBuilder private var miniPreview: some View {
        switch style {
        case .full:
            HStack(spacing: 5) {
                Circle().fill(Color.omEmerald).frame(width: 10, height: 10)
                Capsule()
                    .fill(LinearGradient(colors: [Color.omMint.opacity(0.9), Color.omMint.opacity(0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 3)
            }
            .padding(.horizontal, 7)
            .frame(width: 120, height: 26)
            .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
        case .orb:
            OmOrbView(appState: appState)
                .frame(width: 30, height: 30)
                .frame(width: 40, height: 40)
                .background(Color.omBackground.opacity(0.92), in: Circle())
                .overlay(Circle().strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
        case .whisperLine:
            WhisperBars(appState: appState)
                .frame(width: 64, height: 20)
                .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
        }
    }
}
```

Note: `GeneralSettingsView.body` already has `@Bindable var state = appState` and `let appState = ...` via `@Environment(AppState.self)`. The card takes `appState` for its live orb/bars preview and uses `state.overlayStyle` for the binding. If `appState` isn't directly in scope in `body` (only `state`), add `let appState = state` is unnecessary — reference `appState` through the existing `@Environment(AppState.self) private var appState`. Confirm both `appState` (the environment value) and `state` (the `@Bindable`) are available; they are (see the existing Appearance/General sections that use `$state.*`).

- [ ] **Step 2: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, 278 passing.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/GeneralSettingsView.swift
git commit -m "feat(overlay): Recording overlay picker with live previews + Preview button (Task 5)"
```

---

## Live verification (owed — run after Task 5, on real hardware)

Automated tests cover the enum + `barHeight`. The real overlay is verified live:
1. With `overlayStyle = Full`, a normal dictation looks exactly as before (regression check).
2. Switch to **Orb** → next dictation shows just the orb bottom-center over another app; finalize pulse seals it.
3. Switch to **Whisper line** → next dictation shows the micro-ॐ + reacting bars; bars flash on finalize.
4. A silent session in Orb/Whisper-line surfaces the **NOTHING HEARD capsule**, then exits; in Full it flashes in-pill.
5. Switching style mid-session does NOT reshape the live overlay (applies next dictation only).
6. The picker's three cards render with live mini-previews (breathing mini-orb, rippling mini-bars); the **Preview** button plays the real HUD once with no history row, no paste, no menu-icon change.
7. Reduced Motion: bars/orb static-soft, error is a fade.

## Self-Review notes

- **Spec coverage:** the three styles (Tasks 2–3), session-freeze (Task 1), error capsule (Task 3), setting + picker + previews + Preview button (Tasks 1, 4, 5) each map to a task. `OmOrbView`/`OmGlyph` reused, not reimplemented.
- **Type consistency:** `OverlayStyle` (Task 1) used verbatim in Tasks 2/3/5; `barHeight(amplitude:index:phase:)` defined (Task 2) and tested (Task 2) and used in `WhisperBars` + the card (Tasks 2, 5); `OrbStyleOverlay(appState:isVisible:)` / `WhisperLineOverlay(appState:isVisible:)` signatures match the router's call sites (Task 3); `overlayPreview`/`sessionOverlayStyle`/`previewOverlay` defined (Tasks 1, 4) and consumed (Tasks 3, 5).
- **No placeholders:** every code step is complete. Dark-identity constraint holds (only `om*` + stdlib colors in overlay views; `Color.Porcelain.*` only in the settings card chrome).
- **Colors:** confirmed no `Color(hex:)` anywhere (it is `private` to `OmColors.swift`).
