#!/usr/bin/env python3
"""Reads the DiPCo corpus's transcriptions and emits what a fixture needs.

DiPCo is ten sessions of four people around a dining table — a simulated dinner party, recorded in
a lab for Interspeech 2020, with music piped into several sessions and genuine overlapping speech.
Five far-field array devices around the room, and one close-talk headset per participant. It is a
different room and a different kind of speech from the AMI design meetings the fixtures use, which
is the whole reason for adding it — see ENGINES.md.

Usage:
    dipco_annotations.py turns     <transcriptions.json> <device>
    dipco_annotations.py reference <transcriptions.json> <device>

`turns` writes `start|end|speaker|text`, the same shape `ami_annotations.py turns` writes, so
`diarization_score.py --turns` scores it with no further glue. `reference` writes plain speech
text for WER.

The device is the interesting argument. Each segment carries a *separate* timestamp per device
(`U01`–`U05`, `close-talk`), because the corpus authors re-aligned each transcription to each
channel. So the same conversation can be scored against an array in the room or a headset on a
participant without re-deriving anything, and the difference between those two runs is the room.

The corpus is not in this repository. It is a 12.5 GB download:

    hf download huckiyang/DiPCo --repo-type dataset --local-dir .corpora/dipco

Licence is CDLA-Permissive-1.0. See Fixtures/README.md for attribution.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

# `U01`–`U05` are the far-field array devices; `close-talk` is the participant's own microphone.
# Anything else in a timestamp dict is a version of the corpus this was not written against.
FAR_FIELD = ("U01", "U02", "U03", "U04", "U05")


def parse_time(value: str) -> float:
    """`HH:MM:SS.mmm` to seconds. DiPCo uses the same string format on every device."""
    hours, minutes, seconds = value.split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def load(path: pathlib.Path, device: str) -> list[tuple[float, float, str, str]]:
    """(start, end, speaker, text) per segment, in the device's own timeline, time-ordered."""
    with path.open() as handle:
        segments = json.load(handle)

    rows = []
    for segment in segments:
        # A segment that a device never captured has no entry for it. Dropping those keeps the
        # output an honest record of what that microphone heard rather than of what was said.
        starts, ends = segment.get("start_time", {}), segment.get("end_time", {})
        if device not in starts or device not in ends:
            continue
        text = (segment.get("words") or "").strip()
        speaker = (segment.get("speaker_id") or "").strip()
        if not text or not speaker:
            continue
        rows.append((parse_time(starts[device]), parse_time(ends[device]), speaker, text))

    rows.sort(key=lambda row: row[0])
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("turns", "reference"))
    parser.add_argument("transcriptions", type=pathlib.Path)
    parser.add_argument(
        "device",
        nargs="?",
        default="U01",
        help="Timestamp set to use: U01-U05 for the arrays, or close-talk. Default U01.",
    )
    args = parser.parse_args()

    if not args.transcriptions.exists():
        raise SystemExit(
            f"no transcriptions at {args.transcriptions} — fetch the corpus with "
            "`hf download huckiyang/DiPCo --repo-type dataset --local-dir .corpora/dipco`"
        )

    # The close-talk channel exists for every segment by construction; the arrays do not, so a
    # mistyped device would otherwise look like an empty session rather than a wrong argument.
    available = set()
    with args.transcriptions.open() as handle:
        for segment in json.load(handle):
            available.update(segment.get("start_time", {}))
    if args.device not in available:
        raise SystemExit(
            f"no device '{args.device}' in {args.transcriptions.name}. "
            f"Available: {', '.join(sorted(available))}"
        )

    rows = load(args.transcriptions, args.device)
    if not rows:
        raise SystemExit(f"device '{args.device}' has no segments with text")

    if args.mode == "turns":
        for start, end, speaker, text in rows:
            print(f"{start:.3f}|{end:.3f}|{speaker}|{text}")
    else:
        print(" ".join(text for _, _, _, text in rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
