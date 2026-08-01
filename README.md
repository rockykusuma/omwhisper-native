<div align="center">

<img src="omwhisper-native/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="OmWhisper">

# OmWhisper

**Hold a key. Speak. The text lands where you're typing.**

Menu-bar dictation for macOS, with your choice of on-device or cloud transcription.

[![Release](https://img.shields.io/github/v/release/rockykusuma/omwhisper-native?color=0FA97C&label=release)](https://github.com/rockykusuma/omwhisper-native/releases/latest)
[![Platform](https://img.shields.io/badge/macOS%2026%2B-Apple%20Silicon-0E7490)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-0FA97C.svg)](./LICENSE)

**[⬇️ Download](https://github.com/rockykusuma/omwhisper-native/releases/latest)** ·
[🌐 omwhisper.in](https://www.omwhisper.in) ·
[📖 Documentation](https://www.omwhisper.in/docs) ·
[🔒 Privacy](https://www.omwhisper.in/privacy)

</div>

---

Most dictation apps pick a side: everything on your device (private, but limited), or everything
in the cloud (accurate, but your audio is someone else's problem). OmWhisper lets you choose per
engine, and always tells you which one is about to run.

Out of the box, your audio never leaves your Mac. Point it at a cloud provider with your own API
key and it will — after scrubbing secrets and personal data out of anything sent for AI cleanup.
The app itself only ever phones home to check for updates.

## Requirements

**macOS 26 (Tahoe) or later**, on **Apple Silicon**. Signed with a Developer ID and notarized.
macOS only — there is no Windows build.

## Install

Download the `.dmg` from [Releases](https://github.com/rockykusuma/omwhisper-native/releases/latest),
drag OmWhisper to Applications, and launch it. A first-run walkthrough handles permissions and
lets you try a dictation before anything is pasted anywhere. Updates arrive in-app via Sparkle.

macOS asks for **Microphone** and **Speech Recognition** the first time you dictate, and for
**Accessibility** the first time OmWhisper pastes — that last one is what lets text land in
another app.

## Using it

| | |
|---|---|
| **Hold Fn** | Talk, release when done. This is how most people use it. The key is configurable. |
| **⌘⇧V** | Toggle dictation instead — press once to start, again to stop |
| **⌘⇧B** | Dictate, then clean the text up with AI before pasting |
| **⌘⇧P** | Polish whatever text you currently have selected, in place |
| **⌘⇧D** | Brain dump — ramble, get back something structured |
| **Double-tap right ⌥** | Draft a reply from what's on screen *(off by default)* |

Text is pasted into the frontmost app and your clipboard is restored afterwards. Release-to-paste
measured between 108 ms and 697 ms across nine runs on an M-series Mac.

## Where your audio goes

Four transcription engines, switchable at any time. The sidebar always names the one that will
actually run and whether it leaves your Mac.

| Engine | Runs | Words appear |
|---|---|---|
| **Apple Speech** *(default)* | On device | While you speak |
| **Parakeet** | On device — CoreML, multilingual or English-only | While you speak |
| **Whisper** | On device — the widest language coverage | On release |
| **Cloud** | AssemblyAI · Deepgram · ElevenLabs · OpenAI · Groq | Varies by provider |

Cloud engines need your own API key, which is stored in the macOS Keychain — never in preferences.
Custom vocabulary biases every engine toward the words you actually use.

## AI cleanup

Optional, off by default. Removes filler, fixes self-corrections, applies a style — seven built in,
plus your own.

| Backend | Runs |
|---|---|
| **Apple Foundation Models** | On device |
| **Ollama** | Locally, against any model you've pulled |
| **OpenAI-compatible API** | The provider you choose |

Text bound for a cloud provider is scrubbed first — keys, tokens, cards, emails, phone numbers are
replaced with placeholders and restored in the result. **If cleanup fails for any reason, your raw
text is pasted rather than lost.**

## Beyond dictation

Every one of these is **off by default** and stays off until you turn it on. See the
[privacy policy](https://www.omwhisper.in/privacy) for what each one stores.

| | |
|---|---|
| **Meetings** | Records calls after an on-screen consent prompt, then transcribes, diarizes and summarizes them entirely on device — editable notes, summary templates, and export |
| **Memory** | Periodically notes what's on screen so you can search it later, with a daily written chronicle |
| **Reply assist** | Double-tap right ⌥ to draft a reply from the conversation in front of you |
| **Cross-lingual** | Speak one language, get polished English out |
| **MCP server** | Exposes your history, memory and meetings to Claude Desktop as read-only tools |

## Development

The Xcode scheme is **`omwhisper-native`**, not `OmWhisper` — the product name and the scheme name
differ, and using the wrong one fails with "does not contain a scheme named".

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test
```

Needs Xcode with the macOS 26 SDK. Dependencies resolve through SPM automatically. Release builds
(archive → notarize → `.dmg` → appcast) come from `scripts/build-release.sh` and need a paid Apple
Developer account — see [`docs/RELEASE_SETUP.md`](docs/RELEASE_SETUP.md) for the one-time setup.

| Layer | Technology |
|---|---|
| UI | SwiftUI + AppKit (`NSStatusItem`, non-activating `NSPanel`, `CGEventTap`) |
| State | One `@Observable` `AppState` |
| Transcription | SpeechAnalyzer · FluidAudio (Parakeet) · WhisperKit · streaming WebSocket + REST |
| AI cleanup | Foundation Models · Ollama · OpenAI-compatible |
| Storage | SQLite via GRDB, with FTS5 |
| Updates | Sparkle |

Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so anything touching audio callbacks is
explicitly `nonisolated` — `CLAUDE.md` covers that and the rest of the project's conventions.

## Why native

OmWhisper is built directly on what macOS 26 provides — SpeechTranscriber for streaming on-device
transcription, Foundation Models for on-device cleanup — instead of bundling its own pipelines.
That is what keeps it a small, fast, single-binary app that starts instantly and asks for nothing
it doesn't need.

## License

MIT — see [`LICENSE`](LICENSE).
