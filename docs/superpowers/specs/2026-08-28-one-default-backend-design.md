# One default backend, and "Disabled" stops being one — design

**Date:** 2026-08-28
**Status:** approved, not yet implemented

## The problem

"Default" resolves through two different settings depending on which feature
asks.

| Path | Resolver | Falls back to | Features |
|---|---|---|---|
| Short-form | `activePolishBackend(for:)` | `polishBackend` | dictation polish, Reply Assist |
| Long-form | `backends(for:)` → `LongFormBackends.candidates` | `defaultBackend` | meetings, chronicles, brain-dump |

Both controls render unconditionally on the same screen: a `Picker("Polish
backend")` under *Backend*, and a "Default" row under *Which backend each
feature uses*. Two controls that both read as the global default.

Two consequences, both reachable today:

1. **"Disabled" does not disable.** Setting Polish backend to Disabled stops
   dictation polish while meeting summaries, chronicles and brain-dump keep
   running, because the long-form path never reads `polishBackend`.
2. **The Default row is not the default.** Setting it to Cloud moves three
   features and leaves two behind.

R's call (2026-08-28): Disabled should mean off everywhere.

## Why it happened, and why a quick patch is wrong

`defaultBackend` was introduced with per-feature backends and only half the
codebase migrated to it. The half that did not is the half whose fallback
carries a value the new enum cannot express: **`FeatureBackend` has no
`.disabled` case**, so `polishBackend` could not simply be replaced.

The insight that resolves it: **"Disabled" is not a backend.** It is dictation
polish's off-switch, living in a backend enum because dictation polish is the
only AI feature with no toggle of its own. Three of the five already have one —
`meetingsEnabled`, `replyAssistEnabled`, and `memoryEnabled` (which gates
chronicles). Brain-dump's "off" is not pressing its shortcut.

So the fix is not to teach the backend enum about disabling. It is to give
dictation polish the toggle its siblings already have, and delete the
duplicate global.

**Rejected: adding `.disabled` to `FeatureBackend`.** It would allow "record
meetings but never summarise them", which nothing expresses today — but it
spreads a non-backend concept across a type whose whole job is naming an
engine, and forces every resolution site to handle a case meaning "do not run".
If per-feature disabling is wanted later, it should be per-feature toggles, not
a backend value.

## The interface

### New: `AppState.dictationPolishEnabled: Bool`

**Defaults to `false`.** `polishBackend` currently defaults to `.disabled`, so
dictation polish is off on a fresh install. Defaulting the new toggle to `true`
would silently switch polish on for every new user — extra latency on every
dictation and a new way to fail — which is a product change disguised as a
refactor.

### Changed: `activePolishBackend(for:)`

Falls through to `defaultBackend` instead of `polishBackend`, and returns `nil`
for `.dictationPolish` when the toggle is off. `polishedText` already treats a
nil backend as a configuration state rather than a fault, so a deliberate "off"
raises no alarm — that path is unchanged.

The gate applies to `.dictationPolish` only. Reply Assist has
`replyAssistEnabled` and must not be gated by another feature's switch.

### Deleted: `AppState.polishBackend`

Its four other jobs are rehomed:

- **`usesCloud`** becomes "does any feature resolve to cloud", reusing the
  `cloudFeatures` logic that already exists in `AISettingsView` — moved to
  `AppState` so both callers share one answer.
- **The Foundation-Models nudge** (`polishBackend == .system, !isAvailable()`)
  keys off the *resolved* backend for the feature that actually failed, rather
  than a global that may not govern it.
- **`DebugInfo`** reports the five resolved choices instead of one global.
- **`MeetingAIDiagnostics`** reads the same, rather than the raw
  `polishBackend` key.

### Onboarding must flip the toggle

The AI step shipped 2026-08-27 calls `setBackend(_:for: .dictationPolish)` and
nothing else. Under this design that chooses a backend for a feature that stays
off — the step would appear to do nothing, which is the failure mode this
project has spent the week removing. Choosing a backend there sets
`dictationPolishEnabled = true`. **Not now** still writes nothing.

### Migration

One-time, guarded by a `hasMigratedPolishBackend` flag, expressed as a pure
function so it is testable without constructing `AppState`:

```swift
nonisolated enum PolishBackendMigration {
    struct Plan: Equatable {
        var dictationPolishEnabled: Bool
        var dictationBackend: FeatureBackend?   // nil = leave the slot alone
        var replyAssistBackend: FeatureBackend?
    }

    /// `old` is the stored `polishBackend` string; nil when the key is absent.
    /// The `existing…` values are what those slots already hold, so an explicit
    /// per-feature choice is never overwritten.
    static func plan(old: String?,
                     existingDictation: FeatureBackend,
                     existingReplyAssist: FeatureBackend) -> Plan
}
```

Rules:

- `old == nil` → nothing to do; toggle stays at its default of `false`.
- `old == "disabled"` → `dictationPolishEnabled = false`, both backends nil.
- otherwise → `dictationPolishEnabled = true`, and the equivalent
  `FeatureBackend` written into **dictation polish and Reply Assist**, each only
  where that slot is currently `.useDefault`.

**`defaultAIBackend`, meetings, chronicles and brain-dump are never written.**
This is the load-bearing rule and it gets its own test. `polishBackend`
governed exactly the two short-form features; writing it into `defaultAIBackend`
would silently route meeting transcripts and chronicles to whatever polish
backend the user had — cloud included. That is a privacy regression performed
by a refactor, which is the worst kind, because nothing on screen changes.

### Settings

The *Backend* `PorcelainSection` is removed. A **Dictation polish** toggle
replaces it. The Ollama and Cloud configuration sections appear when the Default
row or any feature resolves to that backend — so a Cloud API-key field never
appears for someone who has chosen nothing cloud-related, and the fields exist
exactly when they can matter.

The Default row keeps shipping as `.useDefault`, meaning the automatic on-device
order. Existing users see no behaviour change, and the honest default stays
"nothing leaves this Mac".

## What this does not do

- No `.disabled` in `FeatureBackend`, and therefore no way to keep a feature on
  while turning only its AI off.
- No change to `LongFormBackends.candidates`, to the rule that cloud is never a
  fallback, or to meeting audio never leaving the Mac.
- No change to what any feature does once a backend is resolved.

## Testing

Pure, and none of it constructs `AppState`:

- `PolishBackendMigration.plan` across every `old` value: absent, `disabled`,
  `system`, `cloud`, `ollama:qwen3.5:latest`, and an unrecognised string.
- **An explicit per-feature choice survives migration** — `existingDictation`
  non-`.useDefault` means `dictationBackend` comes back nil.
- **The plan can never name the global or a long-form feature.** `Plan` has no
  field for them, so this is enforced by the type; a test asserts the field set
  to keep it that way if someone adds one.

Live verification, each naming a result that could come back negative:

1. With `polishBackend = cloud` stored and no per-feature values, launch once →
   `aiBackend.dictationPolish` and `aiBackend.replyAssist` read `cloud`, and
   `defaultAIBackend`, `aiBackend.meetings`, `aiBackend.chronicles`,
   `aiBackend.brainDump` are **all still absent**. Read after quitting the app;
   cfprefsd serves other processes stale values.
2. With `polishBackend = disabled` stored, launch once → the Dictation polish
   toggle is off, and a dictation pastes raw text with no error capsule.
3. Turn Dictation polish off by hand → a meeting summary still generates. That
   is the bug this design fixes, so **it must now fail**: with the toggle off
   and everything on Default, summaries should still run on-device, because the
   toggle governs dictation polish only. **Control:** set the Default row to
   Disabled — which this design does not offer — is impossible, so instead
   confirm the Default row still governs meetings by setting it to Ollama and
   watching the meeting caption name Ollama.
