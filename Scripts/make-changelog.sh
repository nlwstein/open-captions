#!/bin/bash
# Write the commit history the app's changelog is made from. Parsed by Changelog.swift.
#
#   Scripts/make-changelog.sh OUT
#
# Run by the Xcode build (App/project.yml) straight into the app bundle, so every build carries
# the history it was built from. Records are separated by RS (0x1E), fields by US (0x1F):
# full hash, committer date (ISO 8601), subject. Without git or history it writes an empty file,
# and the app says it has no changelog rather than failing to build.
set -euo pipefail
out=${1:?usage: make-changelog.sh OUT}
cd "$(dirname "$0")/.."
if git rev-parse --git-dir >/dev/null 2>&1; then
  git log --no-merges --format='%H%x1f%cI%x1f%s%x1e' > "$out"
else
  : > "$out"
fi
