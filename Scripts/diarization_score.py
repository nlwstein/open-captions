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
comparing them directly would measure nothing. Each cluster is assigned the truth label it dominates
most often — chosen once per file, never per turn, because a per-turn best mapping would score 100%
for any diarizer that found the right number of clusters, which is the failure mode this script
exists to avoid. The number is therefore an upper bound on what a perfect label assignment achieves.

The headline figure is deliberately followed by a breakdown by turn length. On a 47-second clip
almost every turn is long enough to be a fair question; on a real 25-minute meeting about half are
shorter than half a second, which is the diarizer's own step size. A single number over both would
read as model error when much of it is resolution.

Two accuracy figures are printed. The first lets each predicted cluster take the truth label it
dominates, so a person the model split across three clusters can be credited in all three; the
second allows each person only one cluster. The gap between them is fragmentation, and on a
dinner-table recording it is worth a few points.

Usage:
  uv run --no-project python -I Scripts/diarization_score.py <truth-fixture> <diarizer-output.txt>

  The diarizer output is the text form printed by FluidAudio's `lseend` command:
      Speaker 0: 0.10s - 21.80s (21.70s)

  `--turns` points at a `turns.txt` from `ami_annotations.py turns` (or the DiPCo equivalent,
  `dipco_annotations.py turns`); defaults to the committed AMI build output. `--clip-start` is only
  needed for a clip cut from a longer recording, and should be 0 for a whole-meeting score.
  `--table` prints every turn.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / ".fixture-build"

SEGMENT = re.compile(
    r"(?:Speaker|SPEAKER)[ _]?(\d+)\s*[:\s]\s*([\d.]+)\s*s?\s*[-–]\s*([\d.]+)\s*s?", re.IGNORECASE
)


def load_truth(
    fixture: str, turns_path: pathlib.Path, offset: float
) -> list[tuple[float, float, str]]:
    """(start, end, speaker) per reference line, in clip-relative seconds.

    Labels come from `Fixtures/annotations/<fixture>.txt` when that exists, because the committed
    reference is plain text with no second column. For a whole meeting scored straight from the
    corpus there is no such file and none is needed: `turns.txt` carries the speaker in its own
    third column, which is where the annotation file got it in the first place.
    """
    annotations = ROOT / "Fixtures" / "annotations" / f"{fixture}.txt"
    turns_file = turns_path
    if not turns_file.exists():
        raise SystemExit(
            f"no turn timings at {turns_file} — they are written by Scripts/make-ami-fixtures.sh "
            "(or `ami_annotations.py turns` for another meeting), which must be run first"
        )

    rows = [row for row in turns_file.read_text().splitlines() if row.strip()]
    # Only rows with a speaker survive into the reference file, so the filter must match the one
    # speaker_annotations.py applied or the two lists drift apart silently.
    timed = [row.split("|") for row in rows if len(row.split("|")) >= 4 and row.split("|")[3].strip()]

    if annotations.exists():
        labels = [line.strip() for line in annotations.read_text().splitlines() if line.strip()]
        if len(labels) != len(timed):
            raise SystemExit(
                f"{fixture}: {len(labels)} annotations vs {len(timed)} timed turns — "
                "the two are out of step; re-run Scripts/speaker_annotations.py"
            )
    else:
        labels = [parts[2] for parts in timed]

    return [
        (float(parts[0]) - offset, float(parts[1]) - offset, label)
        for parts, label in zip(timed, labels)
    ]


def contested(truth: list[tuple[float, float, str]]) -> list[float]:
    """Per turn: what fraction of it has another speaker talking at the same time?

    This is the reference's own overlap, not the diarizer's, so it says which turns *could* have
    been resolved rather than which were — which is the point. It separates "two people were
    talking at once and the diarizer picked one" from "one person was talking and the diarizer got
    it wrong", and those call for different fixes: the first is not a diarization problem at all.

    Measured as a fraction rather than a yes/no because a corpus like DiPCo saturates a yes/no —
    almost every turn in a dinner party touches some other turn somewhere, and a flag that is true
    for 96% of turns says nothing. What matters is whether the clash occupies the turn or merely
    clips its edge.
    """
    segments = [(start, end) for start, end, _ in truth]
    fractions = [0.0] * len(truth)

    for index, (start, end) in enumerate(segments):
        length = end - start
        if length <= 0:
            continue
        clash = 0.0
        for other, (ostart, oend) in enumerate(segments):
            if other != index:
                clash += max(0.0, min(end, oend) - max(start, ostart))
        fractions[index] = min(1.0, clash / length)

    return fractions


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
    """`(cluster, start, end)` per segment, from either output shape the CLI produces.

    `lseend` prints "Speaker 0: 0.10s - 21.80s" and `sortformer --output` writes JSON, and the two
    are compared against each other often enough that accepting both here is worth more than an
    adapter script. JSON is detected by content, not by extension, because the text form has been
    saved under `.json` names and back.
    """
    text = path.read_text()
    if text.lstrip().startswith("{"):
        payload = json.loads(text)
        segments = [
            (f"s{segment['speakerIndex']}", float(segment["startTimeSeconds"]), float(segment["endTimeSeconds"]))
            for segment in payload["segments"]
        ]
        if not segments:
            raise SystemExit(f"{path} parsed as sortformer JSON but holds no segments")
        return segments

    segments = []
    for line in text.splitlines():
        match = SEGMENT.search(line)
        if match:
            segments.append((f"s{match.group(1)}", float(match.group(2)), float(match.group(3))))
    if not segments:
        raise SystemExit(f"no diarization segments parsed from {path}")
    return segments


def overlap(a: tuple[float, float], b: tuple[float, float]) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def dominant_per_turn(
    truth: list[tuple[float, float, str]], prediction: list[tuple[str, float, float]]
) -> list[tuple[str | None, float]]:
    """For each truth turn: the predicted speaker covering most of it, and how much it covered."""
    predicted_speakers = sorted({s for s, _, _ in prediction})
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
    return dominant


def tally(
    dominant: list[tuple[str | None, float]], truth: list[tuple[float, float, str]]
) -> dict[str, dict[str, tuple[int, float]]]:
    """tally[cluster][label] = (turns where that cluster dominates, total time it covered)."""
    counts: dict[str, dict[str, list[float]]] = {}
    for (speaker, weight), (_, _, label) in zip(dominant, truth):
        if speaker is None:
            continue
        entry = counts.setdefault(speaker, {}).setdefault(label, [0, 0.0])
        entry[0] += 1
        entry[1] += weight
    return {c: {l: (int(v[0]), v[1]) for l, v in labels.items()} for c, labels in counts.items()}


def best_mapping(
    truth: list[tuple[float, float, str]],
    prediction: list[tuple[str, float, float]],
    strict: bool = False,
) -> tuple[dict[str, str], int, int]:
    """The relabelling of predicted speakers that agrees with the truth on the most turns.

    Two modes, because they answer two different questions and the gap between them is a result in
    its own right.

    The default is many-to-one: each cluster is labelled independently with the truth speaker it
    dominates most often. That is the most generous reading, and it is what "was this turn
    attributed to the right person" means if you allow a person to have been split across several
    clusters — which diarizers routinely do.

    `strict` allows each truth speaker at most one cluster, so a person split three ways can be
    credited in only one of them. This is the honest one for this app: a colour is the deliverable,
    and a speaker the model fragmented into three clusters shows up as three colours. It is solved
    exactly by a subset DP over the speakers rather than by search, since the state is just which
    speakers have been used.

    Ties on turn count break toward the assignment covering more overlapping time, so a diarizer
    with correct boundaries beats one that stumbled onto the right counts.
    """
    dominant = dominant_per_turn(truth, prediction)
    counts = tally(dominant, truth)
    speakers = sorted({label for _, _, label in truth})

    if not strict:
        mapping = {
            cluster: max(labels.items(), key=lambda kv: kv[1])[0]
            for cluster, labels in counts.items()
        }
    else:
        # dp[mask] = best (turns, covered) having assigned the clusters processed so far to exactly
        # the speakers in `mask`. Each cluster is either left unassigned or given a free speaker.
        clusters = sorted(counts)
        dp: dict[int, tuple[int, float, dict[str, str]]] = {0: (0, 0.0, {})}
        for cluster in clusters:
            nxt = dict(dp)
            for mask, (turns_hit, covered, assigned) in dp.items():
                for index, speaker in enumerate(speakers):
                    if mask >> index & 1:
                        continue
                    gain = counts[cluster].get(speaker, (0, 0.0))
                    candidate = (
                        turns_hit + gain[0],
                        covered + gain[1],
                        {**assigned, cluster: speaker},
                    )
                    new_mask = mask | (1 << index)
                    if new_mask not in nxt or candidate[:2] > nxt[new_mask][:2]:
                        nxt[new_mask] = candidate
            dp = nxt
        best = max(dp.values(), key=lambda v: v[:2])
        # A cluster that earns no hits is only filling a slot the DP had spare. Printing it would
        # read as a claim about a speaker it never matched, so it is dropped rather than relabelled.
        mapping = {
            cluster: speaker
            for cluster, speaker in best[2].items()
            if counts[cluster].get(speaker, (0, 0.0))[0] > 0
        }

    hits = sum(
        1
        for (cluster, _), (_, _, label) in zip(dominant, truth)
        if cluster is not None and mapping.get(cluster) == label
    )
    return mapping, hits, len(truth)


def stability(
    truth: list[tuple[float, float, str]],
    prediction: list[tuple[str, float, float]],
    windows: int,
) -> tuple[dict[str, str], list[tuple[float, float, int, dict[str, str], int, int]]]:
    """Whether a colour means the same person from the start of a recording to the end.

    The headline score answers "was this turn attributed to the right person", and it does so by
    choosing one relabelling for the whole file. That is exactly the thing a reader cannot do: they
    see the colours turn by turn, and if cluster `s2` is the mother in the first ten minutes and the
    uncle in the last ten, the headline score can be high while the app is unusable. This splits the
    recording into equal windows, solves the same mapping independently in each, and counts how
    often a window agrees with the file-wide answer.

    Windows are cut on time, not on turns, so a quiet stretch is not silently given the same weight
    as a busy one. A window with too few turns to decide anything is reported as such rather than
    counted as agreement — silence is not evidence of constancy.
    """
    floor, ceiling = min(t[0] for t in truth), max(t[1] for t in truth)
    width = (ceiling - floor) / windows if windows else 0.0
    whole, _, _ = best_mapping(truth, prediction, strict=True)

    rows: list[tuple[float, float, int, dict[str, str], int, int]] = []
    for index in range(windows):
        start = floor + index * width
        end = start + width
        subset = [t for t in truth if start <= (t[0] + t[1]) / 2 < end]
        if len(subset) < 8:
            # Too few turns to identify anyone; the honest answer is "undecided", not "agrees".
            rows.append((start, end, len(subset), {}, -1, -1))
            continue
        mapping, _, _ = best_mapping(subset, prediction, strict=True)
        agree = sum(1 for cluster, speaker in mapping.items() if whole.get(cluster) == speaker)
        rows.append((start, end, len(subset), mapping, agree, len(mapping)))
    return whole, rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", help="Fixture name, e.g. ami-meeting.")
    parser.add_argument("prediction", type=pathlib.Path, help="Diarizer output to score.")
    parser.add_argument(
        "--turns",
        type=pathlib.Path,
        default=BUILD / "ami" / "turns.txt",
        help="Turn timings for the fixture. Defaults to the committed AMI build output.",
    )
    parser.add_argument(
        "--clip-start",
        type=float,
        default=None,
        help="Corpus time the clip begins at, for fixtures cut from a longer recording. "
        "Defaults to CLIP_START in Scripts/make-ami-fixtures.sh.",
    )
    parser.add_argument(
        "--table",
        action="store_true",
        help="Print every turn. Off by default: a full meeting has thousands, and the "
        "duration breakdown above carries the finding.",
    )
    parser.add_argument(
        "--cross",
        action="store_true",
        help="Accuracy by turn length AND overlap together. Length alone flatters a meeting "
        "full of short backchannels and overlap alone flatters one full of long turn-taking; "
        "holding both fixed is the only comparison that travels between corpora.",
    )
    parser.add_argument(
        "--stability",
        type=int, default=0, metavar="WINDOWS",
        help="Split the recording into this many equal time windows and check whether each "
        "window's cluster→speaker mapping matches the file-wide one. This is the colour-"
        "constancy question: a high headline score with a low stability score means the "
        "right people were found but the colours moved.",
    )
    args = parser.parse_args()

    offset = args.clip_start if args.clip_start is not None else clip_start()
    truth = load_truth(args.fixture, args.turns, offset)
    prediction = load_prediction(args.prediction)
    mapping, hits, total = best_mapping(truth, prediction)
    strict_mapping, strict_hits, _ = best_mapping(truth, prediction, strict=True)

    print(f"{args.fixture}: {hits}/{total} turns correctly attributed — {100 * hits / total:.0f}%")
    print(f"  diarizer found {len({s for s, _, _ in prediction})} speakers, "
          f"truth has {len({t for _, _, t in truth})}")
    print(f"  best mapping: " + ", ".join(f"{k}→{v}" for k, v in sorted(mapping.items())))

    # Fragmentation is the gap between the two mappings, and it is not a footnote: the app shows one
    # colour per cluster, so a speaker the model split across three of them really does appear in
    # three colours. The generous figure is what "was the right person attributed" means; this is
    # what "would the reader see a consistent colour" means.
    shared = {
        label: sorted(cluster for cluster, mapped in mapping.items() if mapped == label)
        for label in {v for v in mapping.values()}
    }
    split = {label: clusters for label, clusters in shared.items() if len(clusters) > 1}
    print(
        f"  one colour per speaker: {strict_hits}/{total} — "
        f"{100 * strict_hits / total:.0f}%"
        + (f" (mapping: {', '.join(f'{k}→{v}' for k, v in sorted(strict_mapping.items()))})"
           if split else "")
    )
    if split:
        print("  fragmented: " + "; ".join(
            f"{label} across {len(clusters)} clusters ({', '.join(clusters)})"
            for label, clusters in sorted(split.items())
        ))

    # Per-turn outcome, computed once and used for both the breakdown and the table.
    rows = []
    for start, end, label in truth:
        totals: dict[str, float] = {}
        for speaker, pstart, pend in prediction:
            totals[speaker] = totals.get(speaker, 0.0) + overlap((start, end), (pstart, pend))
        winner = max(totals, key=lambda s: totals[s]) if totals and max(totals.values()) > 0 else None
        mapped = mapping.get(winner, "—") if winner else "—"
        rows.append((label, winner, mapped, end - start))

    # A flat accuracy figure is misleading on a real meeting, where most turns are shorter than the
    # diarizer's own step size and cannot be resolved by construction. Reporting the split is what
    # separates "the model is wrong" from "the question was unanswerable at this resolution".
    print("\n  by turn length")
    previous = 0.0
    for edge in (0.5, 1.0, 2.0, 5.0, None):
        if edge is None:
            selected = [r for r in rows if r[3] >= previous]
            label = f"  ≥{previous:>4.1f}s"
        else:
            selected = [r for r in rows if previous <= r[3] < edge]
            label = f"{previous:>4.1f}–{edge:<4.1f}s"
        if selected:
            right = sum(1 for r in selected if r[2] == r[0])
            print(f"    {label}  {right:5d}/{len(selected):<5d} {100 * right / len(selected):5.0f}%")
        if edge is None:
            break
        previous = edge

    if args.stability:
        whole, windows = stability(truth, prediction, args.stability)
        print(f"\n  colour constancy across {args.stability} equal time windows")
        decided = [w for w in windows if w[4] >= 0]
        agree = sum(1 for w in decided if w[4] == w[5])
        for start, end, count, mapping_w, hit, size in windows:
            if hit < 0:
                print(f"    {start / 60:5.1f}–{end / 60:5.1f}m  {count:4d} turns  too few to decide")
                continue
            mark = "same" if hit == size else f"MOVED ({hit}/{size} match)"
            detail = "" if hit == size else "  now: " + ", ".join(
                f"{c}→{s}" for c, s in sorted(mapping_w.items()) if whole.get(c) != s
            )
            print(f"    {start / 60:5.1f}–{end / 60:5.1f}m  {count:4d} turns  {mark}{detail}")
        if decided:
            print(
                f"    windows matching the file-wide mapping: "
                f"{agree}/{len(decided)} — {100 * agree / len(decided):.0f}%"
            )

    # Printed only when the recording has overlap at all, so the single-speaker fixtures do not
    # grow a section that says "none".
    clashes = contested(truth)
    if max(clashes) >= 0.1:
        print("\n  by how much of the turn someone else is talking over it")
        for low, high in ((0.0, 0.1), (0.1, 0.5), (0.5, 1.01)):
            selected = [r for r, c in zip(rows, clashes) if low <= c < high]
            if selected:
                right = sum(1 for r in selected if r[2] == r[0])
                share = 100 * len(selected) / len(rows)
                name = f"{low:.0%}–{high:.0%}" if high <= 1 else f"≥{low:.0%}"
                print(
                    f"    {name:<8} {right:5d}/{len(selected):<5d} "
                    f"{100 * right / len(selected):5.0f}%   ({share:.0f}% of turns)"
                )

    if args.cross:
        print("\n  by turn length and overlap together")
        print(f"    {'':<10} {'clear <10%':>14} {'10-50%':>14} {'contested >=50%':>16}")
        for low, high in ((0.0, 2.0), (2.0, float("inf"))):
            name = f"{'<2s' if high == 2.0 else '>=2s'}"
            cells = []
            for clash_low, clash_high in ((0.0, 0.1), (0.1, 0.5), (0.5, 1.01)):
                selected = [
                    r
                    for r, c in zip(rows, clashes)
                    if low <= r[3] < high and clash_low <= c < clash_high
                ]
                if selected:
                    right = sum(1 for r in selected if r[2] == r[0])
                    cells.append(f"{right}/{len(selected)} {100 * right / len(selected):.0f}%")
                else:
                    cells.append("—")
            print(f"    {name:<10} {cells[0]:>14} {cells[1]:>14} {cells[2]:>16}")

    if args.table:
        print(f"\n  {'truth':>5}  {'time':>14}  {'predicted':>9}  {'as':>4}")
        for (start, end, label), (_, winner, mapped, _) in zip(truth, rows):
            mark = "  " if mapped == label else " ✗"
            print(f"  {label:>5}  {start:6.2f}–{end:6.2f}  {str(winner):>9}  {mapped:>4}{mark}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
