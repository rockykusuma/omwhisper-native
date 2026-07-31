# Release Publishing Automation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `bash scripts/build-release.sh --publish` carry a release all the way to a verified-live state — GitHub release, appcast on omwhisper.in, download button updated — and fail loudly if any of that did not actually happen.

**Architecture:** A new `scripts/publish-release.sh` owns preflight, publish and verify. `build-release.sh` calls its preflight *before* archiving and its publish/verify *after* the appcast is generated. Keeping them separate makes publishing re-runnable without repeating a ~10-minute notarization, and gives the verify stage a standalone `--verify-only` mode.

**Tech Stack:** Bash (`set -euo pipefail`), `gh` CLI, `git`, `curl`, Sparkle's `generate_appcast`.

## Global Constraints

- **Bash strict mode** in every script: `set -euo pipefail`. Match the existing style of `scripts/build-release.sh`.
- **`grep -o`, never `sed`, for parsing `<sparkle:version>`** — `sed` substitutes once per line, so several tags sharing a line report the last rather than the highest. This is already documented at `scripts/build-release.sh:54`.
- **A bare `build-release.sh` must remain non-publishing.** Default behaviour cannot change.
- **Web repo path:** `$OMWHISPER_WEB_REPO`, defaulting to `$PROJECT_ROOT/../omWhisperWebApp`.
- **Feed / site URLs:** `https://www.omwhisper.in/appcast.xml` and `https://www.omwhisper.in`. Note the `www.` — the apex issues a 307 redirect, so `curl` must use `-L` (it already does at `build-release.sh:53`).
- **Every verify failure exits non-zero.** A timeout is a failure, never a warning.
- No new dependencies. `gh`, `git` and `curl` are already required or present.

---

### Task 1: Verify stage and `--verify-only`

Built first because it is the only piece testable against reality *right now*: v2.0.4 is live, so a correct implementation must pass immediately, and a deliberately wrong expectation must fail. That positive/negative pair is the whole point — see `CLAUDE.md` § Verification.

**Files:**
- Create: `scripts/publish-release.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `preflight()` (Task 2), `publish()` (Task 3) hang off the same arg parser. `verify_release <build> <dmg_name>` returns 0/1.

- [ ] **Step 1: Create the script skeleton with arg parsing**

```bash
#!/usr/bin/env bash
# publish-release.sh — Take an already-built, notarized .dmg and make it live:
# GitHub release, appcast on omwhisper.in, download button, then PROVE it.
#
# Split from build-release.sh deliberately: notarization takes ~10 minutes, and
# a publish that fails at minute eleven must be re-runnable without repeating it.
# Every step here is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_ROOT/omwhisper-native.xcodeproj"
SCHEME="omwhisper-native"
BUILD_DIR="$PROJECT_ROOT/.build-release"

WEB_REPO="${OMWHISPER_WEB_REPO:-$PROJECT_ROOT/../omWhisperWebApp}"
FEED_URL="${FEED_URL:-https://www.omwhisper.in/appcast.xml}"
SITE_URL="${SITE_URL:-https://www.omwhisper.in}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-420}"

[ -f "$PROJECT_ROOT/.env" ] && { set -a; . "$PROJECT_ROOT/.env"; set +a; }

MODE="all"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verify-only)   MODE="verify" ;;
    --preflight-only) MODE="preflight" ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)       echo "usage: publish-release.sh [--verify-only|--preflight-only] [--dry-run]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

build_setting() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk -F' = ' "/ $1 /{print \$2; exit}"
}

VERSION="${VERSION:-$(build_setting MARKETING_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(build_setting CURRENT_PROJECT_VERSION)}"
DMG_NAME="${DMG_NAME:-OmWhisper_${VERSION}_$(uname -m).dmg}"
```

- [ ] **Step 2: Add the three live readers**

```bash
# ── Readers over what is actually deployed ───────────────────────────────────
# These read the live feed/site, never local variables. A local variable can
# only confirm what this script already believes.

live_feed_build() {
  curl -sSL --max-time 20 "$FEED_URL" 2>/dev/null \
    | grep -o '<sparkle:version>[0-9]\{1,\}</sparkle:version>' \
    | grep -o '[0-9]\{1,\}' | sort -n | tail -1
}

live_feed_dmg_url() {
  curl -sSL --max-time 20 "$FEED_URL" 2>/dev/null \
    | grep -o 'url="[^"]*\.dmg"' | sed 's/^url="//; s/"$//' | tail -1
}

# The site is a Vite SPA: the bundle name is content-hashed, so find it from
# index.html rather than guessing.
site_bundle_dmg() {
  local js
  js=$(curl -sSL --max-time 20 "$SITE_URL/" 2>/dev/null \
       | grep -o '/assets/index-[A-Za-z0-9_-]*\.js' | head -1)
  [ -n "$js" ] || return 1
  curl -sSL --max-time 20 "$SITE_URL$js" 2>/dev/null \
    | grep -o 'OmWhisper_[0-9.]*_[a-z0-9_]*\.dmg' | head -1
}
```

- [ ] **Step 3: Add `verify_release`**

```bash
verify_release() {
  local want_build="$1" want_dmg="$2"
  local deadline=$(( SECONDS + VERIFY_TIMEOUT ))
  local got_build got_dmg

  echo "Verifying against $SITE_URL (timeout ${VERIFY_TIMEOUT}s)..."
  while :; do
    got_build=$(live_feed_build || true)
    got_dmg=$(site_bundle_dmg || true)
    if [ -n "$got_build" ] && [ "$got_build" -ge "$want_build" ] 2>/dev/null \
       && [ "$got_dmg" = "$want_dmg" ]; then
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo ""
      echo "FAIL: not live after ${VERIFY_TIMEOUT}s."
      echo "  appcast build: ${got_build:-<none>} (wanted >= $want_build)"
      echo "  site download: ${got_dmg:-<none>} (wanted $want_dmg)"
      return 1
    fi
    printf '  feed=%s site=%s — waiting\n' "${got_build:-none}" "${got_dmg:-none}"
    sleep 15
  done
  echo "  ✓ appcast reports build $got_build"
  echo "  ✓ site download is $got_dmg"

  # Read the enclosure URL out of the DEPLOYED feed: that is the URL Sparkle
  # will fetch, and the only copy capable of disagreeing with this script.
  local url code
  url=$(live_feed_dmg_url || true)
  if [ -z "$url" ]; then
    echo "FAIL: live appcast has no .dmg enclosure URL"; return 1
  fi
  code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$url" || echo 000)
  if [ "$code" != "200" ]; then
    echo "FAIL: enclosure $url -> HTTP $code"; return 1
  fi
  echo "  ✓ enclosure downloads ($url)"
  return 0
}

if [ "$MODE" = "verify" ]; then
  verify_release "$BUILD_NUMBER" "$DMG_NAME"
  exit $?
fi
```

- [ ] **Step 4: Make it executable and run the positive control**

```bash
chmod +x scripts/publish-release.sh
bash scripts/publish-release.sh --verify-only
```
Expected: PASSES. v2.0.4 / build 5 is live, so all three checks succeed and it exits 0.

- [ ] **Step 5: Run the negative control — prove the check can fail**

```bash
BUILD_NUMBER=9999 VERIFY_TIMEOUT=30 bash scripts/publish-release.sh --verify-only; echo "exit=$?"
```
Expected: FAILS after ~30s with `appcast build: 5 (wanted >= 9999)` and `exit=1`.

A check that only ever passes proves nothing. Do not proceed until both controls behave as described.

- [ ] **Step 6: Commit**

```bash
git add scripts/publish-release.sh
git commit -m "✨ feat(release): verify a release is actually live, not just built"
```

---

### Task 2: Preflight

**Files:**
- Modify: `scripts/publish-release.sh`

**Interfaces:**
- Consumes: `WEB_REPO`, `PROJECT_ROOT` from Task 1.
- Produces: `preflight()`, invoked by `build-release.sh` in Task 4 via `--preflight-only`.

- [ ] **Step 1: Add `preflight`**

```bash
# ── Preflight ────────────────────────────────────────────────────────────────
# Runs BEFORE the build. Every check here is cheap and currently discovered
# after ten minutes of notarization.

repo_is_clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }
repo_branch()   { git -C "$1" rev-parse --abbrev-ref HEAD; }

preflight() {
  local ok=0

  if ! gh auth status >/dev/null 2>&1; then
    echo "✗ gh is not authenticated — run: gh auth login"; ok=1
  else echo "✓ gh authenticated"; fi

  # A dirty native tree is a correctness problem, not tidiness: gh release
  # create tags whatever commit is checked out, so publishing from a dirty
  # tree yields a tag that does not match the binary users download.
  if ! repo_is_clean "$PROJECT_ROOT"; then
    echo "✗ native repo has uncommitted changes — the tag would not match the build"; ok=1
  else echo "✓ native repo clean"; fi

  if [ ! -d "$WEB_REPO/.git" ]; then
    echo "✗ web repo not found at $WEB_REPO (set OMWHISPER_WEB_REPO)"; ok=1
  elif ! repo_is_clean "$WEB_REPO"; then
    echo "✗ web repo has uncommitted changes — publishing would sweep them up"; ok=1
  elif [ "$(repo_branch "$WEB_REPO")" != "main" ]; then
    echo "✗ web repo is on $(repo_branch "$WEB_REPO"), not main"; ok=1
  else echo "✓ web repo clean on main ($WEB_REPO)"; fi

  return $ok
}

if [ "$MODE" = "preflight" ]; then
  preflight
  exit $?
fi
```

Place this block **above** the `if [ "$MODE" = "verify" ]` guard from Task 1 so both mode guards sit together after all function definitions.

- [ ] **Step 2: Run the positive control**

```bash
bash scripts/publish-release.sh --preflight-only; echo "exit=$?"
```
Expected: all four ✓ lines, `exit=0`.

- [ ] **Step 3: Run the negative control**

```bash
touch "$PWD/scratch-preflight-probe"
bash scripts/publish-release.sh --preflight-only; echo "exit=$?"
rm -f "$PWD/scratch-preflight-probe"
```
Expected: `✗ native repo has uncommitted changes`, `exit=1`. (An untracked file makes `git status --porcelain` non-empty.)

- [ ] **Step 4: Commit**

```bash
git add scripts/publish-release.sh
git commit -m "✨ feat(release): preflight before the build, not after"
```

---

### Task 3: Publish

**Files:**
- Modify: `scripts/publish-release.sh`

**Interfaces:**
- Consumes: `VERSION`, `BUILD_NUMBER`, `DMG_NAME`, `BUILD_DIR`, `WEB_REPO`, `DRY_RUN`.
- Produces: `publish()`, called by the `all` mode path.

- [ ] **Step 1: Add `publish`**

```bash
# ── Publish ──────────────────────────────────────────────────────────────────
# Every step is idempotent: re-running after a verify timeout converges rather
# than duplicating a release or an asset.

run() {  # honour --dry-run for anything with outward-facing effect
  if [ "$DRY_RUN" = "1" ]; then echo "  [dry-run] $*"; else "$@"; fi
}

publish() {
  local tag="v$VERSION"
  local dmg="$BUILD_DIR/$DMG_NAME"
  [ -f "$dmg" ] || { echo "✗ .dmg not found at $dmg — run build-release.sh first"; return 1; }

  # 1 + 2. Release, then asset.
  if gh release view "$tag" >/dev/null 2>&1; then
    echo "Release $tag exists — reusing it."
  else
    local notes_file="$PROJECT_ROOT/docs/releases/$tag.md"
    if [ -f "$notes_file" ]; then
      echo "Creating $tag with notes from docs/releases/$tag.md"
      run gh release create "$tag" --title "OmWhisper $VERSION" --notes-file "$notes_file"
    else
      echo "Creating $tag with generated notes (no docs/releases/$tag.md)"
      run gh release create "$tag" --title "OmWhisper $VERSION" --generate-notes
    fi
  fi
  run gh release upload "$tag" "$dmg" --clobber

  # 3 + 4. Appcast into the web repo, which Vercel deploys on push. The site's
  # DOWNLOAD_URL is derived from this file at build time, so the download
  # button follows with no separate step.
  local src="$BUILD_DIR/appcast/appcast.xml"
  [ -f "$src" ] || { echo "✗ appcast not found at $src"; return 1; }
  run cp "$src" "$WEB_REPO/public/appcast.xml"

  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] commit + push $WEB_REPO"
  elif repo_is_clean "$WEB_REPO"; then
    echo "Web repo unchanged — appcast already current."
  else
    git -C "$WEB_REPO" add public/appcast.xml
    git -C "$WEB_REPO" commit -q -m "🔖 chore(appcast): OmWhisper $VERSION (build $BUILD_NUMBER)"
    git -C "$WEB_REPO" push -q origin main
    echo "✓ web repo pushed — Vercel deploying"
  fi
}
```

- [ ] **Step 2: Add the `all` mode path at the end of the file**

```bash
echo "Publishing OmWhisper $VERSION (build $BUILD_NUMBER)"
echo ""
preflight || exit 1
echo ""
publish   || exit 1
echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] skipping verification — nothing was published."
  exit 0
fi
verify_release "$BUILD_NUMBER" "$DMG_NAME" || exit 1
echo ""
echo "Released. $VERSION (build $BUILD_NUMBER) is live and verified."
```

- [ ] **Step 3: Test with `--dry-run`**

```bash
bash scripts/publish-release.sh --dry-run; echo "exit=$?"
```
Expected: preflight ✓ lines, then `[dry-run]` lines for the gh/cp/push calls, then the dry-run skip notice, `exit=0`. **Nothing is created on GitHub and nothing is pushed** — confirm with `gh release view v2.0.4 --json name` still showing only the existing release, and `git -C ../omWhisperWebApp status` still clean.

Note the `.dmg` check will fail here if `.build-release/` has been cleaned; that is correct behaviour and proves the guard works.

- [ ] **Step 4: Commit**

```bash
git add scripts/publish-release.sh
git commit -m "✨ feat(release): idempotent publish to GitHub and the website"
```

---

### Task 4: Wire into `build-release.sh`

**Files:**
- Modify: `scripts/build-release.sh` (arg parsing near line 15; preflight after line 39; publish at lines 260-265)

**Interfaces:**
- Consumes: `publish-release.sh`'s `--preflight-only` and default modes.
- Produces: `build-release.sh --publish`.

- [ ] **Step 1: Add arg parsing after the `cd "$PROJECT_ROOT"` line (line 15)**

```bash
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -h|--help) echo "usage: build-release.sh [--publish]"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
```

- [ ] **Step 2: Run preflight early — after the version banner (after line 39), before the build-number guard**

```bash
# Preflight before archiving: every check is cheap, and discovering a missing
# web repo or an expired gh token after a ten-minute notarization is the
# failure mode this ordering exists to prevent.
if [ "$PUBLISH" = "1" ]; then
  bash "$SCRIPT_DIR/publish-release.sh" --preflight-only || exit 1
  echo ""
fi
```

- [ ] **Step 3: Replace the closing reminder (lines 260-265) with the publish call**

Replace:
```bash
echo ""
echo "Next: upload $DMG_NAME to the GitHub release, and publish"
echo "$BUILD_DIR/appcast/appcast.xml at https://omwhisper.in/appcast.xml"
echo "(must match SUFeedURL in Info.plist)."
echo ""
echo "Done."
```

With:
```bash
echo ""
if [ "$PUBLISH" = "1" ]; then
  VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" DMG_NAME="$DMG_NAME" \
    bash "$SCRIPT_DIR/publish-release.sh"
else
  echo "Built, not published. To release this build:"
  echo "  bash scripts/publish-release.sh"
  echo "Or re-run with --publish to do both in one command."
  echo ""
  echo "Done."
fi
```

The non-publish branch still tells you what to do next, but it now names a **runnable command that verifies itself** rather than a checklist of manual steps.

- [ ] **Step 4: Verify argument handling without building**

```bash
bash scripts/build-release.sh --help; echo "exit=$?"
bash scripts/build-release.sh --bogus; echo "exit=$?"
```
Expected: usage line then `exit=0`; then `unknown argument: --bogus` and `exit=2`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-release.sh
git commit -m "✨ feat(release): build-release.sh --publish goes end to end"
```

---

### Task 5: Document the flow

**Files:**
- Modify: `docs/RELEASE_SETUP.md`
- Create: `docs/releases/.gitkeep`

- [ ] **Step 1: Create the release-notes directory so the convention is discoverable**

```bash
mkdir -p docs/releases
printf 'Hand-written release notes: vX.Y.Z.md, picked up by scripts/publish-release.sh.\nAbsent means gh --generate-notes is used instead.\n' > docs/releases/README.md
```

- [ ] **Step 2: Add a "Cutting a release" section to `docs/RELEASE_SETUP.md`**

Document, in this order: the one-command flow (`bash scripts/build-release.sh --publish`); that `OMWHISPER_WEB_REPO` goes in `.env` if the web repo is not a sibling directory; that `docs/releases/vX.Y.Z.md` supplies notes when present; that `scripts/publish-release.sh` can be re-run on its own if publishing fails after a successful build; and that `--verify-only` answers "is what's live actually consistent?" at any time.

State plainly that publishing **refuses to run from a dirty tree in either repo**, and why: the tag must match the binary.

- [ ] **Step 3: Update the M5 row in `CLAUDE.md`**

Record that release publishing is now one command with live verification, that the site's `DOWNLOAD_URL` derives from the appcast rather than being pinned, and — the fact worth keeping — that **omwhisper.in served 2.0.0 for four releases** because the closing reminder was an instruction that could not fail.

- [ ] **Step 4: Commit**

```bash
git add docs/RELEASE_SETUP.md docs/releases/README.md CLAUDE.md
git commit -m "📝 docs: one-command release flow"
```

---

## Self-review

**Spec coverage.** §3 preflight → Task 2 (all five checks; build-number guard and Sparkle-binary check already exist in `build-release.sh` and are explicitly left in place). §4 publish, all four steps → Task 3. §5 verify, all three checks → Task 1. §2 decisions: two-script split (Tasks 1/4), unchanged default (Task 4 Step 3), notes fallback (Task 3 Step 1), `OMWHISPER_WEB_REPO` (Task 1 Step 1), idempotency (Task 3 Step 1).

**Placeholders.** None — every step carries runnable code or, in Task 5 Step 2, an explicit list of what the prose must state.

**Type consistency.** `verify_release <build> <dmg>`, `preflight`, `publish`, `run`, `repo_is_clean <dir>`, `repo_branch <dir>` are used with the same arity everywhere. `repo_is_clean` is defined in Task 2 and reused by `publish` in Task 3 — Task 3 must therefore land after Task 2, which the ordering enforces.

**One ordering hazard to respect:** Task 2 Step 1 says to place the preflight mode guard beside the verify guard from Task 1, after all function definitions. Bash executes top to bottom, so a mode guard sitting above a function definition would call an undefined function. Keep all `if [ "$MODE" = ... ]` blocks together near the end.
