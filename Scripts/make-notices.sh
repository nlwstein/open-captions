#!/bin/bash
# Regenerates THIRD_PARTY_NOTICES.md from the header and the licence files of every resolved
# package, so the notices list exactly what is linked. Run after changing Package.resolved.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECKOUTS=.build/checkouts
[ -d "$CHECKOUTS" ] || swift package resolve
OUT=THIRD_PARTY_NOTICES.md

section() {  # title, file
  printf '### %s\n\n~~~~\n' "$1"
  cat "$2"
  printf '\n~~~~\n\n'
}

{
  cat Scripts/notices-header.md
  section "FluidAudio (Apache-2.0) — FluidInference" "$CHECKOUTS/FluidAudio/LICENSE"
  while IFS= read -r f; do
    section "FluidAudio bundles: ${f#"$CHECKOUTS"/FluidAudio/ThirdPartyLicenses/}" "$f"
  done < <(find "$CHECKOUTS/FluidAudio/ThirdPartyLicenses" -type f | sort)
  section "WhisperKit (MIT) — Argmax, Inc." "$CHECKOUTS/WhisperKit/LICENSE"
  section "WhisperKit third-party notices" "$CHECKOUTS/WhisperKit/NOTICES"
  section "swift-argument-parser (Apache-2.0) — Apple Inc. (test harness only, not in the app)" \
    "$CHECKOUTS/swift-argument-parser/LICENSE.txt"
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
