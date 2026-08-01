# Memory — User-Editable Exclusions — Design

**Date:** 2026-08-01
**Status:** Approved. Pending an implementation plan.
**Area:** S1 Memory capture. Follows `2026-08-01-memory-visible-windows-design.md`,
which widened what Memory records and made this gap matter more.

## Problem

Memory captures every visible window's text. The only thing a user can exclude is a
**website**. Everything else is hardcoded:

| Exclusion | Editable |
|---|---|
| Websites / domains | **yes** — `memoryExcludedDomains`, "Excluded sites…" sheet |
| Password managers (`com.apple.Passwords`, 1Password, Keychain Access) | no |
| Private / Incognito windows, by title | no |
| `.env` files, by title (added 2026-08-01) | no |

So there is no way to say "never capture Messages", "never capture my banking app", or
"never capture anything titled *Salary review*". Every such request today needs a code change.
Visible-windows capture sharpened this: a chat window parked on a second monitor is now
recorded where it previously was not.

## Decision

**One "Exclusions…" sheet with three lists**, replacing today's single-purpose
"Excluded sites…" button:

1. **Apps** — chosen from currently-running apps, stored as bundle IDs.
2. **Sites** — today's domain list, moved in unchanged.
3. **Window title contains** — free text, matched case-insensitively as a substring, the
   same way "Incognito" already is.

Rejected: three separate buttons (grows the settings bar for no benefit); a single combined
list with typed prefixes like `app:Slack` (a syntax to learn and to get wrong).

**Hardcoded exclusions stay hardcoded and are not shown as removable.** Password managers,
private browsing and `.env` are safety floors, not preferences — a user must not be able to
switch off "never capture 1Password" by mistake. The user's lists only ever *add*.

## Architecture

### Where the check happens, and why it moves

Domain exclusion currently runs in `MemoryCapture.tick()`, **after** the window has been read
— the AX walk has already pulled up to 50,000 characters into memory, and the result is then
discarded. That is acceptable for domains (the URL is only known after reading the window) but
wrong for apps and titles, which are known **before** any text is read.

App and title exclusion therefore run inside `WindowSnapshotReader.capture(...)`, next to the
existing `ScreenContextReader.isExcluded` call, so an excluded app's text is never read at
all. Domain exclusion stays where it is.

| Piece | Responsibility |
|---|---|
| `MemoryExclusions` | Plain value type carrying the user's three lists. Pure `excludes(bundleID:windowTitle:)`, tested directly. |
| `ScreenContextReader.isExcluded` | **Unchanged.** Still the hardcoded safety floor, still shared with S2's dictation context. |
| `WindowSnapshotReader` | Takes a `MemoryExclusions` and checks it alongside the hardcoded floor, before the text walk. |
| `MemoryCapture` | Owns the current `MemoryExclusions` (assigned from `AppState`, same wiring as `excludedDomains` today) and keeps the domain check in `tick()`. |
| `AppState` | Two new settings beside `memoryExcludedDomains`: `memoryExcludedApps`, `memoryExcludedTitleKeywords`. |

`MemoryExclusions` is what makes this testable without a window: the decision is a pure
function of two strings and three lists.

### Settings

Both new settings follow `memoryExcludedDomains` exactly — `[String]` in `UserDefaults`,
`access(keyPath:)` / `withMutation(keyPath:)` (this project's `@Observable`-over-external-
storage requirement; a plain computed property does not notify, which has caused real
"the row didn't disappear" bugs here), and a setter that pushes the value into
`memoryCapture`. Empty by default — nothing changes for an existing user until they add
something.

**Apps are stored as bundle IDs, chosen by name.** A bundle ID is the stable identity, but
nobody should have to type `com.apple.MobileSMS`. The picker lists running apps with
`activationPolicy == .regular` (so agents and daemons never appear), showing name and icon,
and stores the ID. A stored ID whose app is not running still displays — falling back to the
raw ID when no name can be resolved, rather than vanishing from the list.

### Title keywords

Substring, case-insensitive, matched against the window title — deliberately the same
mechanism as the built-in "Private Browsing" / "Incognito" entries, so there is one rule to
understand and it already has proven behaviour. No globs, no regex: a regex box in a privacy
setting is a way to write an exclusion that silently matches nothing.

The sheet must say plainly that this matches the **window title only**, not page content — a
user who excludes "password" will otherwise assume more protection than they have.

## What this does not fix

**Title-based exclusion has a real hole and the UI must not imply otherwise.** If a window's
title does not name what it contains — a terminal running `cat .env`, an editor showing only
the project folder, a chat app showing only the app name — no title rule catches it. The
honest fix is content-level secret detection at write time, which the app already has for
cloud egress (`Polish/Redactor.swift`, a 10-detector registry). Reusing it on the Memory write
path is a larger, separate change and is **not** in scope here.

**Nothing is removed retroactively.** Adding an exclusion stops future capture; rows already
stored stay until the user clears Memory or they age out at the 90-day retention. The sheet
should say so, because the opposite is the natural assumption.

## Testing

Pure, per this project's convention:

- `MemoryExclusions.excludes(...)`: app matches by exact bundle ID; title keyword matches
  case-insensitively as a substring; empty lists exclude nothing; a keyword that is only
  whitespace never matches everything (the failure mode that would silently disable capture).
- Hardcoded floor still applies when the user's lists are empty — the regression proof that
  `ScreenContextReader.isExcluded` was not displaced.
- Bundle-ID normalisation and de-duplication on add, mirroring `normalizedDomain`.

Live: add a running app to the list, confirm no new rows for it appear while it stays visible
on a second display, and confirm rows for a *different* app keep appearing in the same window
— the second half is what makes the check able to fail rather than merely observing silence.

## Out of scope

Retroactive deletion of already-captured rows · content-level secret detection · per-app
capture *frequency* · excluding by file path rather than window title · time-of-day rules ·
any change to the meetings or history stores.

## Exit criteria

A user can add an app, a site and a title keyword from one sheet; each stops future capture;
an excluded app's window text is never read (not read-then-discarded); the hardcoded password
manager / private browsing / `.env` exclusions still apply and are not user-removable; and
with all three lists empty, capture behaves exactly as it does today.
