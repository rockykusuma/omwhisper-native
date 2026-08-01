# Landing Page — "More than dictation" Section — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming)
**Repo:** `omWhisperWebApp` (the site), not the app repo. Spec kept here because the app
repo is where the feature knowledge lives and the web repo gitignores `docs/`.

## Problem

`omwhisper.in` is entirely dictation: the hero, all six `BentoFeatures` cards, and the
four-step `HowItWorks`. **Meetings, Memory, Reply Assist, Brain-dump, Cross-lingual, MCP,
AI Polish, Vocabulary and History are invisible** unless a visitor clicks Docs → Beyond.

Someone comparing OmWhisper against Meetily or Littlebird would conclude it has no meetings
feature at all — while the app ships consent-first recording, on-device diarization, speaker
naming, templates, editable notes, export and MCP tools, several of which those products
charge $20–50/month for.

## Decisions

Brainstormed twice on 2026-08-01. The first pass closed before a spec; its decisions stand
except for one amendment made after SP2/SP3 shipped.

1. **Dictation-first positioning stays.** The hero, bento and how-it-works are untouched.
   This is one section, not a re-pitch.
2. **One new section**, between `HowItWorks` and `FAQ`, `id="beyond"`.
3. **Two tiers** — three full cards, six compact rows linking into `/docs/beyond`.
4. **AMENDED — which three get cards.** The first pass chose AI Polish / Vocabulary /
   History. That predated SP2 and SP3. Meetings is now the strongest item here and
   Vocabulary/History are table stakes, so the cards are **Meetings, AI Polish,
   Cross-lingual** and the rows are **Memory, Reply Assist, Brain-dump, Vocabulary,
   History, MCP**.
5. **No screenshots.** `app-screenshot.png` was retired in S6 after advertising a BETA
   badge and a Whisper-only model list for months — an asset that rots silently. Use the
   existing CSS/emoji vocabulary instead.

## Content

The framing line under the header does the real work: **"Every one of these is off until
you turn it on."** It converts a long feature list from "bloated" into "restrained", which
is the truthful story — every one of these ships off by default.

**Cards:**

| | Copy |
|---|---|
| **Meetings** | Records a call after asking you, then transcribes it, separates the speakers and writes the notes — entirely on your Mac, even if you dictate through a cloud engine. |
| **AI Polish** | Removes filler and fixes self-corrections in a style you choose. Runs on-device, or through Ollama, or a provider you configure. |
| **Cross-lingual** | Speak Telugu, Hindi or Hinglish, get polished English. No key, no network. |

**Rows:** Memory (local screen-text search + a daily written chronicle) · Reply Assist
(double-tap right ⌥ to draft from what is on screen) · Brain-dump (⌘⇧D — ramble, get
structure) · Vocabulary (replacement rules and fuzzy correction) · History (searchable,
local, exportable) · MCP (read-only access for Claude Desktop).

## Copy constraints — claims that must not drift

- **Never "teach it your jargon" for Vocabulary.** Engine biasing is *measured* inert on
  Apple Speech and both Parakeet variants (byte-identical transcripts with and without a
  vocabulary list). Only replacement rules and fuzzy correction — post-processing — provably
  work. See [[vocabulary-biasing-does-nothing-on-apple]].
- **Cross-lingual needs no key and no network.** `CrossLingual.engineKind` forces on-device
  Whisper; `crossLingualUsesSarvam` requires enabled AND the toggle AND a saved key.
- **Meetings never egress**, whatever the dictation backend: `transcribeMeeting` hardcodes
  Apple + Whisper, and `meetingSummaryBackends()` only ever appends Ollama and SystemLLM.
- **No invented numbers.** S6 found a fabricated "99.2% accuracy" and a "Voice Analysis"
  panel scoring a visitor's speech — a feature that never existed. Every claim here maps to
  shipped code.

## Implementation

One new component, `src/components/BeyondDictation.tsx`, rendered from `Landing.tsx`
between the how-it-works and faq sections. Follows the conventions already in that repo:
shared `SectionHeader` (eyebrow / heading / subtext), neumorphic surfaces via the existing
`--neo-*` CSS variables, `framer-motion` + `useInView` reveals matching `HowItWorks`, and
emoji icons in rounded tiles as `BentoFeatures` already does. Rows link to `/docs/beyond`
with `react-router-dom`'s `Link`.

No new dependencies, no new design tokens, no changes to existing components.

## Verification

- `npm run build` succeeds.
- The section renders between How It Works and FAQ, and the page still scrolls cleanly at
  mobile width.
- Every row's link resolves to `/docs/beyond` (which is live and, since this morning,
  factually correct).
- Read the rendered page, not just the source — both S6 landmines were invisible in source
  review and obvious on screen.

## Out of scope

Re-pitching the hero; per-feature landing pages; screenshots or video; pricing or
comparison tables; touching BentoFeatures/HowItWorks/FAQ.
