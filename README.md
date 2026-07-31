# OmWhisper

Menu-bar dictation for macOS. Hold a key, speak, and the text lands in whatever app you're
in — with your choice of on-device or cloud transcription, and optional AI cleanup.

**[Download OmWhisper 2.0](https://github.com/rockykusuma/omwhisper-native/releases/latest)**
· [omwhisper.in](https://www.omwhisper.in)

Requires **macOS 26 (Tahoe) or later** on **Apple Silicon**. Signed and notarized.

Windows users: the previous [Tauri build](https://github.com/rockykusuma/omwhisper) remains
available and is now frozen.

## Using it

- **⌘⇧V** starts and stops dictation; **hold Fn** to push-to-talk
- **⌘⇧B** dictates and cleans the text up with AI before pasting
- **⌘⇧P** polishes whatever text you currently have selected

macOS asks for Microphone and Speech Recognition the first time you dictate, and for
Accessibility the first time OmWhisper pastes — that last one is what lets text land in
another app.

## Where your audio goes

Four transcription engines, switchable at any time. The sidebar always names the one that
will actually run and whether it stays on your Mac:

| Engine | Runs |
|---|---|
| Apple Speech *(default)* | On device — streaming, words appear as you speak |
| Parakeet | On device — CoreML, multilingual or English-only |
| Whisper | On device — the widest language coverage |
| Cloud | AssemblyAI · Deepgram · ElevenLabs · OpenAI · Groq, with your own key |

AI polish is off by default and offers the same choice: Apple Foundation Models (on device),
Ollama (local), or any OpenAI-compatible API. Text sent to a cloud provider is scrubbed of
secrets and personal data first — keys, tokens, cards, emails, phone numbers — and restored
in the result. If polish fails for any reason, your raw text is pasted rather than lost.

Meeting recording, memory, reply assist, cross-lingual dictation and the MCP server are all
opt-in and off by default. See [the privacy policy](https://www.omwhisper.in/privacy) for
what each one stores.

## Building

The Xcode scheme is **`omwhisper-native`**, not `OmWhisper` — the product name and the scheme
name differ, and using the wrong one fails with "does not contain a scheme named".

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test
```

Needs Xcode with the macOS 26 SDK. Release builds (archive → notarize → `.dmg` → appcast) come
from `scripts/build-release.sh` and need a paid Apple Developer account — see
`docs/RELEASE_SETUP.md` for the one-time signing setup.

## Why a rewrite

macOS 26's SpeechTranscriber and Foundation Models replace roughly 60% of the Tauri app's
codebase: on-device streaming transcription, VAD and LLM polish become API calls rather than
hand-rolled pipelines. `docs/NATIVE_MIGRATION_PLAN.md` has the full rationale, architecture
and feature-parity checklist; `CLAUDE.md` has the project context and milestone history.

## License

See [`LICENSE`](LICENSE).
