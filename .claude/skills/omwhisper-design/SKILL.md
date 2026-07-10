---
name: omwhisper-design
description: "OmWhisper's design system and brand rules. Use for ANY UI/UX work in this repo: SwiftUI views, the overlay/HUD, onboarding, settings tabs, menu-bar states, app icon, HTML prototypes in docs/, UX copy (permission prompts, errors, empty states), animations, and design reviews. Encodes the emerald/green-black palette, the Om orb motion principles, typography, native-macOS conventions, and the calm-motion philosophy. Triggers: design, UI, UX, view, screen, overlay, HUD, onboarding, settings tab, animation, color, palette, icon, copy, prototype, mockup."
---

# OmWhisper Design System

The design intelligence for OmWhisper — a menu-bar dictation app for macOS whose
brand is **calm, private, and precise**. Everything below is derived from approved,
shipped decisions (see `docs/OVERLAY_SPEC.md`, `docs/onboarding-prototype.html`).
When this skill and generic design guidance (e.g. ui-ux-pro-max) conflict, **this
skill wins** — these are the project's actual rules, not suggestions.

## Brand in one paragraph

OmWhisper is the ॐ — a still center surrounded by living energy. The user's voice
is the energy; the app is the stillness. Privacy is the identity, not a feature
("Your voice never leaves this Mac"). The aesthetic is deep green-black with
emerald light: meditative, not techy; premium, not playful. If a design choice
would feel at home in a meditation app crossed with a pro developer tool, it's
right. If it feels like a SaaS dashboard or a gamified consumer app, it's wrong.

## 1. Color palettes (fixed — do not invent new colors)

The app has **two palettes with a strict split** (decided 2026-07-07, R chose
"Porcelain" for the app after reviewing light/dark alternatives):

- **Porcelain (light)** — ALL app windows: the hub (Home/History/Meetings/
  Vocabulary/AI/Memory), Settings, and the menu-bar panel. Reference
  implementation: `docs/hub-concept.html`.
- **Dark (emerald-on-green-black)** — the overlay HUD (per `OVERLAY_SPEC.md`,
  never light-mode) and the onboarding flow (approved prototype). The dark
  orb is the brand jewel; the light app around it is what keeps it dramatic.

### Porcelain tokens (app windows)

| Token | Value | Use |
|---|---|---|
| `bg` | `#F7FAF8` | window canvas |
| `panel` | `#FFFFFF` | cards, fields |
| `panel2` | `#F0F5F1` | nested surfaces, app-icon wells |
| `ink` | `#0F241B` | primary text (deep forest, not black) |
| `dim` | `#66796F` | secondary text |
| `hair` | `#E3ECE5` | hairline borders |
| `em` | `#0FA97C` | primary accent (deeper emerald for AA on light) |
| `mint` | `#0D9488` | chips, secondary accent |
| `teal` | `#0E7490` | gradient partner |
| numerals | `#0FA97C → #0E7490` gradient @135° | big stats |
| accent tints | `rgba(15,169,124,.07/.13)` | hovers / active nav |
| shadow | `rgba(23,58,44,.16)` green-tinted | card/window depth — never pure black |

Porcelain orb variant: blobs render as watercolor washes (`source-over`, deeper
emeralds `#10B981/#0D9488/#059669`, alpha .10+amp·.14), glyph is deep-emerald
ink — light never uses additive blending (it washes out on white).

### Dark tokens (HUD + onboarding only)

| Token | Value | Use |
|---|---|---|
| `omBackground` | `#0A0F0D` (92% for HUD) | dark ground everywhere custom-branded |
| `omPanel` | `#0E1512` | cards, fields on dark ground |
| `omBorder` | `#34D399 @ 35%` | 1pt borders on branded surfaces |
| `omEmerald` | `#34D399` | primary accent, energy blob 1 |
| `omTeal` | `#2DD4BF` | secondary accent, blob 2, LISTENING label |
| `omMint` | `#6EE7B7` | highlights, blob 3, pulse ring, FINALIZING |
| `omGlyphCore` | `#EAFFF5` | primary text on dark, glyph at rest |
| `omGlyphPeak` | `#FFFFFF` | peak luminance, finalize flash |
| `omVolatile` | `#6EE7B7 @ 50%` | partial/volatile transcript words |
| `omDim` | `#5D7A6E` | secondary text on dark |
| `omError` | `#F87171` | errors only — never decoration |

Gradients: emerald→teal at 135° for primary CTAs and the glyph fill. Smart
dictation (AI polish) may use a violet accent variant — an open question in
OVERLAY_SPEC §14; ask before introducing it.

**Scope rule**: the overlay HUD + onboarding are ALWAYS dark (`om*` tokens) —
never let the HUD adapt to light mode (spec §1.5). App windows (hub, Settings,
History, menu-bar panel) use the **Porcelain** tokens, which as of 2026-07-10
are **adaptive**: light "porcelain" in Light Mode, the brand's dark
emerald-on-green-black identity in Dark Mode (R reversed the original
always-light rule). Build hub UI with `Color.Porcelain.*` and it tracks the
system theme for free — do NOT pin app windows to `.aqua` or hard-code the
light hex. The tokens live in `UI/OmColors.swift`, built on
`porcelainAdaptive(light:dark:)`. The Canvas orb isn't token-driven — pass its
palette explicitly from `@Environment(\.colorScheme)` (`.dark` vs
`.porcelain`). App windows still use native SwiftUI controls — Porcelain is the
color system laid over native structure, not web-style custom chrome.

## 2. Motion philosophy (the part that makes it OmWhisper)

1. **The still center.** The ॐ glyph never jiggles, scales, translates, or
   rotates with voice amplitude. It breathes slowly (`1 + 0.02·sin(t/0.9s)`)
   and glows. ALL voice reactivity lives in the field around it (3 additive
   energy blobs + pulse ring — formulas in OVERLAY_SPEC §5).
2. **The 40th-dictation test.** Every animation must still feel good on the
   40th use of the day. No entrance fanfare, no confetti, no per-word sounds.
   If a reviewer would call it "delightful", check it isn't "loud".
3. **Perceived latency beats real latency.** Show state instantly (overlay on
   keydown, warming stroke-draw during engine setup); never block a function
   on a flourish. Paste is never delayed by animation.
4. **Standard timings** (from the approved spec): entrance 350ms spring with
   slight overshoot; word entrance 180ms fade + 4pt rise; volatile→final
   recolor 400ms in place (no movement); exit 300ms ease-in downward;
   finalize = exactly one bright pulse. Reuse these numbers; don't invent.
5. **Reduced Motion**: shapes become static, opacity carries the signal,
   entrances become 150ms fades. Non-negotiable, spec §11.

## 3. Typography

- **App UI (SwiftUI)**: system font (SF Pro) at native sizes. Status labels:
  11pt, +0.08em tracking, UPPERCASE. Transcript: 15pt, line height ~1.55.
- **Web/prototypes/marketing**: DM Sans (body/UI), DM Mono (code/kbd/stats),
  Instrument Serif (rare, display-only accents) — matches omWhisperWebApp.
- **The ॐ glyph**: ALWAYS the committed vector path, never a live font glyph
  in production (font rendering of U+0950 varies per machine — spec §5.3).
  Size ~28pt in the 64pt orb zone; center the **ink bounding box** on the orb
  center, then nudge 1.5pt up. HTML prototypes may use the font glyph with
  `measureText` ink-box centering.

## 4. Component conventions

- **Overlay HUD**: pill ~500×100pt, radius 28, `omBackground` @92% (flat fill,
  NOT `.ultraThinMaterial`), 1pt `omBorder`. Orb left, status label + 2-line
  bottom-anchored transcript right, top fade mask. Panel invariants:
  non-activating, ignores mouse, joins all spaces — never regress these.
- **Transcript semantics**: volatile text = `omVolatile`, not italic (color
  alone carries meaning — no double-encoding). Finalized = `omGlyphCore`.
  Recolor in place; words must never move when finalizing.
- **Settings**: SwiftUI `TabView` (General/Audio/Vocabulary/AI/About pattern),
  plain native controls, `.pickerStyle(.radioGroup)` for exclusive choices.
  Every new @Observable-backed setting needs `access(keyPath:)`/
  `withMutation(keyPath:)` if it's a computed property over UserDefaults
  (see CLAUDE.md M3 notes — Toggles mask this bug, Pickers expose it).
- **Menu bar**: `NSStatusItem` (not SwiftUI MenuBarExtra — known-broken on
  macOS 26, see memory), template-style ॐ icon, distinct icon states for
  idle/recording/polishing.
- **Buttons (branded surfaces)**: primary = emerald→teal gradient pill, dark
  text `#04120C`; secondary = ghost/underline-dotted in `omDim`. One primary
  action per screen.

## 5. UX copy voice

- Calm, first-person-plural absent; speak plainly to the user. Short sentences.
- Privacy claims are **earned, not shouted**: state the mechanism, not the
  slogan ("Audio is transcribed on this Mac and discarded" > "100% private!").
- Permission asks are **just-in-time with a reason**: ask at first use, one
  sentence on why, never a wall of permissions at onboarding. Denial gets a
  graceful, non-guilting fallback ("That's okay — you can enable it later").
- Errors name what happened and what survives: "NOTHING HEARD" (no fake
  success), "SOMETHING BROKE — TEXT COPIED" (data never silently lost).
- No exclamation marks in system copy. Sanskrit/ॐ references stay visual —
  don't write mystical copy.

## 6. Hard don'ts

- No character/face/avatar imagery (explicitly rejected direction).
- No gamification: streaks, badges, celebration confetti.
- No light-mode HUD; no adapting branded surfaces to system appearance.
- No new colors, no new animation timing values without updating OVERLAY_SPEC.
- No web-styled chrome in native windows; no native-skinned marketing pages.
- Nothing that fails the 40th-dictation test.

## 7. Where the source of truth lives

| Topic | File |
|---|---|
| Orb/HUD full spec (formulas, states, a11y, perf budgets) | `docs/OVERLAY_SPEC.md` |
| Approved motion, live reference implementation | `docs/onboarding-prototype.html` |
| Hub window + Porcelain palette reference | `docs/hub-concept.html` |
| Milestones + engineering conventions | `CLAUDE.md` |
| Onboarding flow structure (4 screens, 1 permission, ~75s) | `docs/onboarding-prototype.html` |
| Generic design data (styles/palettes/fonts search) | `.claude/skills/ui-ux-pro-max/` |

When designing something new: check §6, pick tokens from §1, timings from §2,
copy voice from §5 — then reach for ui-ux-pro-max only for what this file
doesn't cover (layout patterns, chart styles, unfamiliar component types).
