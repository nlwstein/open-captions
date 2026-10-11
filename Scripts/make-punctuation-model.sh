#!/usr/bin/env bash
#
# Builds the punctuation model into .models/punctuation, once. The app bundles it from there and
# the Mac tests load it from there; it is not committed (50 MB) and not downloaded by the app.
#
#   Scripts/make-punctuation-model.sh [--force]
#
# Needs uv. The first run fetches the original model (about 200 MB) and a Python conversion stack
# (about 1 GB, cached by uv) and takes a minute or two. See Scripts/punctuation_model.py.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO}/.models/punctuation"

if [[ "${1:-}" != "--force" && -d "${OUT}/Punctuation.mlpackage" && -s "${OUT}/vocabulary.tsv" ]]; then
  exit 0
fi
command -v uv >/dev/null || { echo "uv is needed to build the punctuation model: https://docs.astral.sh/uv/" >&2; exit 1; }

echo "Building the punctuation model into ${OUT#"${REPO}/"}…"
rm -rf "${OUT}.part"
uv run --quiet --no-project "${REPO}/Scripts/punctuation_model.py" "${OUT}.part"
rm -rf "${OUT}"
mv "${OUT}.part" "${OUT}"
