# Per-feature AI backend, including cloud — design

**Date:** 2026-08-16
**Status:** approved in principle (R, 2026-08-16)

## The problem, measured

Summarising a meeting takes minutes and pins the machine. Measured on the real store:

| | |
|---|---|
| Longest transcript | 50,967 chars (59 min) |
| Median transcript | 27,211 chars |
| Chunks at `ollamaChunkLimit = 12_000` | 5, plus collapse rounds and a reduce ≈ **7–8 sequential calls** |
| qwen3.5 per call on this 16 GB M2 Pro | 5s warm, 20s semi-warm, **36s cold** |

So an hour-long meeting is **3–4 minutes of local inference at full tilt**. That matches the
complaint exactly.

**50,967 characters is only ~13,000 tokens.** Every current cloud model accepts 128k+ in a
single call. So cloud does not merely run the same work faster — it **removes the map-reduce
entirely**, replacing 7–8 sequential passes with one. That also improves the summary, because
today every chunk boundary loses cross-references and the collapse rounds compress
already-compressed text.

Cost is not a deciding factor and should not be treated as one: ~13k in / ~500 out is **under
2¢ per meeting** at premium rates.

## This reverses a decision made twice, deliberately

`LongFormBackends.Kind` has no `.cloud` case, and `LongFormBackendsTests` asserts
`Kind.allCases == [.ollama, .system]` specifically so that adding one turns the suite red. A
per-feature backend picker was also proposed and **rejected on the merits on 2026-08-01**: the
polish backend already expressed that choice, and a second control meant either a hidden global
change or a second concept — "and then Meetings/Brain-dump/Reply Assist each want one."

**Both objections were about *which model*** — a quality question, where one good answer serves
everything. Cloud introduces a different axis: **does this data leave the Mac?** That genuinely
differs per feature. Chronicles are built from a whole day of window titles and screen text; a
meeting is one call with other people in it; a dictation is one sentence the user just spoke.
Those are not the same decision, and no single control can express them.

So the reversal is justified on an axis that did not exist when the original decision was made.
The old objection still holds for its own subject and is not being waved away.

## Granularity: egress follows the data, not the button

Every call site that selects a backend today:

| Feature | Functions |
|---|---|
| **Dictation polish** | `polishedText(for:)` — dictation stop-paste, Smart Dictation, Polish Selected |
| **Reply Assist** | `draftAndStream` |
| **Meetings** | `generateMeetingSummary`, `nameMeetingIfNeeded`, `regenerateSummary`, `askAboutMeeting`, `draftFollowUp` |
| **Chronicles** | `generateChronicle` |
| **Brain-dump** | `brainDumpStructured` |

**Five rows, not eight.** All five meeting functions touch the same recording, so splitting them
would let a user send a summary to the cloud but not a question about it — incoherent, because
the summary already went. Granularity follows the data that egresses, not the button pressed.

## The interface

One `Default`, plus per-feature overrides, in the existing AI Polish section. Backends are
**configured once** and features merely **select** — otherwise each feature would carry its own
URL, model and API-key fields.

```
BACKENDS
  Apple Intelligence      Available
  Ollama                  localhost:11434   [Test]   qwen3.5, gemma4, llama3.2
  Cloud                   api.openai.com    [Test]   gpt-4o-mini · key saved

WHICH BACKEND EACH FEATURE USES
  Default              [ Ollama · qwen3.5        ▾ ]

  Dictation polish     [ Default                 ▾ ]
  Reply Assist         [ Default                 ▾ ]
  Meeting summaries    [ Cloud · gpt-4o-mini     ▾ ]
  Chronicles           [ Default                 ▾ ]
  Brain-dump           [ Default                 ▾ ]

  Meeting summaries are sent to api.openai.com. Everything else stays on this Mac.
```

Every menu groups its options by where the data goes, not by vendor:

```
On this Mac              Leaves this Mac
  Apple Intelligence       Cloud · gpt-4o-mini
  Ollama · qwen3.5
  Ollama · gemma4
```

Three properties this buys, each load-bearing:

- **A `Default` row keeps today's behaviour free.** Rows read "Default" until deliberately
  overridden, so a user who does not care sets one thing and never opens this again. The
  flexibility costs nothing to anyone who does not want it.
- **The control carries the privacy signal**, per the design system's rule to state the
  mechanism rather than shout the slogan. Cloud cannot be selected without reading which side of
  the line it sits on, and no warning banner is needed.
- **It scales.** A new feature is one row, not a new picker — which was the substance of the
  2026-08-01 objection.

One factual sentence sits below, naming the actual host. Not a banner, not repeated per row.

**Rejected — settings inside each feature's own section.** Discoverable in context, but "what
leaves my Mac?" would then require touring five screens, and making that question answerable is
the point of the change.

**Rejected — a feature × backend matrix.** Scannable until Ollama has four models, and it fights
the native settings idiom the design system asks for.

## Rules that are not negotiable

**Cloud is never the shipped `Default`.** Flexibility to choose it, yes. A default that quietly
sends a day's work off-device, no. `Default` ships as today's behaviour.

**Fallback never crosses the line.** If a feature's chosen backend is unavailable — Ollama down,
Apple Intelligence unsupported for the Mac's language — it falls back to the *other on-device*
option and then fails honestly. **It must never silently reach for cloud because a local backend
did not answer.** This is the single most dangerous bug the feature could grow: it would look
like a working fallback and be a privacy breach. It gets a dedicated test.

**The chunk limit follows the chosen backend, per feature.** This is where the reported problem
actually gets fixed. A cloud-backed summary must take the whole 50,967-character transcript in
one call, not 5 chunks plus collapse rounds. Shipping per-feature cloud without raising that
limit would deliver the egress and only a fraction of the speed-up.

## The test that must be rewritten, not deleted

```swift
@Test("cloud can never be a long-form candidate")
func noCloudCase() {
    #expect(LongFormBackends.Kind.allCases == [.ollama, .system])
}
```

This exists to stop exactly this change being made carelessly. It is replaced deliberately, by a
test asserting the **new** guarantee: cloud appears as a candidate **only** for features the user
has explicitly set to cloud, and **never** as a fallback for a failing on-device backend.
Deleting it and moving on would throw away the guard rather than update it.

## What this does not do

- **No new provider integration.** `CloudLLM` already speaks OpenAI-compatible
  `/chat/completions` with a Keychain key and runs `Redactor` before egress. OpenAI, Groq,
  Together, Fireworks, DeepInfra, OpenRouter, Mistral and DeepSeek are drop-in; Anthropic and
  Google publish compatible endpoints. This lifts a restriction, it does not build a client.
- **No change to transcription.** Meeting audio is still transcribed on-device. Only the
  *text* can egress, and only where selected.
- **No change to redaction.** `Redactor` continues to scrub secrets and PII before any cloud
  call, as it does for cloud dictation polish today.
- **No ZDR claims.** OpenAI, Anthropic and Google all default to ~30-day retention for abuse
  monitoring and do not train on API data; zero-retention is enterprise-gated at all three. The
  UI must not imply otherwise. **Google's free tier does train on inputs** — if Gemini is ever
  offered by name, that has to be said.

## Testing

- The `default` sentinel resolves to the `Default` row's value, and changing `Default` moves
  every non-overridden feature — the property that keeps the common case simple.
- An overridden feature ignores `Default` entirely.
- **Fallback stays on-device**: a feature set to Ollama, with Ollama unavailable, produces the
  on-device candidate list and **never** a cloud candidate. This is the test the whole design
  rests on; it must fail if someone appends cloud to the fallback chain.
- A feature set to cloud produces exactly one cloud candidate, and its chunk limit is the cloud
  limit rather than Ollama's — a limit accepted and ignored would pass a "did it summarise?"
  check while leaving the performance problem in place.
- `Kind.allCases` no longer pins the old guarantee; the replacement test pins the new one.

Not unit-testable, owed live: a real meeting summarised through cloud, timed against the 3–4
minutes local currently takes, and confirmed to have made **one** call rather than five.
