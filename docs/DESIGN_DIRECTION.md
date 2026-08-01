# Design Direction — the Hub Window & Porcelain

> The implementation plan behind `docs/hub-concept.html` (approved mockup,
> 2026-07-07). Written 2026-07-08 against the codebase as it stands after
> M2-mostly/M3-sub1/S1–S5/M4 — i.e., this plans the *migration* of real,
> shipped windows into the hub, not a greenfield build.
>
> Companions: `.claude/skills/omwhisper-design/SKILL.md` (tokens + rules),
> `OVERLAY_SPEC.md` (HUD — unaffected, stays dark), onboarding prototype
> (separate flow, stays dark).

---

## 1. What was decided

- **One hub window** replaces the current window sprawl. Today the app has:
  `SettingsView` (a 9-tab, 660pt `Settings` scene: General / Vocabulary /
  Audio / About / AI / Meetings / Memory / MCP / Transcription), a
  `Window("History")` scene (`HistoryView`), and a `Window("Memory")` scene
  (`MemoryView` + `MemoryChroniclesView`). Nine tabs already overflowed once
  (the MCP-tab ">>" bug) — the tab bar has hit its ceiling.
- **Porcelain palette** for the hub (R rejected dark app windows; tokens in
  the design skill). HUD + onboarding stay dark.
- **Menu-bar mini-panel** (state surface: orb, Start/Stop, active style,
  last transcription) replaces the plain `MenuContent` dropdown.
- The orb is the recurring motif: sidebar brand mark, empty states, loading.

## 2. Hub information architecture

```
┌ Sidebar (glass) ─┐ ┌ Content (Porcelain canvas) ──────────────┐
│ ॐ OmWhisper      │ │                                          │
│ ● Home           │ │  Home       — dashboard (new)            │
│ ● History        │ │  History    — migrate HistoryView        │
│ ● Meetings       │ │  Meetings   — migrate MeetingsSettings + │
│ ● Vocabulary     │ │               future S3-sub2 browse UI   │
│ ● AI Polish      │ │  Vocabulary — migrate VocabularySettings │
│ ● Memory         │ │  AI Polish  — migrate AISettingsView     │
│                  │ │  Memory     — migrate MemoryView +       │
│ ⚙ Settings       │ │               Chronicles + MemorySettings│
│ 🔒 privacy line  │ │  Settings   — General/Audio/Transcription│
└──────────────────┘ │               /MCP/About (true settings) │
                     └──────────────────────────────────────────┘
```

Sorting rule: **content sections get sidebar slots; configuration collapses
under one Settings item.** Today's 9 settings tabs split accordingly —
Vocabulary/AI/Meetings/Memory are *features* (sidebar), General/Audio/
Transcription/MCP/About are *configuration* (Settings section, sub-tabs or
grouped list). This also fixes the tab-overflow ceiling permanently.

## 3. New surfaces (not migrations)

- **Home dashboard**: greeting + streak sentence; three stat cards (words
  today, time saved vs 45wpm, speaking pace) with count-up numerals in the
  emerald→teal gradient; 7-day breathing bar line (NOT a gamified streak —
  no badges, it's a quiet reflection); last 3 dictations as rows with
  destination-app icon, hover → Copy / Re-polish. Data: `HistoryStore`
  already has everything (fetchPage + storageInfo); add a small
  `statsSummary(day:)` query (words/duration per day).
- **Menu-bar mini-panel**: `NSPopover` (or borderless panel) from the status
  item: 270pt card — mini orb canvas, Ready/Listening state line, primary
  Start/Stop button, active polish style chip (click = cycle, right-click =
  menu), last transcription (2-line clamp + copy), Open OmWhisper row.
  Menu-bar icon states (idle/recording/polishing) already exist and stay.
- **Empty states**: every section renders the orb (calm, small) + one
  sentence + one action, per the copy voice rules. Meetings/Memory sections
  double as feature marketing when the feature toggle is off ("consent-first,
  always local — Enable in Settings").

## 4. Porcelain in SwiftUI (component mapping)

| Mockup element | SwiftUI implementation |
|---|---|
| Tokens | `UI/OmColors.swift` gains a `Porcelain` namespace (bg `#F7FAF8`, panel `#FFFFFF`, ink `#0F241B`, dim `#66796F`, hair `#E3ECE5`, em `#0FA97C`, teal `#0E7490`) alongside the existing dark HUD tokens. Fixed values, NOT adaptive — the hub does not follow system dark mode (design-skill rule). |
| Window + sidebar | `NavigationSplitView` in a new `Window("OmWhisper", id: "hub")` scene; sidebar uses `.background(.ultraThinMaterial)` over an emerald-tinted underlay (the "aurora"), content column uses flat Porcelain bg. |
| Cards | `RoundedRectangle(cornerRadius: 14–16)` fill panel-white, 1pt hair stroke, shadow `rgba(23,58,44,…)` — one `omCard()` ViewModifier, used everywhere. |
| Gradient numerals | `Text` + `.foregroundStyle(LinearGradient(em → teal))`; count-up via `TimelineView` or `contentTransition(.numericText)`. |
| Sidebar orb / empty-state orb | reuse `OmOrbView` (when built per OVERLAY_SPEC §12) with the **Porcelain orb variant**: `source-over` watercolor blobs, deep-emerald ink glyph — parameterize the existing layer stack by palette, do not fork the view. |
| Nav rows | custom `List` row style: 9pt radius, accent-tint fill when selected, 2.5pt gradient bar leading. |
| Hover actions on rows | `.onHover` + trailing HStack opacity swap (matches mockup's reveal pattern). |
| Mini-panel | SwiftUI view hosted in `NSPopover` from the existing `NSStatusItem`; orb canvas at 40pt. |

Migration principle from CLAUDE.md still applies: views being migrated
(`HistoryView`, `MemoryView`, settings tabs) keep their logic/store wiring
untouched — this is a re-skin + re-home, not a rewrite. `@Observable`
gotcha: any *new* UserDefaults-backed setting introduced for the hub needs
`access(keyPath:)`/`withMutation(keyPath:)` (see M3 notes).

## 5. Implementation phases

| Phase | Scope | Exit |
|---|---|---|
| **D1 — Foundations** | `Porcelain` tokens in OmColors; `omCard`/nav-row/section-header components; `OmOrbView` gets the palette parameter | a component gallery debug window renders all pieces |
| **D2 — Hub shell + migrations** | hub `Window` scene + `NavigationSplitView`; move History, Memory(+Chronicles), Vocabulary, AI, Meetings sections in; Settings section absorbs General/Audio/Transcription/MCP/About; old `Settings`/`Window` scenes removed; menu items updated ("Settings…"/"History…"/"Memory…" → "Open OmWhisper") | every existing function reachable in the hub; old windows gone; full test suite green |
| **D3 — Home + mini-panel** | Home dashboard (+`statsSummary` query); NSPopover mini-panel replacing the dropdown menu content (menu stays as right-click fallback) | Home live with real data; panel start/stop round-trip works |
| **D4 — Polish pass** | motion (one spring family), keyboard navigation, VoiceOver labels, Dynamic Type check, `--dim`-on-white contrast verification (§ a11y in LAUNCH_READINESS) | a11y checklist passes; 40th-dictation test on hover/transition motion |

Sequencing vs. roadmap: D1–D2 are the natural next block after the current
M-work (they unblock S3-sub2's Meetings browse UI landing directly in the
hub); D3–D4 can ride alongside M3-sub2. The onboarding port (dark, separate
flow) is independent and can precede or follow.

## 6. Out of scope here

The overlay HUD (own spec), onboarding flow (own prototype; port plan lives
with M2 work), website (S6 — will borrow Porcelain but is its own project),
app icon refresh (tracked in LAUNCH_READINESS/M5 polish).
