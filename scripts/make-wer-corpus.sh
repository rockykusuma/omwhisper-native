#!/usr/bin/env bash
# make-wer-corpus.sh — synthesize a WER corpus with macOS `say`.
#
# Gives every engine identical, perfectly-labelled input in seconds, with no
# recording session. Use it to smoke-test the harness and to compare engines
# against each other.
#
# It does NOT tell you what your dictation accuracy will be. Synthetic speech
# is clean, unaccented, close-mic'd, and free of disfluency, so every engine
# scores far better here than on real dictation. Treat these numbers as a
# floor and a relative ranking, never as a claim about real-world accuracy.
# For that, record yourself — see docs/wer-corpus/README.md.
set -euo pipefail

OUT="${1:-}"
if [ -z "$OUT" ]; then
  echo "usage: make-wer-corpus.sh <output-dir>" >&2
  exit 2
fi
mkdir -p "$OUT"

write() {
  printf '%s' "$2" > "$OUT/$1.txt"
  # LEI16 wav: `say` refuses little-endian float in an AIFF container.
  say -o "$OUT/$1.wav" --data-format=LEI16@22050 "$2"
}

write 01-prose "Let me know if you want me to send over the updated draft before the meeting tomorrow afternoon."
write 02-technical "The transcription engine returns an async throwing stream of partial and final events."
write 03-code "Open the settings view and check whether the audio capture buffer is being converted correctly."
write 04-longer "I spent most of the morning trying to work out why the update never reached anyone, and it turned out the download link had been pointing at an old version for weeks. Once that was fixed everything else fell into place."
write 05-conversational "Honestly I think we should just ship it and see what happens, because waiting another week is not going to make it better."
write 06-mixed "Please review the pull request and let me know if the approach makes sense before I merge it into the main branch."

echo "Wrote $(ls "$OUT"/*.wav | wc -l | tr -d ' ') samples to $OUT"
echo "Run: OmWhisper --wer $OUT   (Debug build)"
