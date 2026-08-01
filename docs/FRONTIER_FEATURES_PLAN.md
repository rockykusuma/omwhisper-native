# Frontier Features Plan — F1–F7

> Decided 2026-07-07 (R approved all seven). Features that change what dictation *is*
> rather than doing the same thing better. These interleave with the M/S/T roadmap
> (see the tracker in `CLAUDE.md`) — they never block the
> committed spine (M2 → S2 → M3 → S3 → S4 → S1 → S5 → M4), and none are needed for
> the 2.0 release (M5). They ship as post-2.0 waves.
>
> Shared rules: local-first (cloud only where the user already opted in via M3/M4
> backends), off-by-default for anything with a new permission or audio behavior,
> and every feature must pass the overlay's "40th-dictation test" — no novelty that
> annoys by Friday.

---

## The seven

### F1 — Voice editing ("the app you never have to touch")
**What**: a spoken edit grammar after (or during) dictation: "scratch that",
"make the last sentence shorter", "swap the greeting for something warmer",
"turn this into bullets", "send it". Overlay shows the edit as a dim→solid diff.
**Why it wins**: every competitor is append-only; the moment you must grab the
keyboard to fix one word, the promise dies. Closing the edit loop is the single
strongest differentiator on this list.
**How**:
- New `EditSession` state after `finalizing`: transcript held in the overlay
  (not yet pasted), mic stays open in *command* mode.
- Command detection: small intent classifier via `PolishBackend` (SystemLLM) —
  prompt returns either `{edit, newText}` or `{command: paste|discard|append}`.
  Ambiguity rule: if it doesn't parse as a command with high confidence, it's
  dictation — append it. Never eat the user's words.
- Diff render: reuse the volatile→finalized recolor mechanics; changed spans
  animate dim→solid, removed spans collapse.
- Escape hatches: "paste it" / hotkey tap ends the session; configurable
  auto-paste-after-N-seconds keeps the zero-edit fast path exactly as fast as today.
**Depends on**: M3 (polish backends), overlay spec state machine (extend §4).
**Exit**: 10 common edit intents ≥95% correctly classified on SystemLLM; zero-edit
dictations pay no added latency; "scratch that" round-trip < 1.5s.
**Risk**: intent misfires eating dictated text → mitigated by the ambiguity rule +
visible diff before paste.

### F2 — Whisper mode (the name is destiny)
**What**: dictation that works when you *whisper* — open offices, cafés, late-night
couch, beside a sleeping baby.
**Why it wins**: embarrassment is the #1 reason people don't use any dictation app
in public. Nobody addresses it. An app called OmWhisper that works whispered is
both a real unlock and marketing gold.
**How** (research → ship, in stages):
1. **Measure**: build a whispered-speech test set (self-recorded + volunteers);
   benchmark WER of AppleEngine vs Parakeet vs Whisper-family on it. Whispered
   speech is unvoiced — no pitch, shifted spectral balance — expect engines to
   degrade differently.
2. **Cheap wins**: input gain boost + compressor tuned for whisper amplitude;
   VAD/level thresholds profile ("Whisper mode" toggle or auto-detect via
   spectral voicing ratio); engine biasing unchanged.
3. **If needed**: route whisper-mode audio to whichever engine benchmarks best
   whispered (engine choice per mode is free with our `TranscriptionEngine`
   protocol); investigate a lightweight whisper-to-voiced preprocessing pass.
4. **UX**: auto-detect whispering and switch profiles silently; overlay shows a
   small 🤫 state so the user knows why it still works. Optional quieter start/stop
   sounds in whisper mode (it's a *quiet* context by definition).
**Depends on**: M1 pipeline (done); M4 helps (engine choice per mode).
**Exit**: whispered WER within 1.5× of normal-voice WER on the test set; auto-detect
flips modes without user action.
**Risk**: highest research uncertainty of the seven — timebox stage 1 before
committing; stage 2 alone may be shippable as "quiet mode".

### F3 — Only-my-voice (speaker-filtered dictation)
**What**: transcribe *you*; ignore the TV, kids, the colleague talking behind you.
One-time voice enrollment ("read this sentence") during onboarding or Settings.
**Why it wins**: background-speech bleed is a top real-world failure for every
dictation app; none of the mainstream competitors do on-device speaker ID.
Also pairs perfectly with S3 meetings (label *who said what* in transcripts).
**How**:
- FluidAudio (already the planned M4 Parakeet dependency) ships CoreML speaker
  diarization/embedding models — one dependency, two features.
- Enrollment: capture ~15s, store the speaker embedding locally (Keychain-adjacent,
  deletable in Settings).
- Runtime: score frames/segments against the enrolled embedding; below-threshold
  segments are dropped *before* they reach the engine (VAD-style gate), so foreign
  speech never even becomes text.
- Meetings bonus (S3 tie-in): the same embeddings give "Me:" vs "Them:" speaker
  labels in meeting transcripts for free.
**Depends on**: M4 (FluidAudio dependency lands), S3 for the diarization bonus.
**Exit**: TV-playing-in-background test produces zero foreign words in output;
enrollment < 30s; toggle off restores exact current behavior.
**Risk**: threshold tuning (rejecting the *user* is worse than letting noise in) —
default lenient, expose a sensitivity slider under Advanced.

### F4 — Speak your language, write in English (cross-lingual dictation)
**What**: dictate in Telugu, Hindi, Hinglish, Tagalog, Spanish — including
mid-sentence code-switching — and polished English comes out (or any source→target
pair; English-out is the hero case).
**Why it wins**: millions think in their mother tongue but write work content in
English; US-centric competitors ignore them entirely. Deeply on-brand for ॐ.
**How**:
- Two lanes, picked by what benchmarks better per language:
  (a) *transcribe-then-translate*: native-locale SpeechTranscriber → `PolishBackend`
  translation-polish pass (the styles system already has a Translate style to
  generalize); (b) *direct*: Whisper-family/cloud engines that translate in-engine
  (M4's engine flexibility pays off here).
- Code-switching: benchmark which lane survives Hinglish; likely (a) with a
  multilingual-tolerant locale + an LLM instructed to normalize mixed input.
- UX: per-language input profile ("I speak: …") set once; output language follows
  the app/document or a fixed choice. Overlay shows source partials live, final
  paste is the translated text — you *see* it heard you correctly in your language.
**Depends on**: M3 (polish backends); M4 widens engine options.
**Exit**: Hinglish → clean English on 20 real-world samples judged usable without
edits ≥80%; latency ≤ dictation + one polish pass.
**Risk**: translation quality on small local models — allow this feature to
recommend the cloud lane (with the M3 key + redaction machinery) honestly.

### F5 — Brain-dump mode (ramble → structure)
**What**: talk messily for five minutes; out comes the email / ticket / outline /
todo list / journal entry. Target shape chosen up front or inferred from the
frontmost app.
**Why it wins**: Superwhisper's "modes" are static prompts; ours are grounded in
screen context (S2) and later memory (S1) — the structured output uses the right
names, tickets, and references automatically.
**How**: mostly prompt engineering on `PolishBackend` + a long-form capture UX:
- New dictation mode (menu item + optional hotkey) with a relaxed overlay (word
  count + elapsed, not 2-line transcript — you're not supposed to watch it).
- Shape templates: email, ticket (summary/steps/expected), outline, todo list,
  meeting agenda, journal. User-editable, same CRUD as polish styles.
- Context: S2's salient terms + frontmost app feed the structuring prompt.
**Depends on**: M3; S2 makes it sing.
**Exit**: 5-minute ramble → usable ticket/email without edits in ≥ 7/10 attempts.
**Risk**: low — this is the cheapest of the seven.

### F6 — Per-app output shaping + voice snippets
**What**: structure-aware output per app — Jira gets ticket format, Slack gets
short casual threads, Xcode gets a doc comment, Mail gets salutation/sign-off,
Terminal gets intent→shell-command **shown for confirmation, never auto-run**.
Plus voice snippets: "insert my calendly link", "sign off formally" → user-defined
expansions.
**Why it wins**: competitors do tone-per-app; structure-per-app + snippets makes
dictation feel native to each destination instead of generic text sprayed anywhere.
**How**:
- Frontmost app bundle ID (already captured by `PasteService`) keys a per-app
  profile: polish style + structure template + snippet set. Sensible defaults
  shipped for ~15 common apps; everything user-overridable in Settings.
- Snippets: literal expansions run engine-side as post-processing (like word
  replacements — no LLM needed); smart snippets ("sign off formally") go through
  the polish pass.
- Terminal command mode: gated behind an explicit per-app opt-in, output lands
  in the overlay with an [Insert] confirmation — `CGEventPost` types it only on
  confirm, and **never** appends a newline. Safety rule is absolute.
**Depends on**: M3 (styles); pairs with F5 templates (same template system).
**Exit**: dictating the same sentence into Slack/Mail/Jira produces three visibly
correctly-shaped results with zero configuration.
**Risk**: over-eager shaping annoying users → per-app toggle, and raw-mode hold
(e.g., hold ⌥ while stopping = paste verbatim).

### F7 — Vocab packs (shareable vocabulary bundles)
**What**: import/export vocabulary + replacements as a signed JSON pack; shipped
starter packs (medicine, law, Swift/iOS dev, finance); a community repo for
user-contributed packs; team packs exported from a teammate's app.
**Why it wins**: turns the vocabulary system into a network effect and gives the
open-source story a community moat. Nobody else has an ecosystem angle.
**How**:
- Pack format: versioned JSON `{name, description, language, terms[], replacements[]}`;
  merge-not-replace on import, per-pack enable/disable and uninstall.
- Distribution: start with a `omwhisper-vocab-packs` GitHub repo + in-app "browse
  packs" (static index.json fetch — the app's only network call besides updates,
  and only on user action); drag-and-drop `.omvocab` import works fully offline.
- Engine side: packs feed the same `vocabulary` parameter S2/M1 already use —
  zero engine work. Cap total biasing terms (engines degrade with huge hint lists);
  prioritize user terms > pack terms.
**Depends on**: vocabulary system (shipped). Could land any time; no LLM needed.
**Exit**: export → import round-trip lossless; a dev pack measurably improves
WER on a jargon-heavy test script.
**Risk**: minimal — scope creep into a "marketplace" is the only trap; a GitHub
repo is enough for v1.

## Sequencing — post-2.0 waves

The committed spine is unchanged: **M2 → S2 → M3 → S3 → S4 → S1 → S5 → M4**, with
M5 (2.0 release) after whichever point is stable. F-features ship as minor-version
waves after M3 exists, ordered value ÷ effort:

| Wave | Features | Gate | Theme |
|---|---|---|---|
| **2.1** | F5 brain-dump · F6 app shaping + snippets · F7 vocab packs | after M3 | cheap wins, mostly prompts + plumbing |
| **2.2** | F1 voice editing · F4 cross-lingual | after 2.1 | the "never touch the keyboard" + "speak your language" headliners |
| **2.3** | F3 only-my-voice · F2 whisper mode | after M4 (FluidAudio) | "dictate anywhere" — together they own public/noisy spaces |

- F2's stage-1 benchmark (whispered WER) is a **parallel research spike** — run it
  early (any time after M2) so 2.3 isn't a surprise; ship "quiet mode" (stage 2)
  in 2.2 if the numbers say the full feature is far away.
- F7 has no dependencies at all — it's a good "palate cleanser" task between
  heavier milestones whenever one is needed.
- Website (S6) grows a section per wave; 2.3's "dictate anywhere, even whispering,
  even in a crowd" is the anchor of the eventual marketing story.

## What we deliberately did NOT add

Full hands-free computer control (a different product), voice-print login
(security theater we can't back), always-listening wake word (violates the
no-silent-behavior principle), and gamification/streaks (fights the calm brand).
