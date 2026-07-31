#!/usr/bin/env bash
# publish-release.sh — Take an already-built, notarized .dmg and make it live:
# GitHub release, appcast on omwhisper.in, download button — then PROVE it.
#
# Split from build-release.sh deliberately: notarization takes ~10 minutes, and
# a publish that fails at minute eleven must be re-runnable without repeating
# it. Every step here is idempotent.
#
# This script exists because build-release.sh used to END by printing a
# reminder to do these steps by hand. A printed reminder cannot fail and
# cannot be observed — and it was ignored: omwhisper.in served 2.0.0 for four
# consecutive releases. See docs/superpowers/specs/2026-08-01-release-publish-automation-design.md
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

# An `if` block, not `[ -f x ] && { ...; }`: under `set -e` the latter exits
# the whole script when .env is absent, because the && chain returns non-zero.
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROJECT_ROOT/.env"
  set +a
fi

MODE="all"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verify-only)    MODE="verify" ;;
    --preflight-only) MODE="preflight" ;;
    --dry-run)        DRY_RUN=1 ;;
    -h|--help)
      echo "usage: publish-release.sh [--verify-only|--preflight-only] [--dry-run]"
      exit 0 ;;
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
  # A wrong --download-url-prefix is invisible to every other check here.
  local url code
  url=$(live_feed_dmg_url || true)
  if [ -z "$url" ]; then
    echo "FAIL: live appcast has no .dmg enclosure URL"
    return 1
  fi
  code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$url" || echo 000)
  if [ "$code" != "200" ]; then
    echo "FAIL: enclosure $url -> HTTP $code"
    return 1
  fi
  echo "  ✓ enclosure downloads ($url)"
  return 0
}

# ── Preflight ────────────────────────────────────────────────────────────────
# Runs BEFORE the build. Every check here is cheap, and discovering a missing
# web repo or an expired gh token after a ten-minute notarization is the
# failure mode this ordering exists to prevent.

repo_is_clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }
repo_branch()   { git -C "$1" rev-parse --abbrev-ref HEAD; }

preflight() {
  local ok=0

  # `gh api user`, not `gh auth status`: status exits non-zero if ANY configured
  # account has a stale token, even when the active one is fine. This machine
  # has three accounts and one expired, so the status check reported failure
  # while every real gh command worked. Making an authenticated call tests the
  # thing we actually depend on.
  local who
  if ! who=$(gh api user -q .login 2>/dev/null); then
    echo "✗ gh cannot authenticate to the API — run: gh auth login"; ok=1
  else
    echo "✓ gh authenticated as $who"
  fi

  # A dirty native tree is a correctness problem, not tidiness: gh release
  # create tags whatever commit is checked out, so publishing from a dirty
  # tree yields a tag that does not match the binary users download — and
  # nothing downstream would ever reveal it.
  if ! repo_is_clean "$PROJECT_ROOT"; then
    echo "✗ native repo has uncommitted changes — the tag would not match the build"; ok=1
  else
    echo "✓ native repo clean"
  fi

  if [ ! -d "$WEB_REPO/.git" ]; then
    echo "✗ web repo not found at $WEB_REPO (set OMWHISPER_WEB_REPO)"; ok=1
  elif ! repo_is_clean "$WEB_REPO"; then
    echo "✗ web repo has uncommitted changes — publishing would sweep them up"; ok=1
  elif [ "$(repo_branch "$WEB_REPO")" != "main" ]; then
    echo "✗ web repo is on $(repo_branch "$WEB_REPO"), not main"; ok=1
  else
    echo "✓ web repo clean on main ($WEB_REPO)"
  fi

  return $ok
}

# ── Mode guards ──────────────────────────────────────────────────────────────
# Kept together, below every function definition: bash executes top to bottom,
# so a guard placed above a definition would call an undefined function.

if [ "$MODE" = "preflight" ]; then
  preflight
  exit $?
fi

if [ "$MODE" = "verify" ]; then
  verify_release "$BUILD_NUMBER" "$DMG_NAME"
  exit $?
fi
