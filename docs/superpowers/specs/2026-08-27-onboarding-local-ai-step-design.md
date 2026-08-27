# Onboarding: offer local AI, and route the empty states honestly — design

**Date:** 2026-08-27
**Status:** approved, not yet implemented

## The problem

Onboarding is `welcome → permissions → tryIt → done`, and the words *ollama*,
*polish* and *backend* appear **zero times** in `OnboardingView.swift`. There
is no AI step to fix — there is no AI step at all. `polishBackend` defaults to
`.disabled`, so a new user is never routed toward a backend in the first place:
polish simply does not exist for them until they find the hub.

That is defensible for cloud, which costs money and sends text off the Mac. It
is not defensible for the two **on-device** backends, which are the product's
actual story: "user choice of local vs. cloud" is meaningless if a new user
never learns the local half exists.

## The four states, not one

The question that started this was "what happens when the user has no Ollama
models?" That is one of four states, and today the app cannot tell them apart:

| State | Truth | What the app says today |
|---|---|---|
| Nothing on :11434, no app, no binary | Ollama isn't installed | "Couldn't reach Ollama. Is it running?" |
| App/binary present, port refused | Installed, not running | *the same sentence* |
| Running, `/api/tags` returns `[]` | Running, no models | *the same sentence* — reachable is true but the list is empty |
| Running, models present | Ready | model picker |

`Ollama.checkStatus` returns a **Bool**, which collapses rows 1–3. Telling
someone to check whether a service is running when they have never installed it
is the same failure this project has already recorded twice: the URLSession
error collapse that reported a timeout as "Couldn't reach Ollama. Is it
running?" while Ollama was up, and `SystemLanguageModel.availability` reporting
`.available` on a Mac where every generation threw. A wrong diagnosis costs more
than no diagnosis, because it sends the next hour to the wrong place.

The app is not sandboxed, so the distinction is cheaply available:
`/Applications/Ollama.app`, `~/.ollama`, `/opt/homebrew/bin/ollama`.

## Decisions

Made by R during brainstorming, recorded because each closes off an approach
that will otherwise be re-proposed:

1. **Onboarding offers local AI as a skippable step** — it does not merely fix
   empty states elsewhere, and it does not steer new users into a multi-gigabyte
   download before their first dictation.
2. **On-device backends only.** Cloud is absent from first-run: it needs an API
   key, costs money and sends text off the Mac. None of those belong in a
   wizard, and `AIFeature`'s own doc comment already says egress is a decision
   per feature, not a default.
3. **The step writes `dictationPolish` and nothing else.** It is the only AI
   feature a brand-new user will hit; the other four are off by default and get
   a backend when they are turned on.
4. **No model downloader.** Not in onboarding, not in Settings, not in this
   project. Both surfaces show the exact `ollama pull` command instead.
5. **The download, if it is ever built, belongs in Settings** — where it can run
   in the background, be retried, and not strand someone mid-wizard.

## The interface

### `Polish/OllamaPresence.swift` (new, `nonisolated`)

```swift
nonisolated enum OllamaState: Equatable {
    case notInstalled
    case installedNotRunning
    case runningNoModels
    case ready([String])
}

/// Pure: the whole classification, so it is testable without a network or a
/// filesystem. `reachable` means /api/tags answered 2xx; `models` is what it
/// listed.
nonisolated static func classify(appInstalled: Bool,
                                 reachable: Bool,
                                 models: [String]) -> OllamaState

/// Effectful: FileManager probes + the existing Ollama.listModels.
nonisolated static func detect(baseURL: String) async -> OllamaState
```

Precedence is `reachable` first: a running server is proof of installation
whatever the filesystem says (Docker, a custom prefix, a remote `baseURL`). Only
when unreachable does `appInstalled` decide between `.installedNotRunning` and
`.notInstalled`.

`Ollama.checkStatus` stays — `detect` needs both the reachability answer and the
list, and the Settings "Test Connection" button still wants a plain yes/no.

### The step

New `.aiPolish` case in `OnboardingStep`, between `.tryIt` and `.done`. After
Try It the user has watched their own words appear, so "want them cleaned up?"
has a referent. Done still ends with shortcuts and launch-at-login.

Dark identity, like every other onboarding step — it ignores the appearance
picker. Two cards:

**Apple Intelligence.** Either a "Use Apple Intelligence" button, or
`SystemLLM.unavailableReason()`'s sentence verbatim. That function already names
the real cause, including the `en-IN` case where `availability` says
`.available` and every generation throws. Rendering our own summary here would
reintroduce exactly the bug it was written to fix.

**Ollama.** One of the four states:

- `.ready(models)` — a picker, and "Use Ollama".
- `.runningNoModels` — `ollama pull qwen3.5`, a copy button, the size, and a
  **Refresh** that re-runs `detect`. This is the state the objective named.
- `.installedNotRunning` — "Ollama is installed but not running" and an **Open
  Ollama** button (`NSWorkspace.open`).
- `.notInstalled` — a link to ollama.com and the same command for after.

**Skip for now** is always enabled and never a dead end, matching the rule
already established for the Try It step: denial is never a dead end.

### What it writes

On an explicit choice only:

```swift
appState.setBackend(.system, for: .dictationPolish)
appState.setBackend(.ollama(model: picked), for: .dictationPolish)
```

`FeatureBackend.ollama(model:)` carries the model inline, so there is no second
write to keep in sync. Skip writes nothing. The global `polishBackend` is
untouched, so the other four features stay `.useDefault` → `.disabled` without
needing a guard.

### Settings inherits the same honesty

`AISettingsView`'s Ollama section switches to `OllamaPresence` and gains the
same pull-command block. Without this, the step's "you can set this up in
Settings" points at a page that still cannot tell the four states apart — and
the four-state distinction is the substance of this work, not decoration.

## Which model the copy names

`qwen3.5`. This is a measurement, not a preference: on this machine and this
transcript, `qwen2.5-coder:7b` attributed statements to the wrong speaker and
invented a term; `llama3.2:3b` returns "Nothing relevant." for content plainly
present, which makes Ask look broken; `gemma4` is 9.6 GB and **froze this 16 GB
Mac**, swap having already been 22.3 GB of 23.5 GB before it loaded. qwen3.5 is
9.7B in 6.6 GB and got attribution right.

So the copy states the size and cautions about RAM. Recommending a model on
answer quality without checking whether the hardware can hold it is a mistake
this project has already made once.

## What this does not do

- **No `POST /api/pull`.** No progress, cancel, resume or disk-space handling
  enters the app. Ollama's own app already downloads models well.
- **No Cloud in first-run.**
- **No change to the other four features**, and none to the global
  `polishBackend` default.
- **Nothing for existing users** — onboarding is gated by
  `hasCompletedOnboarding` and shown once. This reaches new installs and the
  `#if DEBUG` "Reset Onboarding…" path only.

## Testing

Unit, and none of it constructs `AppState` — doing so opens the real history and
memory stores, which is the trap `KeychainTests` fell into:

- `classify` across all four states, plus the precedence rule: `reachable ==
  true` with `appInstalled == false` must be `.ready`/`.runningNoModels`, never
  `.notInstalled`.
- `.ready([])` must be unrepresentable in practice — reachable with an empty list
  is `.runningNoModels`. A test pins that, because returning `.ready([])` would
  render a picker with nothing in it.
- The existing 7 `OnboardingLogicTests` updated for the new case: ordering,
  `next` from `.tryIt`, and `isLast` still only true for `.done`.

**Live verification is owed and cannot be replaced by any of the above.** Each
check names a result that could come back negative:

1. Ollama quit → the card reads *installed but not running*, not *isn't
   installed*. **Control:** move `/Applications/Ollama.app` aside and confirm it
   then reads *isn't installed* — without that, one correct-looking string
   proves nothing about the classification.
2. Ollama running with every model removed → the pull command appears; `ollama
   pull qwen3.5` in a terminal, then **Refresh** → the picker appears without
   restarting the app.
3. Choosing Ollama → `defaults read com.omwhisper.mac.dev aiBackend.dictationPolish`
   reads `ollama:<model>` **and** `aiBackend.meetings` is still absent. Read it
   after quitting the app: cfprefsd serves another process stale values.
4. On this en-IN Mac, the Apple Intelligence card shows the language sentence,
   not a working button.
5. Skip writes nothing: `aiBackend.dictationPolish` absent afterwards.
