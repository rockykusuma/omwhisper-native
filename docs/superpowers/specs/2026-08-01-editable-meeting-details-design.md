# Editable Meeting Details — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming)
**Area:** S3 Meetings / SP1 follow-on. Motivation below is the important part: it records why the obvious automated answer was rejected on evidence.

## Why this exists (the Outlook investigation, 2026-08-01)

R asked to integrate Outlook calendars alongside Apple Calendar. Three automated
routes were investigated and **all three were empirically ruled out for R's
setup** — each by an observation that could have come back positive:

| Route | Finding |
|---|---|
| **EventKit / Apple Calendar** | Adding the work account fails with `AADSTS7000112: Application 'Apple Internet Accounts' is disabled`. WSA's Entra admin has disabled Apple's integration tenant-wide. Permanent; nothing on the Apple side can fix it. |
| **Outlook AppleScript** | Outlook 16.111 ships a full `.sdef` with `calendar event` (subject/start/end/organizer) and `required attendee`, and answers pings — but R runs **New Outlook** (`IsRunningNewOutlook = 1`), where the legacy scripting engine sees nothing: a live probe returned **0 exchange accounts, 0 events**, 1 placeholder calendar. Reading the `.sdef` alone would have led to building the whole integration and discovering this only at live-test time. |
| **Local Outlook database** | New Outlook's container (153 MB) holds only WebKit caches and telemetry — no calendar store. It is a web client; the data lives in the cloud. |
| **Microsoft Graph** | Graph Explorer — *Microsoft's own first-party tool* — returned 403 on `/me/events` and its consent flow required **admin approval** for `Calendars.Read`, despite Microsoft's baseline classification of that scope as user-consentable. WSA disables user consent tenant-wide. An unverified third-party publisher like OmWhisper would face at least the same bar. |

**Conclusion:** every automated path for R's work calendar terminates at a
policy his own IT controls. Building Graph would ship a sign-in button that
returns "Need admin approval" until WSA approves OmWhisper specifically. So the
feature that actually solves the problem is the one no vendor or admin can
withhold: let the user type the details.

Graph is **specced-but-unbuilt**, revisit only if (a) WSA approves the pending
request, proving the path is open, or (b) other users ask — for personal
Microsoft accounts and permissive tenants it would work.

## Design

The schema already supports this: SP1 added `title` and `attendees` to
`meetings.db`. Today they are written only at insert time from a calendar match
or the AX window title. This makes them user-editable. **No migration.**

1. **Store** — `MeetingStore.setDetails(id:title:attendees:)`, alongside SP1's
   `setSpeakerNames` and SP2's `setSummary`. Empty input stores `nil`, not `""`,
   so a cleared title falls back to the app name exactly like an unmatched
   meeting does today.
2. **Parsing** — attendees are typed as one comma-separated line
   ("Alice, Bob Kumar, Priya"). A pure `parseAttendees(_:) -> [String]` splits,
   trims and drops empties. This is the only real logic and the only unit test
   that can fail.
3. **UI** — an "Edit details" button in the meeting detail header opens a
   popover with Title and Attendees fields, matching the affordances already in
   this view (SP1's speaker-rename popover, SP2's summary Edit) rather than
   inventing a third pattern. Saving reloads, so the list row retitles at once.

## Behaviour

- Manual edits **survive re-transcribe**: `transcribeMeeting` writes transcript,
  summary and speaker names only. A test pins this so it stays true.
- Calendar matching runs only at insert, so it can never overwrite something the
  user typed afterwards.
- Edited attendees feed SP1's **speaker-rename suggestion chips** for free —
  they read `meeting.attendees` regardless of origin. Type three colleagues
  once, then rename each speaker with one click.

## Out of scope (YAGNI)

Autocomplete from past attendees; chip/token-style entry; editable
date/duration; bulk editing across meetings; Microsoft Graph (above).

## Testing

- `parseAttendees`: splits on commas, trims whitespace, drops empty entries,
  returns nil-equivalent for a blank line.
- `setDetails`: round-trips title and attendees; empty strings persist as nil.
- Re-transcribe preserves title/attendees (guards the promise above).
- Live: edit a title → list row and header update and survive relaunch; typed
  attendees appear as rename chips on a speaker label; clearing the title falls
  back to the app name.

## Where it lands

On the existing `worktree-sp2-meeting-notes` branch. SP2 is implemented but not
yet live-verified, and both changes edit the same header region of
`HubMeetingsSectionView` — separate branches would only manufacture a merge
conflict, and both get verified in the same pass.

## Exit criteria

A meeting's title and attendees can be typed, corrected and cleared from the
detail pane; they persist, survive re-transcription, retitle the list row, and
feed the speaker-rename suggestions — with no calendar account, no permission
prompt, and no IT approval anywhere in the path.
