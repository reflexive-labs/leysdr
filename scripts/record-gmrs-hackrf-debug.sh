#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Configure the reproducible HackRF/GMRS case, wait for a keyed transmitter, and copy the
# completed recording into the repository so it is visible from the development container.
set -euo pipefail

cd "$(dirname "$0")/.."

duration="${LEY_GMRS_DURATION:-10s}"
frequency_hz="${LEY_GMRS_FREQUENCY_HZ:-462612500}"
sample_rate="${LEY_GMRS_SAMPLE_RATE:-20000000}"
channel=""

command -v ley >/dev/null 2>&1 || {
  echo "ley is not on PATH; build it and add go/bin to PATH first" >&2
  exit 1
}
if [[ ! -t 0 ]]; then
  echo "this test is interactive; run it from a terminal" >&2
  exit 1
fi

cleanup() {
  if [[ -n "$channel" ]]; then
    ley stop "$channel" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "==> Configuring HackRF at ${frequency_hz} Hz, ${sample_rate} samples/s"
tune_output="$(ley tune "$frequency_hz" \
  --mode nfm \
  --bw 20 \
  --rate "$sample_rate" \
  --squelch -69 \
  --no-audio \
  --persistent)"
printf '%s\n' "$tune_output"

channel="$(printf '%s\n' "$tune_output" | awk '$1 == "channel" { print $2; exit }')"
if [[ ! "$channel" =~ ^chan_ ]]; then
  echo "could not find the created channel id in ley tune output" >&2
  exit 1
fi

ley set gain 0 --element LNA --channel "$channel"
ley set gain 6 --element VGA --channel "$channel"
ley set gain 0 --element AMP --channel "$channel"

echo
echo "Ready to make a ${duration} recording on GMRS channel 3."
read -r -p "Hold PTT, then press Return and keep transmitting until recording finishes: " _

echo "==> Recording"
recording_uri="$(ley record "$channel" --for "$duration")"
recording_uri="$(printf '%s\n' "$recording_uri" | tail -n 1)"
if [[ "$recording_uri" != ley://recordings/* ]]; then
  echo "ley record did not return a recording URI: $recording_uri" >&2
  exit 1
fi

recording_dir="$(ley recordings path "$recording_uri")"
if [[ ! -d "$recording_dir" ]]; then
  echo "recording directory does not exist: $recording_dir" >&2
  exit 1
fi

largest=0
for path in tmp/gmrs-debug*; do
  [[ -e "$path" ]] || continue
  suffix="${path##*gmrs-debug}"
  if [[ "$suffix" =~ ^[0-9]+$ ]] && (( suffix > largest )); then
    largest="$suffix"
  fi
done
destination="tmp/gmrs-debug$((largest + 1))"
mkdir -p "$destination"
cp -R "$recording_dir/." "$destination/"

audio_file="$(find "$destination" -maxdepth 1 -type f -name '*.wav' -print -quit)"
echo
echo "Copied the completed recording to $destination"
if [[ -n "$audio_file" ]]; then
  echo "Audio: $audio_file"
fi
