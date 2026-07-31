# Release Setup — from zero to a notarized .dmg

One-time setup, then `scripts/build-release.sh` does the rest.

Team ID: **`Y87BZN47C5`**.

**Status (2026-07-31): the distribution chain works end to end.** Certificate, signing,
export, .dmg, notarization (`status: Accepted`, submission
`d6bf9113-b5d0-45e0-bfdd-7a876f3b9095`) and stapling all succeed. The notarized artifact is
`OmWhisper_2.0.0_arm64.dmg`, SHA-256
`165f74d5c7666aa16e996a464c45e9feb5fd3e9146ff408b9290f2c259195548`.

Outstanding: **step 2** (back up the private key — still the one irreversible item),
**step 7** (Sparkle key, before any .dmg is distributed), and a real Gatekeeper test on a
machine that has it enabled (see below).

---

## 1. Create the Developer ID Application certificate

This is the certificate that lets macOS run the app on someone else's machine without
Gatekeeper blocking it. The "Apple Development" certificate already in your keychain
**cannot** do this — it only works on machines registered to your account.

**Do it through Xcode, not the portal.** Xcode generates the keypair, submits the signing
request, and installs the result in one step; the portal route makes you create a CSR by
hand in Keychain Access and re-import the result, which is where people usually go wrong.

1. **Xcode → Settings → Accounts**
2. Select your Apple ID, pick the team, click **Manage Certificates…**
3. Click **+** (bottom left) → **Developer ID Application**
4. Wait for it to appear in the list, then close.

You need the **Account Holder** or **Admin** role on the team. A solo paid account is the
Account Holder by default, so this should just work.

Verify — this must print a line containing `Developer ID Application`:

```bash
security find-identity -v -p codesigning | grep "Developer ID"
```

Copy that identity string exactly, including the team ID in parentheses. It looks like:

```
Developer ID Application: Your Name (Y87BZN47C5)
```

> **If the + menu doesn't offer "Developer ID Application"**: you're either not the Account
> Holder/Admin, or the team already holds the maximum number of these certificates. Check
> developer.apple.com → Certificates. Do **not** revoke an existing one to make room without
> being certain nothing else signs with it — revoking breaks updates for anything already
> shipped with it.

## 2. Back up BOTH private keys — do this immediately

Two keys now exist, both only in your login keychain, **neither re-issuable**:

| Key | If lost |
|---|---|
| Developer ID Application | Can't sign anything users will run |
| Sparkle EdDSA | No user can ever verify an update — a new key is rejected by existing installs |

A disk failure today costs you the ability to update every copy you ever ship. `*.p12`,
`*.pem` and `*private*key*` are gitignored as a safety net, but these do not belong in the
repo at all.

### 2a. Developer ID → .p12

Use Keychain Access, not `security export` — the CLI has no way to export a single identity
and would dump all of them.

1. Open **Keychain Access** (⌘Space → "Keychain Access")
2. Sidebar **login**, then the **My Certificates** category
3. Select **Developer ID Application: Arunbharath Reddy Keshapalli (Y87BZN47C5)**
   — expand the triangle and confirm a private key sits underneath it. No key, nothing to back up.
4. Right-click → **Export "Developer ID Application: …"**
5. File Format **Personal Information Exchange (.p12)**, choose a location
6. Set a strong **export password** — this encrypts the .p12. Store it with the file.
7. Enter your **macOS login password** when prompted to release the key from the keychain

Verify the export really contains both halves:

```bash
# the right certificate?
openssl pkcs12 -in omwhisper-developer-id.p12 -nokeys -passin pass:'YOUR_EXPORT_PASSWORD' \
  | openssl x509 -noout -subject
# and the private key? should print BEGIN ... PRIVATE KEY
openssl pkcs12 -in omwhisper-developer-id.p12 -nocerts -passin pass:'YOUR_EXPORT_PASSWORD' \
  -passout pass:temp | grep -m1 PRIVATE
```

### 2b. Sparkle EdDSA → text file

```bash
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_keys -maxdepth 1 | head -1)
"$SPARKLE_BIN" -x ~/Desktop/omwhisper-sparkle-private-key.txt
```

Approve the keychain prompt. The file is **plaintext** — its contents are exactly the password
of the "Private key for signing Sparkle updates" keychain item. Move it into secure storage
and delete it from disk; don't leave it on the Desktop.

Verify it matches the key that's actually shipping:

```bash
"$SPARKLE_BIN" -p    # must print KWxanNe25QRF/+jZypGqO+K9s3Cp30ptU8YOrmBgvgY=
```

### 2c. Store them

Both files plus the .p12 export password, in a password manager (as file attachments) or an
encrypted disk image, with at least one copy **off this machine**.

### Restoring on a new Mac

- **Developer ID**: double-click the .p12, enter the export password.
- **Sparkle**: `generate_keys -f <exported-file>`. Remove any existing "Private key for
  signing Sparkle updates" item in Keychain Access first, or the import is refused.

## 3. Create an app-specific password for notarization

Notarization uploads the .dmg to Apple. It authenticates as your Apple ID, but your real
password won't work — it needs an app-specific one.

1. Sign in at **appleid.apple.com**
2. **Sign-In and Security → App-Specific Passwords → +**
3. Name it something like `omwhisper-notarize`
4. Copy the generated password (format `xxxx-xxxx-xxxx-xxxx`). It is shown **once**.

## 4. Write `.env`

In the repo root — it is gitignored (verify with `git check-ignore -v .env`):

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (Y87BZN47C5)"
APPLE_ID="your-apple-id@example.com"
APPLE_ID_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # the app-specific password from step 3
APPLE_TEAM_ID="Y87BZN47C5"
```

`APPLE_SIGNING_IDENTITY` must match `security find-identity` output **character for
character** — a trailing space or a smart quote fails with a confusing "no identity found".

If `APPLE_ID_PASSWORD` is omitted the script still builds and signs, and just skips
notarization. That's a useful way to test step 5 in isolation.

## 5. Run it

```bash
bash scripts/build-release.sh
```

Archive → export → .dmg → notarize → staple → Gatekeeper check. Notarization takes 1–5
minutes. Output lands in `.build-release/` (gitignored) as `OmWhisper_2.0.0_arm64.dmg`.

### Status of the unsigned-of-notarization dry run (2026-07-31)

**Archive → sign → export → .dmg is proven.** `OmWhisper_2.0.0_arm64.dmg` (10.2 MB) built
successfully with notarization skipped. Confirmed on the exported app:

- `Authority=Developer ID Application: … (Y87BZN47C5)` chaining to Apple Root CA
- `flags=0x10000(runtime)` — hardened runtime on
- `codesign --verify --deep --strict` passes, including the embedded Sparkle framework
- **`SUFeedURL` and `NSAudioCaptureUsageDescription` both survive into Release** — the
  PlistBuddy patch phase was the biggest open risk and it works
- `AppIcon.icns` present, entitlements carry `com.apple.security.device.audio-input`
- After notarization: `stapler validate` passes on the .dmg, and the enclosed app assesses as
  `source=Notarized Developer ID`

**Two caveats found while verifying, neither blocking:**

1. **Gatekeeper assessments are disabled on this machine** (`spctl --status: assessments
   disabled`), so `spctl --assess` returns "accepted" for anything and the script's tick
   proved nothing. The script now warns when that's the case. `source=Notarized Developer ID`
   *is* meaningful — it reflects real notarization state — but a true Gatekeeper test needs
   `sudo spctl --master-enable` or another Mac.
2. **The ticket is stapled to the .dmg, not the enclosed .app.** An app dragged to
   /Applications carries no ticket and is verified online at first launch. Normal for .dmg
   distribution and fine for anyone online, which is the usual case for a fresh download. If
   offline first-launch ever has to work, notarize and staple the .app first, then rebuild
   the .dmg from it and notarize that too.

The first run did fail, twice, both fixed in the script:

- `GRDB_GRDB … requires a development team` — SPM package targets have no team of their own
- `conflicting provisioning settings … automatically signed, but code signing identity …
  manually specified`

`CODE_SIGN_IDENTITY` alone caused both. The archive step now also passes
`CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM`, and an empty
`PROVISIONING_PROFILE_SPECIFIER` (Developer ID macOS apps aren't provisioned), which settles
it for every target while leaving the checked-in project on automatic signing for normal
development.

### What may still go wrong once notarization is on

- **"No signing certificate found"** — `APPLE_SIGNING_IDENTITY` doesn't exactly match
  step 1's output.
- **Notarization rejected** — run `xcrun notarytool log <submission-id> --apple-id … ` to get
  the actual reason. Usual causes: an embedded framework not signed with the same identity,
  or a binary missing the hardened runtime. Sparkle and the CoreML/WhisperKit frameworks are
  the likely candidates, since they've never been through this.

Re-check the injected Info.plist keys after any change to the patch build phase — without
`NSAudioCaptureUsageDescription`, meeting recording silently captures nothing, with no prompt
and no error:

```bash
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" \
  .build-release/export/OmWhisper.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :NSAudioCaptureUsageDescription" \
  .build-release/export/OmWhisper.app/Contents/Info.plist
```

## 6. Install it fresh and actually use it

The point of the first .dmg isn't the file — it's that installing it closes several things
that have never been verified on a real build:

- The app has an **icon** in /Applications and the Dock
- **Onboarding** runs on a clean `hasCompletedOnboarding` (never tested on a fresh flag)
- The **single-instance guard** in its real case: launch the /Applications copy while a
  `~/Downloads` copy is running
- **TCC permissions** on a notarized Release build — mic, Accessibility, and audio capture
  are all granted per-binary, and a Developer ID build is a different binary identity from
  the dev build
- A real dictation cycle end to end

## 7. Sparkle — DONE 2026-07-31

Key generated, `SUPublicEDKey` shipping in the binary, appcast generated and signed.

- Public key: `KWxanNe25QRF/+jZypGqO+K9s3Cp30ptU8YOrmBgvgY=`
- Injected via the same PlistBuddy phase as `SUFeedURL` (`INFOPLIST_KEY_SUPublicEDKey`),
  since `GENERATE_INFOPLIST_FILE` drops third-party keys. Verified present inside the
  notarized .dmg, not just in a Debug build.
- `build-release.sh` now runs Sparkle's own `generate_appcast`, which signs the archive with
  the private key from the login keychain and writes `.build-release/appcast/appcast.xml`.

⚠️ **The private key is in your login keychain and nowhere else.** Lose it and no user can
ever verify an update again — the only recovery is shipping a new public key, which existing
installs will reject. Export it now and store it with the .p12 from step 2:

```bash
<sparkle-bin>/generate_keys -x sparkle_private_key.txt   # then move it somewhere safe
```

Remaining before a release actually goes out: the `enclosure url` in the generated appcast
defaults to `https://omwhisper.in/<dmg>` — make sure the .dmg is actually served from there
(or edit the URL to the GitHub release asset), and publish `appcast.xml` at
`https://omwhisper.in/appcast.xml` to match `SUFeedURL`.

### Original notes

Auto-update is currently inert: `SUFeedURL` points at `https://omwhisper.in/appcast.xml`,
but no `SUPublicEDKey` is in the Info.plist and no appcast exists.

**The public key is baked into the shipped binary.** Ship 2.0 without it and every 2.0
install is permanently un-updatable — the only fix is asking users to re-download by hand.
So this must happen before the first .dmg is distributed, not after.

1. Generate the keypair with Sparkle's `generate_keys` (from the Sparkle SPM checkout under
   `~/Library/Developer/Xcode/DerivedData/…/SourcePackages/artifacts/sparkle/`). The private
   key goes into your **login keychain** — back it up like step 2; losing it means no user can
   ever verify an update again.
2. Add the printed public key as `SUPublicEDKey` — via the existing PlistBuddy patch phase,
   the same way `SUFeedURL` is injected, since `GENERATE_INFOPLIST_FILE` drops it otherwise.
3. Rebuild, then sign the .dmg with `sign_update` and put the resulting signature in
   `appcast.xml`.
4. Publish `appcast.xml` at `omwhisper.in/appcast.xml`.

Still to do in the script: a `generate_appcast`/`sign_update` step, and a DMG volume icon
(the disk image currently mounts with a generic one).
