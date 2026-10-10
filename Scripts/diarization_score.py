#!/usr/bin/env python3
"""Scores a diarizer's speaker labels against the fixtures' annotations.

Speaker grouping is the app's only visual structure, so "the diarizer looks about right" is not a
usable answer — a colour that is wrong some of the time is worse than no colour, because the reader
cannot tell which turns to distrust. This turns a diarizer's output into one number per fixture.

The ground truth is the same one the tests use: `Fixtures/annotations/<name>.txt`, one opaque
speaker label per reference line, with the times for those lines in the fixture build directory.
That pairing matters — the annotation file says *who* and the build output says *when*, and they are
in the same order by construction, which `speaker_annotations.py --check` enforces.

Accuracy is reported after the best possible relabelling of the diarizer's speakers. Diarizers emit
arbitrary cluster ids (`Speaker 0`, `SPEAKER_01`) with no relationship to the truth labels, so
comparing them directly would measure nothing. Choosing the best of the 24 possible mappings for a
4-speaker fixture is the standard fix and it is generous to the diarizer on purpose: the number this
produces is an upper bound on what a perfect label assignment could achieve.

The mapping is chosen once per fixture over the whole file, not per turn. A per-turn best mapping
would score 100% for any diarizer that found the right number of clusters, which is the failure mode
this script exists to avoid.

Usage:
  uv run -I Scripts/diarization_score.py <truth-fixture> <diarizer-output.txt> [--fixture-window]

  The diarizer output is the text form printed by FluidAudio's `lseend` command:
      Speaker 0: 0.10s - 21.80s (21.70s)
  and `--fixture-window` is only needed if the file carries corpus-time stamps rather than times
  relative to the clip (FluidAudio's output is already clip-relative, so the default is 0.0).
"""

from __future__ import annotations

import argparse
import itertools
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / ".fixture-build"

SEGMENT = re.compile(
    r"(?:Speaker|SPEAKER)[ _]?(\d+)\s*[:\s]\s*([\d.]+)\s*s?\s*[-–]\s*([\d.]+)\s*s?", re.IGNORECASE
)


def load_truth(fixture: str) -> list[tuple[float, float, str]]:
    """(start, end, speaker) per reference line, in clip-relative seconds."""
    annotations = ROOT / "Fixtures" / "annotations" / f"{fixture}.txt"
    turns_file = BUILD / "ami" / "turns.txt"
    if not annotations.exists():
        raise SystemExit(f"no annotations for {fixture} at {annotations}")
    if not turns_file.exists():
        raise SystemExit(
            f"no turn timings at {turns_file} — they are written by Scripts/make-ami-fixtures.sh, "
            "which must be re-run to regenerate the build directory"
        )

    labels = [line.strip() for line in annotations.read_text().splitlines() if line.strip()]
    rows = [row for row in turns_file.read_text().splitlines() if row.strip()]
    # Only rows with a speaker survive into the reference file, so the filter must match the one
    # speaker_annotations.py applied or the two lists drift apart silently.
    timed = [row.split("|") for row in rows if len(row.split("|")) >= 4 and row.split("|")[3].strip()]
    if len(labels) != len(timed):
        raise SystemExit(
            f"{fixture}: {len(labels)} annotations vs {len(timed)} timed turns — "
            "the two are out of step; re-run Scripts/speaker_annotations.py"
        )

    offset = clip_start()
    return [
        (float(parts[0]) - offset, float(parts[1]) - offset, label)
        for parts, label in zip(timed, labels)
    ]


def clip_start() -> float:
    match = re.search(
        r"^CLIP_START=([\d.]+)",
        (ROOT / "Scripts" / "make-ami-fixtures.sh").read_text(),
        re.MULTILINE,
    )
    if not match:
        raise SystemExit("no CLIP_START in make-ami-fixtures.sh")
    return float(match.group(1))


def load_prediction(path: pathlib.Path) -> list[tuple[str, float, float]]:
    segments = []
    for line in path.read_text().splitlines():
        match = SEGMENT.search(line)
        if match:
            segments.append((f"s{match.group(1)}", float(match.group(2)), float(match.group(3))))
    if not segments:
        raise SystemExit(f"no diarization segments parsed from {path}")
    return segments


def overlap(a: tuple[float, float], b: tuple[float, float]) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def best_mapping(
    truth: list[tuple[float, float, str]], prediction: list[tuple[str, float, float]]
) -> tuple[dict[str, str], int, int]:
    """The relabelling of predicted speakers that agrees with the truth on the most turns.

    Ties are broken toward the mapping that also maximises total overlapping time, so a diarizer
    that gets the boundaries right is preferred over one that merely stumbled onto the right counts.
    """
    predicted_speakers = sorted({s for s, _, _ in prediction})
    truth_speakers = sorted({t for _, _, t in truth})

    # Dominant predicted speaker per truth turn, and how much of the turn it covers.
    dominant: list[tuple[str | None, float]] = []
    for start, end, _ in truth:
        totals = {s: 0.0 for s in predicted_speakers}
        for speaker, pstart, pend in prediction:
            totals[speaker] += overlap((start, end), (pstart, pend))
        if not totals or max(totals.values()) <= 0:
            dominant.append((None, 0.0))
        else:
            winner = max(totals, key=lambda s: totals[s])
            dominant.append((winner, totals[winner]))

    best = (0, 0.0, {})
    # Only 24 permutations for four speakers; brute force is clearer than anything clever.
    for combo in itertools.permutations(truth_speakers, len(predicted_speakers)):
        mapping = dict(zip(predicted_speakers, combo))
        hits = sum(
            1
            for (speaker, _), (_, _, label) in zip(dominant, truth)
            if speaker is not None and mapping[speaker] == label
        )
        covered = sum(
            weight
            for (speaker, weight), (_, _, label) in zip(dominant, truth)
            if speaker is not None and mapping[speaker] == label
        )
        if (hits, covered) > (best[0], best[1]):
            best = (hits, covered, mapping)
    return best[2], best[0], len(truth)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", help="Fixture name, e.g. ami-meeting.")
    parser.add_argument("prediction", type=pathlib.Path, help="Diarizer output to score.")
    args = parser.parse_args()

    truth = load_truth(args.fixture)
    prediction = load_prediction(args.prediction)
    mapping, hits, total = best_mapping(truth, prediction)

    print(f"{args.fixture}: {hits}/{total} turns correctly attributed — {100 * hits / total:.0f}%")
    print(f"  diarizer found {len({s for s, _, _ in prediction})} speakers, "
          f"truth has {len({t for _, _, t in truth})}")
    print(f"  best mapping: " + ", ".join(f"{k}→{v}" for k, v in sorted(mapping.items())))

    print(f"\n  {'truth':>5}  {'time':>14}  {'predicted':>9}  {'as':>4}")
    for (start, end, label) in truth:
        totals: dict[str, float] = {}
        for speaker, pstart, pend in prediction:
            totals[speaker] = totals.get(speaker, 0.0) + overlap((start, end), (pstart, pend))
        winner = max(totals, key=lambda s: totals[s]) if totals and max(totals.values()) > 0 else None
        mapped = mapping.get(winner, "—") if winner else "—"
        mark = "  " if mapped == label else " ✗"
        print(f"  {label:>5}  {start:6.2f}–{end:6.2f}  {str(winner):>9}  {mapped:>4}{mark}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
