# OmWhisper

Free, offline-capable voice-to-text for macOS — a menu-bar dictation app with your choice of
local (on-device) or cloud transcription and AI polish backends.

This is the **native Swift rewrite** (v2.0) of OmWhisper, built on macOS 26's SpeechTranscriber
and Foundation Models APIs. It supersedes the original Tauri/Rust app at
[rockykusuma/omwhisper](https://github.com/rockykusuma/omwhisper), which is now frozen
(bug-fix-only) and remains the release for Windows users.

## Status

Early build — see `docs/NATIVE_MIGRATION_PLAN.md` for the milestone plan (M0–M5) and
`CLAUDE.md` for full project context.

## Requirements

- macOS 26 or later
- Apple Silicon
- Xcode with the macOS 26 SDK

## Build

```bash
# Build + run in Xcode, or from the command line:
xcodebuild -scheme OmWhisper -project omwhisper-native.xcodeproj build test
```

Release builds (archive → notarize → `.dmg`) are produced by `scripts/build-release.sh` and
require a paid Apple Developer account. See that script and `CLAUDE.md` for the required
environment variables.

## Why a rewrite

macOS 26 system APIs (SpeechTranscriber, Foundation Models) replace roughly 60% of the Tauri
app's codebase — on-device streaming transcription, VAD, and LLM polish become API calls
instead of hand-rolled pipelines. See `docs/NATIVE_MIGRATION_PLAN.md` for the full rationale,
architecture, and feature-parity checklist.

## License

See `LICENSE`.
