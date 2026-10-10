#!/usr/bin/env python3
"""Writes Fixtures/annotations/<name>.txt — one speaker label per line of the reference.

Speaker identity is the one piece of ground truth this repo had and threw away. The AMI corpus
records it (one file per participant, `ES2002a.<A|B|C|D>.words.xml`) and `ami_annotations.py` parses
it; the synthetic fixtures know it per line (the `$VOICE_X|ms|text` heredocs in make-fixtures.sh).
Both drop it before the reference is committed, because the reference format is plain text with no
room for a second column.

Rather than change the reference format, the labels are written to a sibling file with exactly one
label per reference line. That keeps the existing alignment machinery (reference tokens to hypothesis
tokens) usable for speaker scoring, since line *i* of the annotation belongs to line *i* of the
reference by construction.

The label is an opaque group id, not a name: `B` for AMI means the corpus's speaker B, `C` for
family-dinner means the `$VOICE_C` voice. Nothing downstream should read meaning into it — the
question the metric asks is only whether two turns were grouped together, and whether that grouping
matches the truth.

Provenance, since neither source is committed:

  AMI        .fixture-build/ami/turns.txt, itself written by `ami_annotations.py turns` from the
             corpus at .corpora/ami/words/. Regenerate the corpus checkout with
             Scripts/make-ami-fixtures.sh before re-running this.
  synthetic  the heredocs in Scripts/make-fixtures.sh, which are committed.

Usage: python3 Scripts/speaker_annotations.py [--check]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Fixtures"
ANNOTATIONS = FIXTURES / "annotations"
AMI_TURNS = ROOT / ".fixture-build" / "ami" / "turns.txt"
MAKE_FIXTURES = ROOT / "Scripts" / "make-fixtures.sh"

AMI_FIXTURES = ["ami-meeting", "ami-meeting-far", "ami-meeting-synth"]

# `render_lines "doctor-visit" 165 <<LINES` … `LINES`
HEREDOC = re.compile(r'render_lines\s+"([^"]+)"[^\n]*<<(\w+)\n(.*?)\n\s*\2\b', re.DOTALL)
# `$VOICE_B|4300|Your blood pressure is 148 over 92 today.`
HEREDOC_LINE = re.compile(r"^\$VOICE_([A-Z])\|(\d+)\|(.*)$")


def reference_lines(name: str) -> list[str]:
    path = FIXTURES / "reference" / f"{name}.txt"
    if not path.exists():
        raise SystemExit(f"missing reference: {path}")
    return [line for line in path.read_text().splitlines() if line.strip()]


def ami_labels(name: str) -> list[str]:
    if not AMI_TURNS.exists():
        raise SystemExit(
            f"missing {AMI_TURNS}. It is gitignored; run Scripts/make-ami-fixtures.sh to rebuild it."
        )
    labels = []
    for line in AMI_TURNS.read_text().splitlines():
        parts = line.split("|")
        if len(parts) < 4 or not parts[3].strip():
            continue
        labels.append(parts[2])
    return labels


def synthetic_labels(name: str) -> list[str]:
    script = MAKE_FIXTURES.read_text()
    for fixture, _, body in HEREDOC.findall(script):
        if fixture != name:
            continue
        labels = []
        for line in body.splitlines():
            match = HEREDOC_LINE.match(line.strip())
            if match:
                labels.append(match.group(1))
        return labels
    raise SystemExit(f"no render_lines heredoc for '{name}' in {MAKE_FIXTURES}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the committed files match the sources instead of writing them.",
    )
    args = parser.parse_args()

    ANNOTATIONS.mkdir(parents=True, exist_ok=True)
    names = sorted(p.stem for p in (FIXTURES / "reference").glob("*.txt"))
    failures = 0

    for name in names:
        reference = reference_lines(name)
        labels = ami_labels(name) if name in AMI_FIXTURES else synthetic_labels(name)

        # The whole scheme rests on this: one label per reference line, in the same order. If a
        # source ever drifts, the annotation would silently mislabel every line after the drift.
        if len(labels) != len(reference):
            print(
                f"{name}: {len(labels)} labels for {len(reference)} reference lines — SKIPPED",
                file=sys.stderr,
            )
            failures += 1
            continue

        path = ANNOTATIONS / f"{name}.txt"
        if args.check:
            committed = path.read_text().splitlines() if path.exists() else []
            if committed != labels:
                print(f"{name}: annotations are stale", file=sys.stderr)
                failures += 1
            continue

        path.write_text("\n".join(labels) + "\n")
        speakers = sorted(set(labels))
        print(f"{name}: {len(labels)} lines, {len(speakers)} speaker(s) {speakers}")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
