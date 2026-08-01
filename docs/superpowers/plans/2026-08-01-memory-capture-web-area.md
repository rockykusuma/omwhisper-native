# Memory Capture — Web Area — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Memory captures page content instead of the whole window, so snapshots stop being 58% browser chrome. Per `docs/superpowers/specs/2026-08-01-memory-capture-web-area-design.md`.

**Architecture:** `BrowserURL`'s existing private `AXWebArea` finder is generalised to return the element and made internal. `WindowSnapshotReader` walks that subtree when one exists, the window root otherwise. An empty web area skips the snapshot rather than falling back to chrome.

**Tech Stack:** Swift 6 (MainActor-by-default), ApplicationServices (AX), Swift Testing.

## Global Constraints

- Both files are already `nonisolated` — AX calls are cross-process IPC with no MainActor affinity. Keep them that way.
- **Never capture more chrome than today.** Every change here either narrows what is captured or leaves it identical.
- The AX walk cannot be unit-tested (it needs a live tree). The existing suite staying green is the regression proof; the real verification is the measurement in Task 3.
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`.
- Commit style: emoji conventional commits. Continue on the current `memory-semantic-search` worktree branch — this change is what makes that feature worth having, and they verify together.

---

### Task 1: Generalise the web-area finder

**Files:**
- Modify: `omwhisper-native/Memory/BrowserURL.swift`

**Interfaces:**
- Produces: `BrowserURL.findWebArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement?` — internal (not private), so `WindowSnapshotReader` can call it.
- Changes: `findWebAreaURL` is replaced by `findWebArea` + a URL read at the call site. `url(bundleId:window:)` keeps its exact behaviour and signature.
- Consumes: nothing new.

This is a pure refactor — `BrowserURLTests` must pass unchanged, which is what proves the URL path didn't move.

- [ ] **Step 1: Replace the finder**

In `BrowserURL.swift`, replace `findWebAreaURL` with:

```swift
    /// The first AXWebArea in this window's tree, if any.
    ///
    /// Internal rather than private: WindowSnapshotReader targets its text walk
    /// at this subtree so Memory captures page content instead of the sidebar
    /// and tab strip (see the web-area capture spec). One finder, two callers.
    ///
    /// Not browser-only in practice — Electron apps (Teams, Slack, VS Code,
    /// Claude) expose a web area too, which is why no allowlist is involved.
    static func findWebArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if (copyAttribute(element, kAXRoleAttribute) as? String) == "AXWebArea" {
            return element
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = findWebArea(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The AXURL of the window's web area, if it has one.
    private static func webAreaURL(_ window: AXUIElement) -> String? {
        guard let area = findWebArea(window), let url = copyAttribute(area, "AXURL") else { return nil }
        if let cfURL = url as? URL { return cfURL.absoluteString }
        if let s = url as? String, !s.isEmpty { return s }
        return nil
    }
```

In `url(bundleId:window:)`, change `findWebAreaURL(window, depth: 0)` to `webAreaURL(window)`.

- [ ] **Step 2: Prove the refactor changed nothing**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/BrowserURLTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, same count as before the change.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Memory/BrowserURL.swift
git commit -m "♻️ refactor(memory): web-area finder returns the element, for a second caller"
```

---

### Task 2: Target the text walk at the web area

**Files:**
- Modify: `omwhisper-native/Memory/WindowSnapshotReader.swift`

**Interfaces:**
- Consumes: Task 1's `BrowserURL.findWebArea`.
- Produces: no API change — `captureFrontmost` keeps its signature and return type.

- [ ] **Step 1: Change what the walk starts from**

In `captureFrontmost`, replace the block that runs `collectText` from `windowElement`:

```swift
        var lines: [String] = []
        var budget = 50_000
        let deadline = Date().addingTimeInterval(timeBudget)
        ScreenContextReader.collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
```

with:

```swift
        // Walk the page, not the window. Measured on the real store, 58% of a
        // median Arc snapshot was sidebar and pinned-tab chrome -- indexing that
        // buried the actual content and produced search hits like
        // "Footer (c) 2026 GitHub, Inc.". Any app exposing a web area benefits,
        // including Electron ones; native apps find none and behave as before.
        let webArea = BrowserURL.findWebArea(windowElement)
        var lines: [String] = []
        var budget = 50_000
        let deadline = Date().addingTimeInterval(timeBudget)
        ScreenContextReader.collectText(webArea ?? windowElement, depth: 0,
                                        into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // A web area that yielded nothing means a page mid-load, a canvas app or
        // a PDF viewer. Skip the tick rather than falling back to the window
        // walk: a snapshot that is 100% chrome is worse than no snapshot, and
        // the 5s poll retries almost immediately.
        if webArea != nil, content.isEmpty {
            snapshotLog.debug("web area empty, skipping tick: \(app.localizedName ?? bundleID, privacy: .public)")
            return nil
        }
```

Leave the existing `guard !content.isEmpty` block below it untouched — that path still handles native apps and still escalates the Electron accessibility flag, which must keep working for apps whose web area isn't exposed yet.

- [ ] **Step 2: Full build + suite**

Run the full-suite command.
Expected: TEST SUCCEEDED, same count as before (no test covers the AX walk; this proves nothing else moved).

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Memory/WindowSnapshotReader.swift
git commit -m "✨ feat(memory): capture the page, not the window chrome"
```

---

### Task 3: Measure it — the exit criterion

The spec's exit criterion is a number, not a claim: the Arc boilerplate share must fall
substantially from today's **58% median**. This task is how that gets established.

- [ ] **Step 1: Record the baseline from existing rows**

```bash
DEV=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
sqlite3 -noheader "$DEV" "SELECT MAX(id) FROM snapshots;"   # note this: the cutoff
```

Everything at or below that id is pre-change; everything above is post-change. Without the
cutoff the two populations mix and the measurement means nothing.

- [ ] **Step 2: Rebuild, relaunch, and browse for a few minutes**

```bash
osascript -e 'tell application id "com.omwhisper.mac.dev" to quit' 2>/dev/null
DD=$(xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug 2>/dev/null | grep -m1 "  BUILT_PRODUCTS_DIR" | sed 's/.*= //')
open "$DD/OmWhisper-Dev.app"
```

Then use Arc normally for a few minutes so at least ~30 new Arc snapshots accumulate. Fewer
than that and the document-frequency measure is noise.

- [ ] **Step 3: Compare old rows against new**

```bash
DEV=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
CUTOFF=<the id from Step 1>
for RANGE in "id <= $CUTOFF" "id > $CUTOFF"; do
  sqlite3 -noheader "$DEV" "SELECT replace(content,char(10),' ') FROM snapshots WHERE appName='Arc' AND $RANGE;" > /tmp/arc_rows.txt
  python3 - <<'PY'
import collections, statistics
lines=[l.strip() for l in open('/tmp/arc_rows.txt') if l.strip()]
if len(lines) < 5:
    print(f"  only {len(lines)} rows — not enough to measure"); raise SystemExit
docs=[l.split() for l in lines]
df=collections.Counter()
for d in docs:
    for t in set(d): df[t]+=1
boiler={t for t,c in df.items() if c > 0.7*len(docs)}
shares=[sum(1 for t in d if t in boiler)/len(d) for d in docs if d]
print(f"  rows={len(docs)} boilerplate_tokens={len(boiler)} median_share={statistics.median(shares)*100:.0f}%")
PY
done
```

Expected: the first block (old rows) reproduces roughly **58%**; the second block (new rows)
is substantially lower. **If it is not, the change did not work** — say so plainly and reopen
the native-app options the spec put out of scope, rather than declaring victory.

- [ ] **Step 4: Confirm the downstream effect**

Re-run a semantic query that previously surfaced chrome and check the matched passage is now
real page text. The passages for new snapshots are indexed automatically by the capture hook,
so this needs no extra step beyond letting the indexer catch up.

- [ ] **Step 5: Record the measured result**

Append the before/after numbers to the spec's exit-criterion section and commit. A spec that
says "should improve" is worth less than one that says what actually happened.
