# M5 — Feature-Parity Audit vs. Appendix B

**Date:** 2026-07-31 · **Audited at:** `main @ e884eab` · **Reference:** the Tauri app at
`../omwhisper` (read-only spec, per `CLAUDE.md`).

**Verdict: parity is met and substantially exceeded. Four real gaps, two of them
release-blocking.** Everything below is verified against both codebases, not inferred from
the progress tracker.

---

## P0 — Blocks the first public .dmg

### 1. Sparkle can never actually update anyone

`SUFeedURL` is set (`project.pbxproj:393,434` → `https://omwhisper.in/appcast.xml`) and the
runtime is wired, but:

- **`SUPublicEDKey` is absent from Info.plist** — the PlistBuddy patch phase injects only
  `SUFeedURL` and `NSAudioCaptureUsageDescription` (`project.pbxproj:216`).
- No `appcast.xml` has ever been published.
- `scripts/build-release.sh` has no `generate_appcast` / `sign_update` step — it just prints
  a reminder at lines 151–153.

**Why it's P0, not P1:** the public key is baked into the shipped app. If 2.0 goes out
without it, every 2.0 install is permanently un-updatable — you'd have to make users
re-download by hand forever. This is the one item that is genuinely irreversible.

Needs your explicit go-ahead (key generation + publishing are public/semi-irreversible acts,
per `CLAUDE.md`).

### 2. No single-instance guard

Old app: `ensure_single_instance()` (`src-tauri/src/lib.rs:251`, called at `:305`).
Native: nothing — grep for `runningApplications` finds only `CallDetection.swift:83`.

Two copies running means two `CGEventTap`s on the same hotkey, two mic grabs, and two
memory/meeting daemons writing the same SQLite files. Easy to hit accidentally (Spotlight-
launching an app that's already resident in the menu bar shows no window, so nothing tells
the user it's already running). Appendix B lists it. ~10 lines.

---

## P1 — On Appendix B, genuinely missing

### 3. ~~Clipboard-restore delay is not a setting~~ — FIXED 2026-07-31

Appendix B: *"paste to frontmost app + clipboard restore **w/ delay setting**"*.

- Old: `clipboard_restore_delay_ms`, default 2000, user-editable (`settings.rs:38,149`).
- Native: `PasteService.paste(_:restoreDelay: Duration = .seconds(2))`
  (`Paste/PasteService.swift:39`) — and **no call site passes it**
  (`AppState.swift:1185`, `AppState.swift:1390`). Not reachable by the user.

Matters for slow targets (Electron apps, remote desktops, VMs) where 2s can restore the
clipboard before the paste lands. Also missing the old `restore_clipboard` on/off flag —
native always restores.

**Fixed:** `AppState.restoreClipboard` (default on) and `clipboardRestoreDelayMS` (default
2000, clamped ≥ 0 on read so a stale value can't feed a negative duration into the paste
path), both wired through a single `pasteRespectingClipboardSettings` helper so the two
paste sites can't drift. `PasteService.paste` gained `restoreClipboard:` and skips the
restore entirely when off. Controls sit under Settings → General.

### 4. No debug info / log export

Appendix B: *"debug info + rotating logs"*. Native has 12 `os.Logger` call sites, no log
file, no "copy debug info" affordance, no log level setting.

This one is already costing you: your own notes record that os_log is dead on dev builds and
that `--diagnose-meeting` was the *only* working evidence channel for the meeting bugs. A
beta soak without a way for a tester to hand you state produces unactionable reports.

### 5. ~~CapsLock PTT dropped~~ — WITHDRAWN 2026-07-31, not a gap

The original finding compared the two apps' *picker options* and concluded CapsLock had been
dropped. Checking the behaviour instead: the old app's single-key PTT entry point is

```rust
fn spawn_ptt_for_key(key: &str, ...) -> Option<crate::fn_key::PttTapHandle> {
    if key != "Fn" {
        return None;
    }
```

**CapsLock PTT never worked in the Tauri app.** It appeared in the settings picker and in
`MACOS_ONLY_KEYS` (`lib.rs:632`), but the CGEventTap that implements single-key PTT
(`fn_key.rs`) only ever handled Fn and Left Ctrl — picking CapsLock silently did nothing.
Right Option and Right Control were dead there too, and the native app implements both for
real (`PTTKey.pressState`). Native is *ahead* on PTT, not behind.

Not worth building now either: CapsLock is a latching key. macOS emits `flagsChanged` when
the lock state toggles, not on physical press and release, so "hold to talk" isn't
expressible — you'd get press-to-start/press-to-stop, a stuck caps LED, and nothing at all
for the many users who remap the key. If a CapsLock trigger is ever wanted it should ship
honestly as a *toggle*, not as PTT.

Lesson for the rest of this audit: a checklist entry describes what the old UI *offered*,
which is not the same as what it *did*.

---

## P2 — Old-app settings absent from Appendix B (decide, don't default)

Not parity failures — they were never on the checklist — but they're capability the old app
had and a returning user may miss:

| Old setting | Native |
|---|---|
| `overlay_placement` (6 positions) | Fixed bottom-center |
| `show_dock_icon` | Menu-bar-only, always |
| `restore_clipboard` (on/off) | Always restores |
| `apply_polish_to_regular` | Regular ⌘⇧V always pastes raw; polish only in Smart mode |

---

## Confirmed present — no action

Menu-bar residency · ⌘⇧V toggle (and it's re-recordable, via `dictationShortcut` — the old
app's `hotkey` equivalent) · live streaming overlay (exceeds parity) · paste + clipboard
restore · mic device selection · level meter (overlay bars) · start/stop sounds + volume ·
history search / export txt-md-json / delete / clear / auto-delete / storage info · stats
totals-today-streak (`HistoryStore.homeStats`) · legacy DB importer · custom vocabulary ·
word replacements · fuzzy toggle · 7 polish styles + custom CRUD · Smart Dictation with raw
fallback · backends Disabled/System/Ollama/Cloud · translate language picker · test
connection · onboarding · settings sections · error recovery (`errorMessage` +
`.error(label:)` overlay — engine failure copies the text out rather than crashing).

---

## Appendix B itself is stale — fix the checklist

1. **"launch sound" does not exist in the old app.** `sounds.rs` bundles only
   `start.wav`/`stop.wav`, played from `commands.rs:223` and `:536` at record start/stop.
   Nothing plays at app launch. Strike the item.
2. **"6 built-in styles"** (line 153) — the old app shipped 7 (Smart Correct added later
   upstream); native ships 7.
3. **"Explicitly dropped: … Whisper/Moonshine engines"** (line 155) — Whisper was un-dropped
   and shipped 2026-07-11 as a fourth engine.

And the checklist no longer describes the product: native additionally ships Parakeet, five
cloud STT providers, meeting recording/transcription/summary, memory + chronicles, an MCP
server, reply assist, cross-lingual dictation, and brain-dump mode. Appendix B is a
2.0-minimum floor, not a scope statement.

---

## Recommended order

1. ~~Single-instance guard (P0-2)~~ — done 2026-07-31.
2. ~~Debug-info export (P1-4)~~ — done 2026-07-31.
3. ~~Clipboard delay setting + `restore_clipboard` (P1-3)~~ — done 2026-07-31.
   ~~CapsLock PTT (P1-5)~~ — withdrawn, never worked in the old app either.
4. **Prove the distribution path** — and note it has *never* been run: no git tags, no
   releases, no `.env`, and no Developer ID Application certificate installed (only an
   "Apple Development" cert, which cannot notarize). The chain is strictly ordered —
   Developer ID cert → `build-release.sh` runs → a real .dmg exists → Sparkle key signs it
   → appcast published → auto-update proven. The cert and an app-specific password are the
   user's to create; everything after is scriptable.
5. That first fresh install also closes three owed live verifications at once: onboarding
   first-run on a clean `hasCompletedOnboarding`, the single-instance guard in its real
   `/Applications`-vs-`~/Downloads` case, and whether a notarized Release build's TCC
   permissions behave like the dev build's (the Info.plist PlistBuddy patch phase has only
   ever run under Debug).
6. Then the rest of the live backlog (real multi-person call, Deepgram/OpenAI/Groq,
   D4b motion + dark mode, cross-engine WER) → beta soak → tag the Tauri repo `v-final`.
