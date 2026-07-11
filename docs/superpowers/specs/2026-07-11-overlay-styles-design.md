# Overlay 3-Style System (Full / Orb / Whisper-line) — Design

**Date:** 2026-07-11
**Milestone:** Overlay spec conformance (`docs/OVERLAY_SPEC.md` §3). The dictation HUD
currently ships only the **Full** style; this adds the **Orb** and **Whisper-line**
presentations and an `overlayStyle` setting, per the canonical mockup `docs/overlay-styles.html`.

## Goal

Let the user choose how the dictation overlay presents itself while they dictate — Full (orb +
live words), Orb (orb only), or Whisper-line (a tiny lozenge of sound) — with the choice made in
a Porcelain "Recording overlay" settings card. One dictation engine, three presentations.

## Decisions (2026-07-11)

- **Picker fidelity**: cards with **live mini-previews** + an on-demand **Preview button** (not
  the mockup's auto-demo-on-every-select). The Preview button plays the real HUD once.
- **Errors always surface** (per spec §3): minimal styles (Orb, Whisper-line) transiently morph
  into a small capsule showing the error label — built, not simplified to a bare red flash.
- **Vector micro-ॐ** for Whisper-line: reuse `OmGlyph` (the existing vector path), not a font
  glyph, per spec §5.3.
- **Style frozen per session**: read once at dictation start, never changes mid-session (spec §3:
  "applies next dictation only").

## Background (verified against current code)

- **`UI/OverlayView.swift`** is the Full pill today: an `HStack` of `orbZone` (a mount-gated
  `OmOrbView`) + a `VStack` of status label + 2-line transcript, sized `480×90` inside a
  `RoundedRectangle(cornerRadius: 28)` with `omBackground`/`omBorder`. It reads
  `appState.dictation`/`overlayPhase`/`finalizedTranscript`/`volatileTranscript`, is mounted once
  for the panel's lifetime, and animates via value-keyed `.animation` (never `.transition`).
- **`UI/OverlayPanel.swift`** hosts one cached `NSHostingView(OverlayView())` in a fixed
  `500×115` transparent, non-activating, click-through `NSPanel` (`ignoresMouseEvents`, floating,
  `canJoinAllSpaces`, `stationary`, `fullScreenAuxiliary`), positioned bottom-center 90pt up.
  `show(appState:)` orders it front; `hide()` orders it out.
- **`OmOrbView(appState:, palette: .dark)`** already implements warming stroke-in, the reactive
  energy field, the pulse ring, the breathing glyph, and the finalize pulse — driven by
  `appState.audioLevel` + `appState.dictation`. It is reused verbatim by all three styles.
- **`OmGlyph`** (`UI/OmGlyph.swift`) is the existing vector ॐ path — reused small for the
  Whisper-line micro-glyph.
- **`AppState.audioLevel: Float`** (RMS 0–1) is the amplitude source for the Whisper-line bars.
- **`AppState`** owns `private let overlay = OverlayPanel()`; the overlay is shown from
  `toggleOrStop`/`beginPushToTalk` (early-show on `.starting`) and hidden in the exit flow.
  Settings persist via UserDefaults; picker-bound settings use `access(keyPath:)`/
  `withMutation(keyPath:)` (see `mcpAccessEnabled`).
- **`OverlayPhase`** enum drives the terminal flourishes (`pasting`/`error(label:)`/`cancelled`/
  `polishing`/`none`); the error case already carries its label.

## Architecture

### 1. `OverlayStyle` (new — `UI/OverlayStyle.swift`)

```
nonisolated enum OverlayStyle: String, CaseIterable, Identifiable {
    case full, orb, whisperLine
    var id: String { rawValue }
    var title: String        // "Full" | "Orb" | "Whisper line"
    var caption: String      // one-line card description (from the mockup copy)
}
```
Card copy (verbatim from the mockup):
- Full — "Orb + live words as you speak. See everything land."
- Orb — "Just the orb, breathing with your voice. No text."
- Whisper line — "A tiny pulse of sound. Barely there."

Default `.full`. Pure — unit-tested (cases, titles, captions, default resolution).

### 2. `AppState`

- `var overlayStyle: OverlayStyle` — UserDefaults-backed (`SettingsKeys.overlayStyle`,
  `access`/`withMutation`, default `.full`). This is what the picker binds to.
- `private(set) var sessionOverlayStyle: OverlayStyle = .full` — captured from `overlayStyle` the
  instant the overlay is shown for a dictation (in `toggleOrStop`/`beginPushToTalk`, alongside the
  existing `overlay.show`). `OverlayView` renders from THIS, so mid-session setting changes never
  reshape a live overlay.
- `var overlayPreview: OverlayStyle?` — non-nil only while the Preview button's canned demo runs.
- `func previewOverlay(_ style: OverlayStyle)` — guarded on `dictation == .idle`. Sets
  `overlayPreview = style` and `sessionOverlayStyle = style`, shows the panel, and drives a canned
  sequence on a `Task`: warming (`…`) → listening with a short sample `finalizedTranscript`
  ("The overlay should match how much attention you want to give it.") → a finalize beat
  (`overlayPhase = .pasting`) → hide, then reset `overlayPhase = .none`, clear `overlayPreview`,
  and clear the sample `finalizedTranscript`. It never touches `dictation`, so the menu icon,
  sounds, history, and paste path are all untouched. A second press while a preview runs cancels
  the prior Task first (no overlap).

### 3. `OverlayView` becomes a router (`UI/OverlayView.swift`)

`OverlayView` keeps ownership of the shared envelope and dispatches on the active style:
- Active style = `appState.overlayPreview ?? appState.sessionOverlayStyle`.
- `isVisible` (unchanged: `dictation != .idle || overlayPhase == .polishing`), plus visible while
  `overlayPreview != nil`.
- Shared across styles: the entrance/exit opacity + settle envelope, the border `errflash`, and
  the **minimal-style error capsule** (see §5).
- Body switches:
  - `.full` → `FullStyleOverlay` (the current pill content, extracted verbatim — no behavior change).
  - `.orb` → `OrbStyleOverlay`.
  - `.whisperLine` → `WhisperLineOverlay`.
- All three are bottom-center-anchored inside the fixed transparent panel, so only the drawn
  shape is visible; switching styles or morphing to the error capsule is pure SwiftUI layout.

### 4. The style views

- **`FullStyleOverlay`** (extracted from today's `OverlayView` body): 500×100 pill, orb + label +
  2-line transcript. Byte-for-byte the current behavior, just moved into its own view.
- **`OrbStyleOverlay`** (new): a 96×96 circle (`omBackground` @92%, 1pt `omBorder`) containing
  `OmOrbView(appState:)` at ~84pt. No label, no text. Warming/listening/finalize all come from
  `OmOrbView` already.
- **`WhisperLineOverlay`** (new): a 132×38 lozenge (r19, `omBackground`/`omBorder`) containing a
  small `OmGlyph` micro-ॐ (mint, soft glow) + `WhisperBars`.
  - **`WhisperBars`** (new): 5 mint capsules whose heights track `appState.audioLevel`, sampled
    once per frame via `TimelineView(.animation)` (same cadence as `OmOrbView`), each bar phase-
    offset so they ripple. On the finalize beat the bars flash to `omMint` peak once. A pure
    `barHeight(amplitude:index:phase:) -> CGFloat` helper (called once per bar per frame) is
    unit-tested; the `TimelineView` render is verified live. Static soft state under Reduced Motion.

### 5. Error handling (shared, in the router)

On `overlayPhase == .error`:
- **Full**: unchanged — the in-pill border + label flash `omError` ("NOTHING HEARD" /
  "SOMETHING BROKE — TEXT COPIED").
- **Orb / Whisper-line**: the shape transiently morphs into a small capsule (~180×38, r19,
  `omBackground`, border flashing `omError`) showing the error label in `omError` (hiding the
  orb / bars / micro-ॐ), then runs the normal error-exit. Because the panel is a fixed transparent
  canvas, this is a SwiftUI frame + content animation — no panel resize. The morph respects
  Reduced Motion (fade, no shape spring).

### 6. `OverlayPanel` (minor)

- Confirm the fixed panel comfortably contains the largest style + its entrance/exit headroom
  (Full 500×100 is the largest; the current 500×115 already fits — Orb/Whisper-line are smaller).
  No per-style resizing.
- No new public surface strictly required — the Preview path drives visibility through the same
  `overlay.show(appState:)`/`overlay.hide()` the dictation path uses, orchestrated by
  `AppState.previewOverlay(_:)`.
- If the NSWindow shadow (`hasShadow`) tracks the smaller shapes poorly, switch to a SwiftUI
  shadow on each style's shape and set `hasShadow = false` — an implementation detail to settle
  live, noted here so it isn't a surprise.

### 7. Settings picker — `UI/GeneralSettingsView.swift`

A new "Recording overlay" `PorcelainSection` (below Appearance):
- A row of three selectable cards (one per `OverlayStyle.allCases`): each shows the style title,
  its caption, and a **live mini-preview**:
  - Full → a mini-pill glyph (small rounded dark rect with a tiny orb dot + a faux transcript bar).
  - Orb → a small real `OmOrbView(appState:)` (~44pt) breathing at idle.
  - Whisper line → a mini-lozenge with a small animated `WhisperBars` (idle murmur).
- The selected card is emerald-highlighted (bound to `$state.overlayStyle`); tapping selects.
- A **"Preview"** button → `appState.previewOverlay(appState.overlayStyle)` plays the real HUD once.
- Header copy (from the mockup): "How OmWhisper appears while you dictate. Every style shows
  warming, listening, and errors — minimal styles just skip the live words."
- Porcelain tokens throughout, real `Button`s (keyboard/VoiceOver), matching the hub's D4a rebuild.

### 8. Tests (`omwhisper-nativeTests/`)

Pure logic only (SwiftUI/orb/panel/preview verified live, per project convention):
- `OverlayStyleTests` — `allCases` order, `title`/`caption` per case, `rawValue` round-trip,
  default resolution (`.full`).
- `WhisperBarsTests` — the pure `barHeight(amplitude:index:phase:)` helper: clamps to a
  min/max, rises with amplitude, differs per index (phase offset). No timing/rendering.

Full suite stays green (270 → ~278).

## Live verification (owed)

Pure pieces are unit-tested; the real overlay is verified live:
1. Each style renders correctly bottom-center over another app during a real dictation (Full
   unchanged; Orb shows just the orb; Whisper-line shows micro-ॐ + reacting bars).
2. Warming shows on keydown in every style; finalize pulse (orb) / bar flash (line) seals each.
3. A silent session surfaces NOTHING HEARD in every style — including the minimal-style capsule
   morph — then exits cleanly.
4. Switching style in Settings applies to the **next** dictation, never mid-session.
5. The picker's live mini-previews animate; the Preview button plays the real HUD once without
   starting a real dictation (no history row, no paste, menu icon unaffected).
6. Reduced Motion: bars/orb go static-soft, the error morph is a fade.

## Out of scope (explicit)

- **§13 measured sign-offs** (60fps <3% CPU Instruments run, 3-minute pill-height check) — a
  measurement pass, not this feature.
- **Auto-demo on every card select** — replaced by the on-demand Preview button.
- **The full 90pt entrance slide** (spec §4/§8) — the existing modest settle is kept; re-tuning
  the entrance/exit distance is a pre-existing `ponytail` deviation, orthogonal to the styles.
- **Overlay placement setting** (bottom-center vs. under-notch, spec §14 open question) — not part
  of this cut.
