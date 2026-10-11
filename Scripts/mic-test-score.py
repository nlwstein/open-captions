"""Scores a microphone test from the app against what was actually said.

    python3 Scripts/mic-test-score.py <results.json> <reference.txt>

results.json is the file the app's microphone test writes (share it, or pull Documents/MicTest
with `xcrun devicectl device copy from`). reference.txt is the text of the clip that was playing,
as played by Scripts/mic-test-play.sh.

Each setup records the clip once through, starting wherever the loop happened to be, so the score
ignores word order: content-word recall is the share of the reference's content words (each
occurrence counted) that turn up in the transcript. Function words like "the" are left out, because
a recogniser guessing them proves nothing about the microphone.
"""
import json
import re
import sys
from collections import Counter

STOP = set("""a an the and or but if so of to in on at by for with from as is are was were be been
being am it its it's this that these those i you he she we they me him her us them my your his our
their do does did have has had not no yes uh um oh okay ok just like""".split())


def words(text):
    return [w for w in re.findall(r"[a-z0-9']+", text.lower()) if w not in STOP]


def main(results_path, reference_path):
    results = json.load(open(results_path))
    reference = Counter(words(open(reference_path).read()))
    total = sum(reference.values())
    rows = []
    for clip in results["clips"]:
        if clip.get("transcript") is None:
            rows.append((-1, clip, 0, 0))
            continue
        heard = Counter(words(clip["transcript"]))
        hit = sum((heard & reference).values())
        extra = sum((heard - reference).values())
        rows.append((hit / total if total else 0, clip, hit, extra))
    rows.sort(key=lambda r: -r[0])
    print(f"{results.get('device', '')}, {total} reference content words\n")
    print(f"{'recall':>7} {'hit':>5} {'extra':>5} {'speech dB':>9}  setup")
    for recall, clip, hit, extra in rows:
        label = " · ".join(filter(None, [clip["setup"]["processing"], clip["setup"]["microphone"],
                                         clip["setup"]["pattern"]]))
        if recall < 0:
            print(f"{'—':>7} {'':>5} {'':>5} {clip.get('levelP90', 0):9.0f}  {label}  (not transcribed)")
        else:
            print(f"{recall:7.1%} {hit:5d} {extra:5d} {clip['levelP90']:9.0f}  {label}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
