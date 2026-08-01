# Overlay Spec — the Om Orb Dictation HUD

> Design + behavior spec for the signature dictation overlay: a voice-reactive
> energy field around a steady ॐ glyph, with words flowing in live as you speak.
> This is OmWhisper's brand moment — the thing a user sees 40× a day and shows
> a friend once. It must survive both.
>
> Status: **approved direction** (mockup reviewed 2026-07-07). Supersedes the
> current status-dot `OverlayView`. An earlier avatar concept was explicitly
> rejected — do not reintroduce character/face imagery.
>
> Living reference: `docs/onboarding-prototype.html` contains a canvas
> implementation of the §5 layer stack (blob formulas, ring, glyph) with the
> glyph size/centering values below already applied — open it in a browser to
> see the approved motion.

---

## 1. Design principles

1. **The ॐ is the still center; the voice is the energy around it.**
   The glyph itself never jiggles with amplitude. It breathes slowly and
   glows. All voice reactivity lives in the field *around* it. A glyph that
   dances is charming once and irritating by the 40th dictation.
2. **Perceived latency beats real latency.** The overlay appears on
   keydown — before the engine emits anything — in a *warming* state. The
   ~250ms before the first partial is brand time, not dead time.
3. **Ambient, not performative.** Every animation must pass the test:
   *does this still feel good at 4:45pm on the 40th dictation?* No entrance
   fanfare, no sound-per-word, no confetti.
4. **Display-only.** The panel never takes key focus, never accepts clicks
   (`ignoresMouseEvents = true` stays). The paste target must never lose focus.
5. **Fixed dark palette.** The HUD is dark regardless of system appearance —
   it floats over arbitrary content and the emerald identity needs the
   green-black ground. Do not adapt to light mode.

## 2. Palette

| Token | Value | Use |
|---|---|---|
| `omBackground` | `#0A0F0D` @ 92% opacity | pill background |
| `omBorder` | `#34D399` @ 35% | 1pt pill border |
| `omEmerald` | `#34D399` | energy blob 1, accents |
| `omTeal` | `#2DD4BF` | energy blob 2, LISTENING label |
| `omMint` | `#6EE7B7` | energy blob 3, pulse ring, FINALIZING label |
| `omGlyphCore` | `#EAFFF5` | glyph at rest-glow, finalized words |
| `omGlyphPeak` | `#FFFFFF` | glyph at full luminance, finalize flash |
| `omVolatile` | `#6EE7B7` @ 50% | volatile (partial) words |
| `omError` | `#F87171` | nothing-heard / failure state |

Define these once (e.g. `Color+Om.swift` or an asset catalog group). No other
colors in the overlay.

## 3. Anatomy

```
┌──────────────────────────────────────────────────┐
│  ┌──────┐   LISTENING                            │  pill: ~480 × 82 pt
│  │ orb  │   finalized words in mint-white and    │  radius 28, 1pt border
│  │  ॐ  │   the volatile tail dimmed emerald…    │  bg omBackground
│  └──────┘                                        │
└──────────────────────────────────────────────────┘
        bottom-center, 90pt above screen bottom (unchanged)
```

- **Orb zone**: 64×64pt, left-aligned, 8pt inset. Canvas/Metal layer.
- **Status label**: 11pt, 0.08em tracking, uppercase. `LISTENING` (omTeal),
  `…` while warming, `FINALIZING` (omMint), `NOTHING HEARD` (omError).
- **Transcript zone**: 15pt system font, line height ~1.55, bottom-anchored
  window exactly **2 lines tall**, older lines clipped above (see §7).
- Panel frame becomes ~500×100 to fit (update `OverlayPanel.makePanel` and
  keep `position()` math).

### Overlay styles (user setting — decided 2026-07-07)

The overlay is one engine with **three user-selectable presentations**
(`overlayStyle` setting; picker with live previews + auto-demo in the hub's
settings). Reference mockup: `docs/overlay-styles.html`. Decided 2026-07-07:
**Orb is the canonical minimal style**; **Whisper line** ships as a third,
ultra-minimal tier (competitive answer to Wispr Flow's Flow Bar lozenge,
but ours keeps the micro-ॐ brand mark — never a bars-only capsule).

| Style | Form | Shows |
|---|---|---|
| **Full** (default) | the pill below (~500×100pt) | orb + status label + live 2-line transcript |
| **Orb** (minimal) | ~96pt circle | orb only — field reacts to voice, finalize pulse, no text |
| **Whisper line** (ultra-minimal) | ~132×38pt lozenge | micro-ॐ + 5 amplitude bars, nothing else |

Rules that hold across ALL styles (this is what keeps minimal honest):
- Same state machine, same entrance/exit physics, same timings (§4).
- Warming is visible on keydown in every style.
- Finalize pulse still seals the dictation (orb pulse; in Whisper line the
  bars flash mint once).
- **Errors always surface**: minimal styles transiently expand into a small
  capsule showing `NOTHING HEARD` (§9) — silence must never look like
  success, regardless of how minimal the user went.
- Style switching applies from the next dictation; never mid-session.

This supersedes the earlier "idle-listening compact form" idea (orb-only was
phase-2 speculative; it is now simply the **Orb** style).

## 4. State machine

Overlay states extend the existing `DictationState` — do **not** fork a
second source of truth. Add the two terminal flourishes as short-lived,
overlay-local phases driven by `AppState` transitions:

```
                keydown/toggle             first partial
   hidden ────────────────────▶ warming ────────────────▶ listening
     ▲                            │  release <500ms          │ stop
     │                            │  & no transcript         ▼
     │        (no animation)      ▼                      finalizing
     ├────────────────────── cancelled                       │
     │                                                       ├─ text → pasting ─▶ hidden
     └───────────────────────────────────────────────────────┴─ empty → error ──▶ hidden
```

| Overlay state | Backed by | Orb behavior | Label |
|---|---|---|---|
| hidden | `.idle` | — | — |
| warming | `.starting` | glyph stroke-draws in (§5.4), field at 20% energy | `…` |
| listening | `.recording` | full reactive field (§5) | `LISTENING` |
| finalizing | `.finalizing` | field decays to calm; glyph does one bright pulse | `FINALIZING` |
| pasting | overlay-local, ≤300ms | exit animation (§8) | — |
| error | overlay-local, 800ms | field collapses, border + label flash omError | `NOTHING HEARD` |
| cancelled | overlay-local | instant hide, no paste, no history entry | — |

### Timings

| Transition | Duration | Curve |
|---|---|---|
| Entrance (hidden → warming) | 350ms | spring, slight overshoot (`cubic-bezier(.2,.9,.3,1.2)` equivalent) |
| Warming → listening | on first `.partial` event; label crossfade 150ms | ease-out |
| Word entrance (per word) | 180ms opacity fade + 4pt rise | ease-out |
| Volatile → finalized recolor | 400ms | ease |
| Finalize hold (glyph pulse + whiten words) | 420ms | ease |
| Exit (pasting) | 300ms | ease-in, translateY +90pt + fade |
| Error flash | 800ms total, then exit | ease |
| Cancelled | 120ms fade, no translate | linear |

Rule: **paste is never delayed by animation.** `CGEventPost` fires as soon as
the final transcript is ready; the 420ms finalize hold and 300ms exit run
concurrently with (or after) the paste, not before it. The <700ms
stop-to-paste budget is untouched by this spec.

## 5. The orb — layer stack

Three layers, back to front. All amplitude-driven values use the smoothed
signal from §6.

### 5.1 Energy field (3 blobs)

Three overlapping organic shapes, additive blending, one per brand color
(omEmerald, omTeal, omMint). Each blob is a closed curve whose radius is:

```
r(θ, t) = R_base + A·amp·k1 + sin(3θ + t/0.30s + φᵢ)·(w1 + amp·k2)
                            + sin(5θ − t/0.20s + φᵢ)·(w2 + amp·k3)
```

Reference values (from the approved mockup, scaled to a 128px canvas —
halve for pt): `R_base = 27`, `A·k1 = 16`, `w1 = 3, k2 = 8`, `w2 = 2, k3 = 4`,
`φᵢ = i·2.1`. Blob alpha = `0.16 + amp·0.20`.

### 5.2 Pulse ring

A single 1.5pt circle: radius `34 + amp·20 + sin(t/0.6s)·2`, alpha
`0.10 + amp·0.30`, color omMint. Reads as a soft sonar breathing with speech.

### 5.3 The ॐ glyph

- **Source**: a vector ॐ path imported as a `Path`/asset — **not** a font
  glyph (font rendering of U+0950 varies by machine; the logo must be
  pixel-identical everywhere). The committed path lives in `UI/OmGlyph.swift`
  and is the single source of the mark — the HUD, menu bar, app icon
  (`scripts/make-app-icon.swift`) and OG image all render from it, so none of
  them can drift. Regenerate assets by re-running those scripts; never
  hand-edit the produced PNGs.
- **Size**: ~28pt within the 64pt zone (tuned down from the original ~44pt —
  reviewed in the onboarding prototype 2026-07-07; the smaller glyph gives the
  energy field room and reads calmer). Reference: font-size 36 on the spec's
  128px reference canvas.
- **Centering**: center the glyph's **ink bounding box** on the orb center —
  measure the actual rendered bounds (`Path.boundingRect` for the vector
  asset; the prototype uses `measureText` ink metrics) rather than baseline
  math or a hand-tuned constant, then nudge **1.5pt up**. Fixed-offset
  centering drifts across fonts/machines; ink-box centering does not.
- **Breath**: `scale = 1 + 0.02·sin(t/0.9s)` — slow, voice-independent. This
  is what makes the glyph read as *calm*.
- **Luminance**: interpolate omGlyphCore → omGlyphPeak by
  `lum = min(1, glow·0.55 + amp·0.5)` where `glow` is a state-level base
  (warming 0.3, listening 0.6, finalize pulse 1.0) smoothed at ~0.08/frame.
  A subtle dark under-copy (omTeal 900-ish `#04342C` @ 90%, offset 1.5pt)
  keeps the glyph legible when the field behind it is bright.
- **Never** scale, translate, or rotate the glyph with amplitude.

### 5.4 Warming stroke-draw

During `warming`, the glyph draws itself: animate `strokeEnd` 0→1 over
~240ms (ease-out), then crossfade stroke → fill (~80ms). If the first partial
arrives early, jump-complete the draw — never block on the flourish. This
turns engine-setup dead time into the brand signature.

### 5.5 Finalize pulse

On entering `finalizing`: `glow → 1.0` for one pulse (rise 120ms, decay
300ms), ring emits one expanding wave (radius → 60pt, alpha → 0). One pulse
only. This is the visual "om" that seals the dictation.

## 6. Amplitude signal

- **Source**: `AudioCapture.level` (nonisolated, thread-safe RMS 0–1, already
  implemented).
- **Sampling**: read once per frame from the render loop. Use SwiftUI
  `TimelineView(.animation)` + `Canvas`, or a `CADisplayLink`-driven
  `CAMetalLayer` if Canvas can't hold 60fps (§10).
- **Shaping**: raw RMS is too spiky and too quiet. Apply:
  `shaped = min(1, (rms · 6)^0.7)` (gain then soft-knee compress — tune the
  gain constant against a real mic, target: normal speech ≈ 0.5–0.8).
- **Smoothing**: asymmetric one-pole — attack `amp += (target − amp)·0.30`
  when rising, decay `·0.08` when falling (per frame @60fps). Fast onset,
  slow relax; the field should bloom on a word and sigh between words.
- **Floors**: warming 0.20, listening idle-floor 0.12 (never fully dead),
  finalizing decays to 0.12.

## 7. Word flow (transcript zone)

Maps directly onto the existing `finalizedTranscript` / `volatileTranscript`
split in `AppState` — no new transcript model.

- **Finalized text**: omGlyphCore, regular weight.
- **Volatile tail**: omVolatile (50% mint), *not italic* (drop the current
  `.emphasized` — the color split carries the meaning; italic + color is
  double-encoding and jitters as words re-render).
- **Entrance**: only *newly appended* words animate (180ms fade + 4pt rise).
  When volatile text is *replaced* (SpeechTranscriber refining a hypothesis),
  swap in place with a 100ms crossfade — no rise, or the line shimmers
  constantly. Diff by common-prefix: animate only the changed suffix.
- **Volatile → finalized**: when a run moves from volatile to finalized,
  recolor in place over 400ms. The word must not move or re-layout.
- **Two-line window**: the zone is exactly 2 lines, bottom-anchored, older
  content clipped above with an 8pt fade-out gradient mask at the top edge.
  Long dictations scroll naturally; the pill never grows vertically.
- **Empty states**: warming shows nothing (the stroke-draw is the content);
  listening with no words yet shows `Listening…` in omVolatile;
  finalizing with words shows the whiten treatment (§4 timings).

## 8. Exit / paste handoff

The overlay cannot animate *inside* the target app, so the handoff is an
exit gesture that implies delivery:

1. Paste fires (`PasteService`) the moment the final transcript is ready.
2. Simultaneously: all words snap to omGlyphPeak (whiten, 420ms hold already
   running from finalize), then the pill translates down +90pt and fades
   over 300ms — the reverse of its entrance.
3. Optional phase-2 flourish: the transcript block drifts 12pt *toward* the
   frontmost window's center (direction from `PasteService`'s frontmost-app
   frame) during the fade. Cut it instantly under Reduced Motion.

## 9. PTT + edge semantics

- **PTT keydown** (`PushToTalkMonitor`): overlay shows *immediately* on
  keydown in `warming`. Never wait for the engine or first buffer.
- **Short-hold cancel**: key released `< 500ms` after keydown **and** both
  transcripts empty → `cancelled`: hide (120ms), no paste, no history row,
  no sound. Kills phantom pastes from accidental Globe taps.
- **Nothing heard**: stop with both transcripts empty (after a real-length
  session) → `error` state: field collapses, border/label flash omError with
  `NOTHING HEARD`, 800ms, then hide. No paste, no history row. Silence must
  never look like success.
- **Engine failure mid-session**: same error treatment, label `SOMETHING
  BROKE — TEXT COPIED` if any partial text existed (in which case put it on
  the clipboard even though paste may be unsafe).
- **Toggle + PTT interplay**: PTT keydown while a toggle session is
  `.recording` is **ignored** (simplest rule; revisit if users complain).
  Toggle hotkey during a PTT hold stops the PTT session (acts as stop).

## 10. Performance & platform

- **Budget**: < 3% CPU on M-series, zero GPU when hidden. Kill the render
  loop entirely in `hidden` (no `TimelineView` ticking behind an
  `orderOut`'d panel).
- **First try SwiftUI**: `TimelineView(.animation)` + `Canvas` with
  `.blendMode(.plusLighter)` for the additive blobs. This is likely fine for
  3 blobs + ring + one path. Measure with Instruments; only reach for a
  `CAMetalLayer` + shader if Canvas can't hold 60fps under 3%.
- **Panel invariants (do not regress)**: `.nonactivatingPanel`,
  `ignoresMouseEvents = true`, `.canJoinAllSpaces`, `.stationary`,
  `.fullScreenAuxiliary`, floating level, no key focus — all as currently in
  `OverlayPanel.swift`.
- Replace `.ultraThinMaterial` with the fixed omBackground fill (§1.5) —
  material blur samples the desktop and breaks the dark identity over light
  content; it also costs more than a flat fill.

## 11. Accessibility

- **Reduced Motion** (`accessibilityReduceMotion`): blobs and ring become a
  static soft disc whose *opacity* (not shape) tracks `amp`; glyph breath
  off; stroke-draw becomes a fade; entrance/exit are 150ms fades with no
  translation. Word rise-in becomes plain fade.
- **VoiceOver**: the panel is display-only; mark the whole overlay as an
  accessibility element with a live-region-style label ("Dictating: <last
  sentence>") updated at most once per second, or exclude it entirely if
  that fights the paste target's focus — test both, prefer whichever never
  steals VO focus.
- **Contrast**: omVolatile on omBackground is intentionally sub-AA (it's
  transient, decorative-adjacent); finalized text (omGlyphCore) must stay
  ≥ 4.5:1 — it does.

## 12. Implementation map

| Piece | Where | Notes |
|---|---|---|
| Layer-stack orb view | new `UI/OmOrbView.swift` | TimelineView + Canvas; takes `amp`, `glow`, `phase` |
| ॐ vector path | new asset — SVG from the `omWhisperWebApp` repo, or trace once from Devanagari Sangam MN (see §5.3) | convert once to `Path`/SVG asset; do not use a text glyph |
| Palette | new `UI/OmColors.swift` | §2 tokens only |
| Pill layout + states | rewrite `UI/OverlayView.swift` | keep `AppState` as the only source of truth |
| Panel size/pos | `UI/OverlayPanel.swift` | ~500×100; everything else unchanged |
| Overlay-local phases (pasting/error/cancelled) | `AppState` (small `overlayPhase` enum) or view-local | must not add a second dictation state machine |
| Short-hold cancel | `AppState.stopDictation()` + `PushToTalkMonitor` timestamps | needs keydown time |
| Amplitude shaping | `UI/OmOrbView.swift` (view-side) | source stays `AudioCapture.level` |

## 13. Sign-off additions

Add to the M1/M2 sign-off list:

1. Overlay visible **< 50ms** after PTT keydown (warming state).
2. 60fps orb at < 3% CPU during a 60s dictation (Instruments).
3. 3-minute dictation: pill height constant, last 2 lines always visible.
4. Accidental Globe tap (< 500ms, silent) → nothing pasted, no history row.
5. Silent 5s session → `NOTHING HEARD` flash, no paste.
6. Reduced Motion on → no shape animation, all flows still legible.
7. The 40th-dictation test: run it all day; if anyone reaches for a
   "disable overlay animations" setting, the motion is too loud.

## 14. Open questions (decide before phase 2)

- Compact orb-only idle form (§3): ship or skip?
- Exit drift toward target app (§8.3): worth it, or does it read as lag?
- Should the finalize pulse have a matching (very quiet) audio tick, tying
  into the existing start/stop sounds — or is the stop sound already that?
- Smart dictation (M3): violet accent variant of the palette for
  polish-in-progress, or same emerald with a different label?
- Overlay placement setting: bottom-center (default) vs. under-notch
  (FluidVoice ships notch-aware placement — glanceable without leaving your
  text; see `COMPETITOR_FLUIDVOICE.md` §adopt). Orb/Whisper-line styles fit
  the notch area naturally; Full pill likely bottom-only.
