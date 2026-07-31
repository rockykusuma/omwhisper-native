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
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" \
    && echo "✓ Gatekeeper: accepted" || echo "✗ Gatekeeper check failed"

  DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
  echo ""
  echo "Notarized SHA-256: $DMG_SHA256"
else
  echo "Skipping notarization (APPLE_ID / APPLE_ID_PASSWORD / APPLE_TEAM_ID not set)."
  echo "  Team ID is Y87BZN47C5 — set APPLE_ID and an app-specific APPLE_ID_PASSWORD to notarize."
fi

echo ""
echo "Upload $DMG_NAME to the GitHub release, then update omwhisper.in/appcast.xml"
echo "(Sparkle feed) and version.json with the new $VERSION. Appcast entries need"
echo "an EdDSA signature — sign_update from Sparkle's SPM checkout, once the"
echo "signing key exists (not generated yet — see CLAUDE.md)."
echo ""
echo "Done."
