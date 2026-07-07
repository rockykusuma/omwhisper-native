# Handoff: menu bar icon "not tappable" — debugging state (2026-07-07)

## ✅ RESOLVED (2026-07-07)

Root cause: **SwiftUI `MenuBarExtra` silently drops real mouse clicks on macOS 26
(Tahoe)** — synthetic AX/AppleScript clicks work (false green), only a human
physical click exposes it. Fixed by replacing `MenuBarExtra` with an AppKit
`NSStatusItem` + `NSMenu` in `AppDelegate` (`OmWhisperApp.swift`); SwiftUI App
lifecycle kept only for the `Settings` scene. Proven by a bare `NSStatusItem`
spike that took 36/36 real trackpad clicks where `MenuBarExtra` took none, then
confirmed end-to-end on the full menu. The investigation trail below is kept as a
post-mortem.

## The bug (user report)

From the moment the app launches, clicking the OmWhisper menu bar icon (SwiftUI
`MenuBarExtra`, SF Symbol "waveform") does nothing for the user. Persists across
yesterday's and today's attempts. **Still unresolved for real user clicks** —
see "The contradiction" below.

## Environment

- macOS 26.5.1 (25F80), Apple Silicon
- Two displays: **DELL P2419H 1920×1080 = MAIN display** (menu bar origin 0,0),
  Built-in Retina 3456×2234 secondary
- Debug build from DerivedData:
  `~/Library/Developer/Xcode/DerivedData/omwhisper-native-fxpcbydguyylgrazhqwstjzordaj/Build/Products/Debug/OmWhisper.app`
- Bundle ID `com.omwhisper.mac`. The OLD Tauri app (`com.omwhisper.app`) is also
  installed and normally running — its ॐ tray icon sits **directly adjacent** to the
  native app's waveform icon in the menu bar. It was quit during testing; user may
  have relaunched it since.
- Notable installed apps that touch the menu bar: **Say No to Notch**, Highlight,
  possibly others (not investigated).

## Config history (important — two variables changed together)

| Variant | LSUIElement | menuBarExtraStyle | Result |
|---|---|---|---|
| Committed HEAD (`63f9d61`) | YES | `.window` | Icon shows, menu/popover never presents (original bug) |
| Yesterday's uncommitted change | NO | `.menu` | User still reports dead icon |
| Current working tree (today) | **YES** (reverted by me) | `.menu` | Synthetic clicks work 100%; **user's real clicks still don't** |

Current uncommitted diff: `OmWhisperApp.swift` (`.window` → `.menu` + comment),
`project.pbxproj` (LSUIElement NO → YES, both build configs). Rebuilt with
`xcodebuild -scheme omwhisper-native` — build green, app runs, `LSUIElement=true`
in built Info.plist, no Dock icon. App was killed at user request; last built
product is current with the working tree.

## What is VERIFIED (evidence, not inference)

1. **App launch is healthy.** Unified log (`log show --info --debug --predicate
   'subsystem == "com.omwhisper.mac"'`) shows `AppState.init` completes, both NSEvent
   hotkey monitors install, no errors, no hang. Accessibility = false (debug build,
   not yet granted — irrelevant to clicking, relevant to paste).
2. **The NSStatusItem and its menu are fully functional.** Via System Events (AX):
   `menu bar item 1 of menu bar 2` exists (pos ≈ 872,3, size 34×24), and both
   `click <item>` (AXPress) and **synthetic physical clicks at the item's global
   center** (`System Events: click at {889, 15}`) open the 5-item menu
   (Start Dictation / sep / Grant Accessibility Access… / Settings… / Quit).
3. **Timing is NOT the issue for synthetic clicks.** Fresh `pkill` + relaunch, then
   clicks starting ~3 s after launch: **8/8 successes across two runs** (5/5 then 3/3),
   in both LSUIElement=NO and =YES variants, all with `.menu` style.
4. `.menu` + LSUIElement=YES: `background only = true`, no Dock icon, menu still
   opens on synthetic clicks 3/3 after fresh launch of a clean rebuild.

## The contradiction (the actual remaining mystery)

Synthetic clicks at the AX-reported coordinates open the menu **every single time**;
the user's **real trackpad/mouse clicks do nothing** (reconfirmed today on the
rebuilt `.menu`+YES build). So the item, menu, and app are fine — something about
real mouse events at the menu bar never reaches the item, or the user is clicking a
different location/display than the tested one.

Unresolved observations consistent with this:
- Claude's computer-use tool clicks (separate synthetic-event path, screenshot-space
  coordinates) at the *computed* icon position did nothing, and one such click landed
  on the **adjacent old Tauri ॐ icon** and opened the Tauri window instead — i.e.
  that click path lands ~20–30 pt left of the computed target. Coordinate/space
  confusion around the menu bar is easy here; treat any screenshot-based clicking
  as unreliable evidence.
- All successful tests clicked the **main (Dell) display's** menu bar at AX
  coordinates. Nobody has verified the **built-in Retina (secondary) display's**
  menu bar copy of the icon. macOS 26 (Tahoe) has known menu-bar flakiness reports
  (missing/unresponsive items, e.g. AeroSpace #1968, Maccy #1224, Ice #711,
  Stats #3120).

## Hypotheses for the remaining gap, in order

1. **User clicks on the secondary (built-in) display's menu bar.** Tahoe
   menu-bar-extra bugs on non-main displays would explain everything: AX/synthetic
   clicks target the main display and work; real clicks on the built-in menu bar fail.
   → Test: have the user click on the Dell's menu bar specifically; and separately
   test a real click on the built-in display.
2. **User is clicking the wrong icon.** The old Tauri ॐ icon sits immediately next
   to the native waveform icon; when the Tauri app is running, a click there opens
   the (sometimes slow/hidden) Tauri window, looking like "nothing happened."
   → Test: quit the Tauri app (`pkill` or its Quit) before testing; hover to confirm
   which icon is which.
3. **A menu-bar utility intercepts real mouse events.** "Say No to Notch" (installed)
   or similar overlays the menu bar region; synthetic `click at` may hit the item via
   a path such utilities don't intercept.
   → Test: quit Say No to Notch (and any menu-bar manager), then real-click.
4. **Real vs synthetic event delivery difference in Tahoe** (least likely; no
   supporting reports found).

Explicitly RULED OUT: `.window` style (already replaced; it was the original M0/M1
bug — silently never presents), LSUIElement value (both tested OK), app hang at
launch, missing/failed status item creation, AppState init crash, hotkey monitors
interfering, timing/race at launch (for synthetic clicks).

## Reproduction / test snippets used

```bash
# launch + logs
open ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug/OmWhisper.app
log show --last 1m --info --debug --predicate 'subsystem == "com.omwhisper.mac"' --style compact
```

```applescript
-- synthetic physical click at the item's true position (works 8/8)
tell application "System Events"
  set p to first process whose bundle identifier is "com.omwhisper.mac"
  set mi to menu bar item 1 of menu bar 2 of p
  set {x, y} to position of mi
  set {w, h} to size of mi
  click at {x + (w div 2), y + (h div 2)}
  delay 0.8
  count of menu items of menu 1 of mi -- errors if menu didn't open
end tell
```

## Suggested next steps for whoever picks this up

1. With the user present: quit the Tauri app AND Say No to Notch, relaunch the native
   app, have the user hover to identify the waveform icon and click it on the **Dell**
   menu bar. If that works, bisect: relaunch Say No to Notch → click again.
2. If still dead for real clicks only: add a temporary `NSEvent.addGlobalMonitorForEvents`
   log or an `AppDelegate`-level probe to see whether mouseDown ever reaches the app,
   and try an `NSStatusItem`-based spike (AppKit, no MenuBarExtra) to isolate SwiftUI.
3. Test the built-in display's menu bar copy of the icon explicitly (drag a window to
   make it the active display, real-click there).
4. Keep `.menuBarExtraStyle(.menu)` and `LSUIElement=YES` regardless — both are
   correct for this app and verified working for synthetic input.

## Repo state left behind

- Uncommitted: `OmWhisperApp.swift` (.menu + comment), `project.pbxproj`
  (LSUIElement=YES). Recommend committing — strictly better than HEAD.
- App process killed at user request. Old Tauri app also quit during testing.
- Accessibility permission still ungranted for the debug build.
