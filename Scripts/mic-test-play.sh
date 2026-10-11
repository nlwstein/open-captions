#!/usr/bin/env bash
# Loops one recording out of the Mac's speakers, for the app's microphone test.
#
#   Scripts/mic-test-play.sh <audio file> [volume 0-1, default 0.6]
#
# Put the Mac where the far talker would be, and set the phone's "Each setup" to the clip's length
# (printed below) so every setup hears the whole clip once. Stop with Ctrl-C. Score the results
# with Scripts/mic-test-score.py.
set -euo pipefail
file="${1:?usage: mic-test-play.sh <audio file> [volume]}"
volume="${2:-0.6}"
seconds=$(afinfo "$file" | awk '/estimated duration/ {printf "%d", $3 + 0.999}')
echo "clip is ${seconds}s; set Each setup to at least ${seconds}s. Ctrl-C to stop."
while true; do
  afplay -v "$volume" "$file"
done
