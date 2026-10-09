#!/usr/bin/env python3
"""Reads AMI word annotations and emits the two things a fixture needs: a reference
transcript, and a per-turn breakdown for re-synthesising the same conversation.

The corpus is not in this repository — it is a 40 MB download, and `make-ami-fixtures.sh`
fetches it. Point this at wherever it landed:

    ami_annotations.py reference <corpus> <meeting> <start> <end>
    ami_annotations.py turns     <corpus> <meeting> <start> <end>

Words are emitted in *time* order, not grouped by speaker. That is not a stylistic
choice: these recordings are a mixdown of four headset microphones, so when two people
talk at once both voices are genuinely present and a transcriber hears them interleaved.
Grouping by speaker would put the words in an order nobody ever heard and score the
recognizer against a conversation that did not happen.

Fillers ("Um", "uh", "Mm-hmm") are kept. Whisper emits them, so dropping them from the
reference would hand it a free pass on the tokens it is least reliable about — and the
synthetic twin is generated from this same output, so both sides of that comparison stay
symmetric. Punctuation is restored from the annotation's punc="true" markers purely for
readability; the harness strips it before scoring.
"""

import argparse
import glob
import os
import sys
import xml.etree.ElementTree as ET

# A turn is one speaker talking without this long a pause. It only decides where the
# reference text wraps and where the twin starts a new utterance — never the scoring.
TURN_GAP = 1.0

# The gap between the end of one turn and the start of the next, used when re-synthesising.
# Kept short so the twin's turn boundaries land where the real ones did.
DEFAULT_TURN_GAP = 0.15


def load(corpus, meeting):
    """Every annotated word for a meeting, from all four speakers, in time order."""
    pattern = os.path.join(corpus, "words", f"{meeting}.*.words.xml")
    paths = sorted(glob.glob(pattern))
    if not paths:
        raise SystemExit(
            f"No word annotations matching {pattern}.\n"
            f"Run Scripts/make-ami-fixtures.sh, or pass the directory holding words/ and segments/."
        )

    words = []
    for path in paths:
        # ES2002a.B.words.xml -> "B"
        speaker = os.path.basename(path).split(".")[1]
        root = ET.parse(path).getroot()
        # The root binds xmlns:nite as a *prefix*, so the <w> children are in no
        # namespace at all and cannot be found with a namespaced path.
        for element in root.findall("w"):
            text = (element.text or "").strip()
            if not text:
                continue
            words.append({
                "speaker": speaker,
                "start": float(element.get("starttime")),
                "end": float(element.get("endtime")),
                "text": text,
                "punc": element.get("punc") == "true",
                "trunc": element.get("trunc") == "true",
            })
    words.sort(key=lambda w: (w["start"], w["end"]))
    return words


def in_window(words, start, end):
    """Tokens starting inside the window, plus any punctuation that closes the last word.

    A "." or "?" carries the same timestamp as the word before it, so a window ending
    exactly on that timestamp would otherwise leave the sentence visibly unterminated.
    """
    picked = [w for w in words if start <= w["start"] < end]
    for w in words:
        if w["start"] >= end and w["punc"] and picked and abs(w["start"] - picked[-1]["end"]) < 0.01:
            picked.append(w)
        elif w["start"] >= end:
            break
    return picked


def render(tokens):
    """Joins tokens into a line, attaching punctuation to the word it follows."""
    parts = []
    for token in tokens:
        if token["trunc"]:
            # A cut-off fragment is not a word anybody would expect on screen, and the
            # recognizer has no way to produce it. Dropped from both reference and twin.
            continue
        if token["punc"]:
            if parts:
                parts[-1] += token["text"]
            continue
        parts.append(token["text"])
    return " ".join(parts).strip()


def turns(tokens, gap=TURN_GAP):
    """Groups tokens into runs of one speaker, breaking on a pause longer than `gap`."""
    out = []
    for token in tokens:
        previous = out[-1] if out else None
        if previous and previous["speaker"] == token["speaker"] \
                and token["start"] - previous["end"] < gap:
            previous["tokens"].append(token)
            previous["end"] = token["end"]
        else:
            out.append({
                "speaker": token["speaker"],
                "start": token["start"],
                "end": token["end"],
                "tokens": [token],
            })
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["reference", "turns"])
    parser.add_argument("corpus", help="Directory containing words/ and segments/")
    parser.add_argument("meeting", help="Meeting identifier, e.g. ES2002a")
    parser.add_argument("start", type=float)
    parser.add_argument("end", type=float)
    args = parser.parse_args()

    tokens = in_window(load(args.corpus, args.meeting), args.start, args.end)
    groups = turns(tokens)

    if args.mode == "reference":
        print("\n".join(line for line in (render(t["tokens"]) for t in groups) if line))
        return

    for turn in groups:
        text = render(turn["tokens"])
        if text:
            # start|end|speaker|text — the builder places each turn at `start`.
            print(f"{turn['start']:.3f}|{turn['end']:.3f}|{turn['speaker']}|{text}")

    spoken = [t for t in tokens if not t["punc"] and not t["trunc"]]
    print(f"# {len(spoken)} words, {len(groups)} turns, "
          f"speakers {sorted({t['speaker'] for t in spoken})}", file=sys.stderr)


if __name__ == "__main__":
    main()
