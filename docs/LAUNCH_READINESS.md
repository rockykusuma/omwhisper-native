# Launch Readiness — what the feature roadmap doesn't cover

> Gap analysis, 2026-07-07. The M/S/F/T phases plan *features*; this doc plans
> everything between "built" and "shipped, trusted, survivable." Items marked
> **DECIDE** need R's call; the rest are work items that should attach to
> existing milestones (suggested attachment in brackets).

---

## 1. Release engineering [attach to M5, start now]

- **Sparkle go-live** (already parked for R's go-ahead): generate EdDSA keypair
  (store private key OFFLINE + backup — losing it strands every installed copy),
  publish `appcast.xml` to omwhisper.in, add `generate_appcast` to
  build-release.sh. Semi-irreversible; do once, carefully.
- **Release checklist** doc: version bump, changelog, notarize, staple, SHA-256,
  appcast entry, website download link, git tag. One page, followed every time.
- **Rollback story**: keep N−1 DMG downloadable; appcast supports pulling a bad
  release. Decide the "bad build shipped" procedure before it happens.
- **Min-OS gate**: the DMG needs `LSMinimumSystemVersion` messaging and the
  website needs a "requires macOS 26 (Apple Silicon)" gate with the Tauri app
  offered to everyone below it. Otherwise the #1 support email is "won't open."

## 2. Edge-case catalog [attach to M2/M3 QA — cheap to test now, expensive later]

Real-world states no milestone explicitly owns:

- **Secure input fields** (passwords, some terminals): macOS blocks event taps
  and paste; PTT keydown may not even arrive. Detect `IsSecureEventInputEnabled`
  → overlay shows a calm "secure field" state instead of appearing broken.
- **Mic disappears mid-dictation** (AirPods die, USB unplugged): must finalize
  what was heard, not crash or hang; overlay error state.
- **Sleep/wake + display changes**: overlay position on multi-monitor,
  full-screen apps and Stage Manager, screen-sharing (overlay is visible to
  the far side — acceptable? note in docs at minimum).
- **Hotkey conflicts**: ⌘⇧V collides with "Paste and Match Style" in many apps
  — needs conflict detection or at least easy rebinding surfaced in onboarding.
- **Paste target vanished** (app quit between stop and paste): clipboard
  fallback + notification, never silent loss.
- **Long dictations**: 10-minute hold — memory growth, engine limits, UI.
- **Login-item + PTT race** at boot; permission revoked while running
  (user unchecks Accessibility mid-session).

Deliverable: a one-page test matrix run before each release (pairs with the
release checklist).

## 3. Privacy formalization [attach to S1/S3 — before any memory/meeting ship]

The brand IS privacy; it needs artifacts, not just behavior:

- **Privacy page rewrite** (S6 dependency): per-feature table — what's
  captured, where it's stored, what leaves the machine and when, how to
  delete it. Mechanism-level honesty, matching the copy voice rules.
- **Data lifecycle**: "Export everything" (history/meetings/memory → files)
  and "Delete everything" (one button, includes Keychain entries) in Settings.
  Ship WITH S1, not after.
- **Threat model note**: memory DB is plaintext SQLite protected by FileVault
  + file permissions — document that stance (or decide to encrypt at rest).
  **DECIDE**: is FileVault-reliance the stated position for 2.x?
- **Meeting-consent legal note**: recording laws vary (two-party consent
  states/countries); S3 UI shows a one-line reminder, docs carry the fuller
  note. Same posture as Smriti's README, surfaced in-product.
- **No-telemetry policy**: state it publicly ("no analytics, no crash
  reporters, no network calls except updates + your chosen backends") — it's
  a differentiator; make it checkable (document every network call the app
  can make).

## 4. Support & feedback without telemetry [attach to M5]

No analytics means support IS the feedback channel:

- **In-app diagnostics**: "Copy Debug Info" (versions, engine, permissions
  state, last error — all local, user-visible before sending) + local log
  file with rotation. The Tauri app had this; the native app doesn't yet.
- **Report a problem** menu item → pre-filled email/GitHub issue with the
  debug info the user consents to attach.
- **DECIDE**: support channel — GitHub issues only, or an email too?
- **Docs/FAQ**: a help section on omwhisper.in (10 articles: permissions,
  hotkey change, engines, PTT, styles, meetings consent, memory controls,
  uninstall, "why macOS 26", troubleshooting mic). Wispr Flow's help center
  is the reference for tone.
- **Uninstall story**: docs page listing exactly what to remove (app, app
  support dir, login item, Keychain items) — privacy-brand table stakes.

## 5. Accessibility & localization [start in M2, audit at M5]

- **App-wide a11y**: overlay spec covers the HUD; the hub needs VoiceOver
  labels, full keyboard navigation, Dynamic Type, contrast check on Porcelain
  dims (`--dim` on white is borderline — verify ≥4.5:1 for body text).
  A dictation app attracts RSI/motor-impaired users; a11y is core audience.
- **Localization readiness**: String Catalog from day one (retrofitting is
  misery). **DECIDE**: launch languages — English-only for 2.0 is fine, but
  F4 (speak Telugu/Hinglish) implies UI localization for those markets in
  2.2; plan the string freeze then.

## 6. Performance & footprint budgets [attach to M4]

The overlay has budgets (<3% CPU, 60fps); the app doesn't:

- Idle (menu bar, no dictation): ~0% CPU, target < 150MB RAM.
- Engine memory policy: models cached after first use — decide eviction
  (unload after N min idle?) especially once Parakeet (~600MB class) lands.
- S1 capture daemon: battery test on laptop (the 5s AX walk) with a
  measured number before it ships.
- Disk: model storage location + "manage downloads" UI (M4), meeting audio
  growth cap / auto-prune setting (S3).

## 7. Identity & legal [before M5 public launch]

- **DECIDE — license & repo visibility**: Tauri app is MIT/public. Is
  omwhisper-native also MIT/public from day one? (Open source is part of the
  trust story; decide deliberately, not by default.)
- **Name check**: quick trademark/App-name collision search for "OmWhisper"
  in software (there are many *Whisper*-named tools post-OpenAI-Whisper).
  Cheap now, painful after launch.
- **Domain/email**: omwhisper.in is becoming the app's home (appcast lives
  there) — set up support@ / security@ addresses; a security-contact page
  (privacy-first apps get security researchers).
- **DECIDE — sustainability**: "free for everyone" is the identity. Options
  that don't betray it: nothing (hobby), GitHub Sponsors/donations link,
  or a paid "supporter" tier that unlocks nothing (Things-style goodwill).
  Decide before launch so the website copy is stable.

## 8. Existing-user migration [attach to M5]

- Tauri-app users: final Tauri release should show a one-time "OmWhisper 2.0
  is native" notice pointing to the new download (the old updater
  version.json can carry it). History importer already ships in M2 ✅.
- Windows users: clear message that Windows stays on 1.x (maintained? frozen?
  **DECIDE** the public wording — "frozen" reads abandoned; "feature-complete"
  reads intentional).

## 9. Success criteria without analytics [M5 beta]

No telemetry → define success observationally: beta cohort (10–20 users) with
a weekly 5-question form (dictations/day self-report, failures seen, feature
they'd delete, NPS-ish), plus the existing sign-off latency numbers re-run on
each beta build. Write the form once, reuse weekly.

---

## Order of urgency

1. **Edge-case catalog** (§2) — cheapest now, shapes M2/M3 code as it's written.
2. **Sparkle go-live + release checklist** (§1) — blocks any real distribution.
3. **A11y + String Catalog from day one** (§5) — retrofit cost is brutal.
4. **Privacy artifacts** (§3) — must exist the day S1/S3 ship, draft earlier.
5. **DECIDE items** (license, sustainability, support channel, FileVault
   stance, Windows wording) — each is a sentence from R; batch them in one
   sitting.
6. Everything else attaches to M4/M5 naturally.
