#!/usr/bin/env bash
# build-release.sh — Archive, notarize, and package OmWhisper (native) as a distributable .dmg.
# macOS only. Requires Xcode, a Developer ID Application certificate, and a paid Apple
# Developer account for notarization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_ROOT/omwhisper-native.xcodeproj"
SCHEME="omwhisper-native"
BUILD_DIR="$PROJECT_ROOT/.build-release"
ARCHIVE_PATH="$BUILD_DIR/OmWhisper.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

cd "$PROJECT_ROOT"

# Load .env if present (APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_ID_PASSWORD, APPLE_TEAM_ID)
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

echo "╔════════════════════════════════════╗"
echo "║   OmWhisper Native Release Builder  ║"
echo "╚════════════════════════════════════╝"
echo ""

# MARKETING_VERSION from build settings, not a file: the target uses
# GENERATE_INFOPLIST_FILE, so omwhisper-native/Info.plist does not exist on disk
# and reading it silently yielded "unknown" — which would have shipped a .dmg
# named OmWhisper_unknown_arm64.dmg.
VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
VERSION=${VERSION:-unknown}
echo "Version:  $VERSION"
echo "Arch:     $(uname -m)"
echo ""

if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  echo "ERROR: APPLE_SIGNING_IDENTITY is not set."
  echo "  export APPLE_SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
  echo "  Find yours: security find-identity -v -p codesigning | grep 'Developer ID'"
  exit 1
fi
echo "Signing: $APPLE_SIGNING_IDENTITY"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Archive ──────────────────────────────────────────────────────────────────
echo "Archiving..."
# CODE_SIGN_IDENTITY alone is not enough and fails two ways: the targets are set
# to automatic signing, which Xcode refuses to combine with a manually specified
# identity, and the SPM package targets (GRDB, Sparkle, ...) have no team of
# their own, so they fail with "requires a development team". Passing the style
# and team on the command line settles both for every target in the build, and
# leaves the checked-in project on automatic signing for normal development.
# PROVISIONING_PROFILE_SPECIFIER is deliberately empty: Developer ID macOS apps
# are not provisioned, and an inherited value would be looked up and fail.
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-Y87BZN47C5}" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  2>&1 | tee "$BUILD_DIR/archive.log" | grep -E "Compiling|Archiving|Finished|error|warning: unused" | tail -30

# ── Export (Developer ID, direct distribution) ──────────────────────────────
echo ""
echo "Exporting signed .app..."
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID:-Y87BZN47C5}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${APPLE_SIGNING_IDENTITY}</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: export did not produce a .app in $EXPORT_DIR"
  exit 1
fi
echo ".app path: $APP_PATH"

# ── Package into a .dmg ──────────────────────────────────────────────────────
echo ""
echo "Packaging .dmg..."
DMG_NAME="OmWhisper_${VERSION}_$(uname -m).dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create -volname "OmWhisper" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│                Release Artifacts                     │"
echo "├─────────────────────────────────────────────────────┤"
printf "│ Version:  %-43s│\n" "$VERSION"
printf "│ DMG:      %-43s│\n" "$DMG_NAME"
printf "│ Size:     %-43s│\n" "$DMG_SIZE"
printf "│ SHA-256:  %-43s│\n" "${DMG_SHA256:0:43}"
printf "│           %-43s│\n" "${DMG_SHA256:43}"
echo "└─────────────────────────────────────────────────────┘"
echo ""
echo "DMG path: $DMG_PATH"
echo ""

# ── Notarization ─────────────────────────────────────────────────────────────
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_ID_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "Notarizing DMG (this takes 1–5 minutes)..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo ""
  echo "Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"

  echo ""
  echo "Verifying Gatekeeper acceptance..."
  # spctl --assess returns "accepted" for everything when assessments are off,
  # so the check below is a false green on a machine with Gatekeeper disabled.
  # Say so rather than printing a tick that means nothing.
  if ! spctl --status 2>/dev/null | grep -q "assessments enabled"; then
    echo "⚠️  Gatekeeper assessments are DISABLED on this machine — the check below"
    echo "    proves nothing. Re-enable with 'sudo spctl --master-enable', or verify"
    echo "    on another Mac, before trusting it."
  fi
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" \
    && echo "✓ Gatekeeper: accepted" || echo "✗ Gatekeeper check failed"

  # The ticket is stapled to the .dmg, not to the .app inside it, so the app a
  # user drags to /Applications carries no ticket of its own and Gatekeeper
  # verifies it online on first launch. Fine when online, which is the normal
  # case for something just downloaded. Staple the .app too (a second notarize
  # pass on the .app, then rebuild the .dmg from it) if offline first-launch
  # ever needs to work.
  echo ""
  echo "Note: ticket stapled to the .dmg. The enclosed .app verifies online on"
  echo "      first launch — see scripts comment if offline launch must work."

  DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
  echo ""
  echo "Notarized SHA-256: $DMG_SHA256"
else
  echo "Skipping notarization (APPLE_ID / APPLE_ID_PASSWORD / APPLE_TEAM_ID not set)."
  echo "  Team ID is Y87BZN47C5 — set APPLE_ID and an app-specific APPLE_ID_PASSWORD to notarize."
fi

# ── Appcast (Sparkle) ────────────────────────────────────────────────────────
# generate_appcast signs each archive with the EdDSA private key from the login
# keychain and writes/updates appcast.xml in the same directory. Using Sparkle's
# own tool rather than hand-writing XML: it owns the signature format, delta
# generation, and pruning of old entries.
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
  -name generate_appcast -maxdepth 1 2>/dev/null | head -1)

if [ -n "$SPARKLE_BIN" ]; then
  echo ""
  echo "Generating appcast..."
  # Only the .dmg should be fed to it — the exported .app and staging copies
  # would otherwise be picked up as separate "updates".
  APPCAST_DIR="$BUILD_DIR/appcast"
  mkdir -p "$APPCAST_DIR"
  cp "$DMG_PATH" "$APPCAST_DIR/"
  # Without an explicit prefix, generate_appcast derives the download URL from
  # the app's own SUFeedURL — i.e. it would point users at the website for a
  # binary the website doesn't host. The .dmg lives on GitHub Releases; the
  # site serves only appcast.xml. Override DOWNLOAD_URL_PREFIX if that changes.
  DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/rockykusuma/omwhisper-native/releases/download/v${VERSION}/}"
  PRODUCT_LINK="${PRODUCT_LINK:-https://www.omwhisper.in}"
  # Regenerate from scratch: generate_appcast updates entries in place, so a
  # stale URL in an existing appcast.xml would survive a prefix change.
  rm -f "$APPCAST_DIR/appcast.xml"
  if "$SPARKLE_BIN" \
       --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
       --link "$PRODUCT_LINK" \
       "$APPCAST_DIR" 2>&1 | tail -5; then
    echo "appcast.xml: $APPCAST_DIR/appcast.xml"
  else
    echo "⚠️  appcast generation failed — check that the Sparkle signing key exists"
    echo "    (generate_keys -p should print a public key)."
  fi
else
  echo ""
  echo "⚠️  Sparkle's generate_appcast not found — build once in Xcode so SPM"
  echo "    resolves the Sparkle artifact, then re-run."
fi

echo ""
echo "Next: upload $DMG_NAME to the GitHub release, and publish"
echo "$BUILD_DIR/appcast/appcast.xml at https://omwhisper.in/appcast.xml"
echo "(must match SUFeedURL in Info.plist)."
echo ""
echo "Done."
