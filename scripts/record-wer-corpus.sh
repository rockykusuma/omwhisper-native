#!/usr/bin/env bash
# record-wer-corpus.sh — record a WER corpus in your own voice, your room, your mic.
#
# The synthetic corpus (make-wer-corpus.sh) answers "do these engines differ?".
# It cannot answer "how accurate is MY dictation", because `say` produces clean,
# unaccented, close-mic'd speech with no disfluency and no room. This script
# produces the only corpus whose numbers predict what you actually experience.
#
# Interactive: it prints a sentence, you read it aloud, it saves the audio beside
# the exact text as the reference. Use the mic you really dictate with — a corpus
# recorded on a headset says nothing about your laptop mic.
#
# Every take is CHECKED before it is accepted: a recording whose peak never rises
# above room tone is offered back for a retake rather than silently scored. A
# corpus of silence would report a catastrophic WER and look like an engine bug,
# which is the expensive way to discover the mic was muted.
set -euo pipefail

OUT="${1:-}"
DEVICE="${2:-:default}"
MAXSEC=90          # hard ceiling per take; RETURN stops it long before this
MIN_PEAK_DB=-40    # speech peaks around -20..-6 dB; room tone sits below -45
MIN_SECONDS=1.0

if [ -z "$OUT" ]; then
  cat >&2 <<USAGE
usage: record-wer-corpus.sh <output-dir> [ffmpeg-avfoundation-device]

  <output-dir>  created if missing; existing takes are kept and skipped
  [device]      default ":default". Available inputs:
USAGE
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n '/AVFoundation audio devices/,$p' | sed -n '2,20p' | sed 's/^.*\] /                /' >&2
  echo >&2
  echo "  Pick the mic you actually dictate with, e.g. \":2\" for MacBook Pro Microphone." >&2
  exit 2
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

peak_db() { # prints the take's peak level, or "" if ffmpeg can't read it
  ffmpeg -hide_banner -i "$1" -af volumedetect -f null - 2>&1 \
    | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p' | head -1
}
duration_s() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1
}
# "speech" / "silent" / "unreadable" — the whole judgement in one place so it can
# be tested without a microphone. Run: record-wer-corpus.sh --self-check
classify() {
  local peak; peak="$(peak_db "$1")"
  [ -z "$peak" ] && { echo unreadable; return; }
  if awk "BEGIN{exit !($peak < $MIN_PEAK_DB)}"; then echo silent; else echo speech; fi
}

if [ "${1:-}" = "--self-check" ]; then
  tmp="${TMPDIR:-/tmp}/wer-selfcheck.$$"; mkdir -p "$tmp"; trap 'rm -rf "$tmp"' EXIT
  ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 2 -y "$tmp/silent.wav"
  say -o "$tmp/speech.wav" --data-format=LEI16@16000 "This is what a real take sounds like."
  fail=0
  for want in silent speech; do
    got="$(classify "$tmp/$want.wav")"
    [ "$got" = "$want" ] && echo "  ok   $want.wav → $got ($(peak_db "$tmp/$want.wav") dB)" \
                         || { echo "  FAIL $want.wav → $got, expected $want"; fail=1; }
  done
  got="$(classify "$tmp/does-not-exist.wav")"
  [ "$got" = unreadable ] && echo "  ok   missing file → unreadable" \
                          || { echo "  FAIL missing file → $got"; fail=1; }
  exit $fail
fi

mkdir -p "$OUT"

record() {
  local name="$1" text="$2"
  if [ -f "$OUT/$name.wav" ] && [ -f "$OUT/$name.txt" ]; then
    echo "  ✓ $name — already recorded, skipping (delete the .wav to redo)"
    return
  fi
  while :; do
    printf '\n\033[1m--- %s ---\033[0m\n%s\n\n' "$name" "$text"
    printf 'RETURN to start recording… '
    read -r _ </dev/tty
    ffmpeg -hide_banner -loglevel error -f avfoundation -i "$DEVICE" \
           -t "$MAXSEC" -ac 1 -ar 16000 -y "$OUT/$name.wav" </dev/null &
    local pid=$!
    sleep 0.4   # avfoundation takes a moment to open; don't clip the first word
    printf '\033[31m●\033[0m recording — read it aloud, then press RETURN… '
    read -r _ </dev/tty
    kill -INT "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    local peak dur verdict
    peak="$(peak_db "$OUT/$name.wav")"
    dur="$(duration_s "$OUT/$name.wav")"
    verdict="$(classify "$OUT/$name.wav")"
    if [ "$verdict" = unreadable ] || [ -z "$dur" ]; then
      echo "  ✗ could not read the take back. Retaking."
      continue
    fi
    # A take that never rose above room tone is a muted mic or the wrong device,
    # not a quiet reader — accepting it would poison every engine's score equally
    # and read as an engine failure.
    if [ "$verdict" = silent ]; then
      echo "  ✗ peak ${peak} dB — that is room tone, not speech. Wrong device, or muted?"
      printf '    r = retake, s = skip this sample, k = keep anyway: '
      read -r ans </dev/tty
      case "$ans" in k|K) ;; s|S) rm -f "$OUT/$name.wav"; return;; *) continue;; esac
    elif awk "BEGIN{exit !($dur < $MIN_SECONDS)}"; then
      echo "  ✗ only ${dur}s — stopped too early. Retaking."
      continue
    else
      printf '  ✓ %ss, peak %s dB. RETURN to keep, r to retake: ' "${dur%.*}" "$peak"
      read -r ans </dev/tty
      case "$ans" in r|R) continue;; esac
    fi
    printf '%s' "$text" > "$OUT/$name.txt"
    return
  done
}

cat <<INTRO

Recording a WER corpus into: $OUT
Device: $DEVICE

Read each sentence naturally, at your normal dictation pace and distance.
Do NOT over-enunciate — the point is to measure your real speech, and a
carefully-articulated corpus flatters every engine equally and predicts nothing.
If you fluff a word, retake it: the .txt must be exactly what you said.

INTRO

# Sentences are non-repeating prose. A corpus built by repeating one sentence is
# pathological for ASR — every engine looks far worse and the fixture, not the
# engine, is what gets measured. They also deliberately CONTAIN the vocabulary
# terms below: a vocabulary benchmark whose corpus lacks the words the engine
# gets wrong measures nothing, which this project has now learned twice.
record 01-prose        "Let me know if you want me to send over the updated draft before the meeting tomorrow afternoon."
record 02-jargon       "I pushed the appcast to Vercel and the notarize step finally passed on the first try."
record 03-code         "The SwiftUI settings pane calls an async throwing stream, so the buffer conversion has to stay off the main actor."
record 04-engines      "We swapped WhisperKit for Parakeet before OmWhisper starts, and the transcription got noticeably better."
record 05-work         "The firmware team found that the hearing aid drops the GATT connection whenever Auracast slicing is enabled."
record 06-conversational "Honestly I think we should just ship it and see what happens, because waiting another week is not going to make it any better."
record 07-longer       "I spent most of the morning trying to work out why the update never reached anyone, and it turned out the download link had been pointing at an old version for weeks. Once that was fixed, everything else fell into place and the rest of the afternoon was straightforward."
record 08-numbers      "The build takes about four minutes on this machine and the whole suite runs six hundred and thirty eight tests in ninety five suites."
record 09-disfluent    "So, um, what I was going to say is that the meeting detection thing, it just never fired for the Teams call, and I had to record it by hand."
record 10-mixed        "Please review the pull request and let me know whether the approach makes sense before I merge it into the main branch."

# Terms an engine plausibly gets wrong. Present so the harness can run each engine
# twice — biasing off, then on — and so the post-processing columns have something
# to correct. Without these files the run measures raw engine output only.
cat > "$OUT/vocabulary.txt" <<'VOCAB'
# Terms the engines actually get wrong on this corpus. A vocabulary benchmark
# whose corpus lacks these words measures nothing at all.
appcast
Vercel
notarize
SwiftUI
WhisperKit
Parakeet
OmWhisper
async
Auracast
GATT
VOCAB

cat > "$OUT/replacements.txt" <<'REPL'
# from -> to. These are the splits fuzzyCorrect structurally cannot reach: it
# walks whitespace-delimited tokens and never crosses a space, so "app cast"
# arriving as two words is uncorrectable there.
app cast -> appcast
whisper kit -> WhisperKit
swift ui -> SwiftUI
om whisper -> OmWhisper
REPL

n=$(ls "$OUT"/*.wav 2>/dev/null | wc -l | tr -d ' ')
words=$(cat "$OUT"/*.txt 2>/dev/null | grep -v '^#' | wc -w | tr -d ' ')
cat <<DONE

Wrote $n samples (~$words reference words, vocabulary.txt and replacements.txt included) to
  $OUT

Run the benchmark (Debug build):
  OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev --wer $OUT

Numbers from this corpus describe YOUR speech on YOUR mic. They are not
comparable with the synthetic runs in docs/wer-corpus/README.md, which are a
floor — record-and-read is harder input than \`say\` produces, so expect worse
absolute numbers and trust the ranking between engines.
DONE
