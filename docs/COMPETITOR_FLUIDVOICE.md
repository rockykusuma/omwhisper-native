# Competitor Analysis — FluidVoice (Altic)

> Researched 2026-07-08 from altic.dev/fluid + github.com/altic-dev/FluidVoice.
> **This is OmWhisper's closest competitor — near-identical positioning.**

## What it is

Free, open-source (GPLv3) Mac dictation app by the Altic team (multi-product
company: Glu, FluidWrite, MCP, Pilot). "Free forever, no tiers."

| Fact | Value |
|---|---|
| Traction | **50,000+ downloads · 6.7k GitHub stars · 417 forks** |
| Velocity | 802 commits, **36 releases, latest (v1.6.2) 2026-07-06** — ships constantly |
| Platform | macOS 15+ (Sequoia), **Apple Silicon AND Intel**; iOS + Windows on waitlist |
| License | GPLv3 (switched from Apache 2.0 on 2026-02-23 — anti-closed-fork move) |
| Telemetry | Optional anonymous analytics (no audio/text collected) |

## Feature set vs. our roadmap

**They already ship things we have planned:**

| FluidVoice | Our equivalent | Status gap |
|---|---|---|
| Engine lineup: Nemotron Speech 3.5 (~40 langs), Parakeet Flash/TDT v3/v2, Cohere Transcribe, Apple Speech, Whisper tiny→large — via **FluidAudio SDK (our exact M4 dependency)** | M4 multi-engine | They shipped it, more engines |
| **Fluid-1**: custom-trained local polish model (~3.5GB, optional) — formatting, casing, dates/names/numbers, tone | M3 SystemLLM (Foundation Models) | Theirs is purpose-trained for dictation cleanup; ours is zero-download |
| **Per-app adaptive tone** (custom prompts per app, auto app detection: Slack casual, Mail formal, GitHub structured) | **F6 — no longer a differentiator** | They shipped our 2.1 headline |
| Write Mode / Command Mode / Direct Dictation | F5/F6 modes | Partially shipped there |
| Cloud post-processing (OpenAI, Groq, custom) | M3 sub-project 2 | Shipped there |
| 40+ languages (model-dependent) | F4 (partially) | Transcription yes; cross-lingual *output* (speak Telugu → English) unclear/absent |
| Claims: <100ms perceived latency, up to 3,380× RTF, multi-hour sessions | M1 sign-off numbers | Comparable class |

**What they do NOT have (our defensible axis):**

- **Screen-context dictation (S2)** — ours is SHIPPED. Nothing like it there.
- **Meeting intelligence (S3)** — consent-first recording + local summaries.
- **Voice reply assist (S4)**, **local memory (S1/S5)**, **digital twin (T1–T4)**
  — the entire Smriti direction is absent.
- **Voice editing (F1)**, **whisper mode (F2)**, **only-my-voice (F3)**.
- **Zero telemetry** (they have optional analytics — small but real wedge).
- **Design**: their aesthetic is dev-tool utilitarian; our Porcelain/orb
  direction aims at a different (award/consumer) register.
- **macOS 26 advantages**: Foundation Models polish with no 3.5GB download;
  SpeechTranscriber streaming partials.

**Their structural advantages over us:**

- Massive head start in distribution (50k downloads, community, SEO for
  "wispr flow alternative", "open source dictation mac").
- Much larger addressable base: macOS 15+ AND Intel vs. our macOS 26 + Apple
  Silicon only.
- A trained model (Fluid-1) as a moat investment we can't match solo.
- A team shipping weekly vs. a solo project.

## Strategic implications (recommendations)

1. **Stop competing on raw dictation.** Engine count, speed, languages —
   table stakes now, and they'll always ship more of it faster. M4 stays
   (user choice matters) but it is parity work, not differentiation.
2. **The moat is the Smriti line.** "Dictation that knows your screen, your
   meetings, and you" — S2 (already shipped!) → S3 → S4 → memory/twin. None
   of it exists in FluidVoice, and it's hard for a general team to follow
   (privacy posture + product focus required). Consider pulling S3 earlier
   if M3-sub2 can slip.
3. **Reposition the website (S6).** "Free local dictation for Mac" is a lost
   SEO/positioning battle — they own it with 50k downloads. Lead with what's
   ours: *"The dictation app with memory"* / context-aware / meetings. Free +
   local becomes the trust floor, not the headline.
4. **F6 demoted.** Per-app tone ships for parity but is no longer a 2.1
   headline; F1 (voice editing) and F2/F3 (whisper mode / only-my-voice)
   remain genuinely unshipped anywhere — they move up as the marketable
   frontier features.
5. **License decision now has a data point**: they moved Apache → GPLv3 to
   prevent closed forks. Same consideration applies to us (LAUNCH_READINESS §7).
6. **Zero-telemetry wedge**: we can honestly say "no analytics, none" — they
   can't. Small, but on-brand and checkable.
7. **Watch, don't chase**: track their releases (they ship weekly); revisit
   this doc when they announce Windows/iOS or context features. If they ship
   screen-context dictation, our window narrows — S2 marketing should not
   wait for 2.0 polish.

## What to adopt from them (researched from their README, 2026-07-08)

Concrete, non-strategic takeaways — each with where it attaches:

1. **Beta update channel** [M2 Sparkle wiring]: they ship `Settings →
   Automatic Updates → Beta Releases`. Sparkle supports channels natively —
   wire ours the same way; it IS the M5 beta-soak distribution mechanism.
2. **Homebrew cask** [M5]: `brew install --cask fluidvoice` — table stakes
   for dev-audience distribution. Publish `omwhisper` cask at launch;
   the Tauri app never had one.
3. **Notch-aware overlay placement** [OVERLAY_SPEC §14 open question]: their
   overlay can sit around the MacBook notch. Worth offering placement as a
   setting (bottom-center default · under-notch option) — the notch position
   is glanceable without looking away from your text.
4. **Model catalog UX** [M4]: their engine table shows *best-for / languages /
   download size / hardware* per model. Steal this format for our engine
   picker and website — honest sizes ("~500 MB") build trust and set
   expectations before download.
5. **Voice actions via Shortcuts** [fold into F6]: their Command Mode launches
   apps/runs system actions. Our safer take: route voice commands through
   **user-created macOS Shortcuts** (an allowlist by construction) instead of
   arbitrary control — keeps F6's never-auto-run rule while matching the
   capability.
6. **Optional audio history with budget + ZIP export** [S3/history backlog]:
   they keep dictation audio locally, opt-in, with size budgets. Useful for
   accuracy debugging and (later) T3 auto-vocab training signal. Opt-in,
   default off, budget-capped — fits our privacy posture.
7. **Language-first onboarding step** [onboarding port, conditioned]: their
   onboarding leads with language + engine choice. Ours assumes English; add
   a language step when system locale isn't English (also pre-work for F4).
8. **"Everything is optional" framing** [S6 website copy]: they state it as a
   feature bullet. We live it (all Smriti features off by default) — say it
   explicitly the way they do.
9. **Community mechanics** [M5 launch]: GitHub Sponsors button, "please star"
   README CTA, star-history chart, testimonial wall harvested from GitHub
   discussions, platform waitlist page. Zero-cost launch playbook.
10. **Open-core honesty** [LAUNCH_READINESS §7 DECIDE input]: their app is
    GPLv3 but Fluid-1 (the model) is private — stated plainly: *"keeping it
    private so we can sustainably offer the core for free."* A viable
    sustainability template if we ever need one; also their Apache→GPLv3
    switch is the anti-closed-fork precedent.

Explicitly NOT adopting: Intel/macOS 15 support (contradicts our macOS 26
bet), optional analytics (contradicts zero-telemetry stance), their
utilitarian visual style (Porcelain is our register).

## Sources

- https://altic.dev/fluid (product page, FAQ, testimonials)
- https://github.com/altic-dev/FluidVoice (stars/forks/releases, README)
