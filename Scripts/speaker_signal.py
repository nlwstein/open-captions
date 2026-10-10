#!/usr/bin/env python3
"""Asks whether cheap acoustic features separate the true speakers at all.

Speaker grouping is the app's only visual structure, and every way of building it — an embedding
model, a clustering pass, a threshold — rests on one assumption: that a speaker sounds more like
themselves than like anyone else in the room. If that does not hold on the fixtures, no amount of
engine work downstream will recover it, and the honest move is to find out before building.

Two measurements per fixture, both over pairs of turns:

  within   distance between two turns by the *same* speaker
  across   distance between two turns by *different* speakers

The features are median F0 by autocorrelation and a band-energy profile: both hand-rolled, neither
needing a model download. They were picked for being cheap, but the result should not be read as a
cost trade-off — the target is an iPhone 15 Pro Max or newer, where spending compute is fine as
long as it keeps up in real time. These features do not fail because they are cheap. They fail
because they measure what was said rather than who said it, and a larger budget does not fix that.

Turns are read as isolated per-turn clips rather than sliced out of the mixed fixture, so a
grouping failure here cannot be blamed on segmentation — this measures the feature, not the loop.

  synthetic  .fixture-build/<fixture>/lines.tsv, written by make-fixtures.sh (one clip per line,
             same order as the heredoc, so the voice is known from the script)
  AMI        Fixtures/audio/ami-meeting.wav, cut per turn using the timings and speaker labels in
             .fixture-build/ami/turns.txt

AMI is the one that counts, and it is the reason this script takes an --audio argument at all. The
first version of it read .fixture-build/ami/turn_NNN.caf and called those turns real speech. They
are not: make-ami-fixtures.sh renders those files with `say`, one fixed macOS voice per participant,
as the synthetic twin of the real meeting. Measuring them would have answered a question about
text-to-speech while appearing to answer one about people — and it would have flattered the result,
because a fixed voice is bit-for-bit the same speaker every time it talks.

The real audio is the corpus mixdown. Cutting turns out of it is imperfect — the mix contains
crosstalk from the other participants, and a group of real people in a real room is the hard case
this app exists for — but it is real.

Usage: uv run --with numpy Scripts/speaker_signal.py [--fixture NAME]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / ".fixture-build"
MAKE_FIXTURES = ROOT / "Scripts" / "make-fixtures.sh"
MAKE_AMI_FIXTURES = ROOT / "Scripts" / "make-ami-fixtures.sh"
SAMPLE_RATE = 16000

HEREDOC = re.compile(r'render_lines\s+"([^"]+)"[^\n]*<<(\w+)\n(.*?)\n\s*\2\b', re.DOTALL)
HEREDOC_LINE = re.compile(r"^\$VOICE_([A-Z])\|(\d+)\|(.*)$")


def decode(path: pathlib.Path) -> np.ndarray:
    """Audio as float32 mono at 16 kHz, via ffmpeg so the container format does not matter."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "1",
         "-ar", str(SAMPLE_RATE), "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype="<f4").astype(np.float64)


def trim(signal: np.ndarray) -> np.ndarray:
    """Drop leading and trailing near-silence. `say` pads its output, and the padding carries no
    speaker information while diluting every average taken over the clip."""
    if signal.size == 0:
        return signal
    frame = 400
    usable = signal[: signal.size // frame * frame].reshape(-1, frame)
    energy = np.sqrt((usable**2).mean(axis=1) + 1e-12)
    if energy.max() <= 0:
        return signal
    loud = np.flatnonzero(energy > energy.max() * 0.05)
    if loud.size == 0:
        return signal
    return signal[loud[0] * frame : (loud[-1] + 1) * frame]


def frames(signal: np.ndarray, size: int = 640, hop: int = 320) -> np.ndarray:
    if signal.size < size:
        signal = np.pad(signal, (0, size - signal.size))
    count = 1 + (signal.size - size) // hop
    index = np.arange(size)[None, :] + hop * np.arange(count)[:, None]
    return signal[index] * np.hanning(size)[None, :]


def median_f0(signal: np.ndarray) -> float:
    """Median fundamental frequency over voiced frames, 0.0 if none were voiced.

    Autocorrelation, peak in the 70-320 Hz lag range, accepted only if the peak is a clear fraction
    of the frame's energy — otherwise a fricative or a noise burst would report a confident pitch.
    """
    lo, hi = SAMPLE_RATE // 320, SAMPLE_RATE // 70
    values = []
    for frame in frames(signal):
        flat = frame - frame.mean()
        energy = (flat**2).sum()
        if energy <= 1e-9:
            continue
        correlation = np.correlate(flat, flat, mode="full")[flat.size - 1 :]
        if correlation[0] <= 0:
            continue
        correlation = correlation / correlation[0]
        window = correlation[lo:hi]
        if window.size == 0:
            continue
        lag = lo + int(np.argmax(window))
        if correlation[lag] > 0.3:
            values.append(SAMPLE_RATE / lag)
    return float(np.median(values)) if values else 0.0


def band_profile(signal: np.ndarray) -> np.ndarray:
    """Mean log energy in 12 mel-spaced bands — a coarse stand-in for a spectral voiceprint."""
    edges = np.linspace(0, 1, 13)
    windowed = frames(signal)
    spectrum = np.abs(np.fft.rfft(windowed, axis=1)) ** 2
    # Mel scale, so the bands spread the way hearing does rather than the way Hz does. Built from
    # the actual bin frequencies, which depend on the frame size — assuming a band range that does
    # not match the FFT width indexes off the end of the spectrum.
    hz = np.fft.rfftfreq(windowed.shape[1], 1 / SAMPLE_RATE)
    mel = 2595 * np.log10(1 + hz / 700)
    mel = mel / mel[-1]
    bins = [np.flatnonzero((mel >= a) & (mel < b)) for a, b in zip(edges[:-1], edges[1:])]
    out = []
    for group in bins:
        if group.size == 0:
            out.append(0.0)
        else:
            out.append(float(np.log(spectrum[:, group].mean() + 1e-12)))
    return np.array(out)


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    denominator = np.linalg.norm(a) * np.linalg.norm(b)
    return float(1 - (a @ b) / denominator) if denominator > 0 else float("nan")


class Turn:
    def __init__(self, speaker: str, signal: np.ndarray, text: str):
        self.speaker = speaker
        self.signal = trim(signal)
        self.text = text
        self.f0 = median_f0(self.signal)
        self.bands = band_profile(self.signal)

    @property
    def seconds(self) -> float:
        return self.signal.size / SAMPLE_RATE

    @property
    def label(self) -> str:
        return f"{self.speaker} {self.f0:5.0f}Hz {self.seconds:4.1f}s  {self.text[:40]}"


def synthetic_turns(fixture: str) -> list[Turn]:
    lines_file = BUILD / fixture / "lines.tsv"
    if not lines_file.exists():
        return []
    script = MAKE_FIXTURES.read_text()
    voices = []
    for name, _, body in HEREDOC.findall(script):
        if name == fixture:
            voices = [m.group(1) for m in (HEREDOC_LINE.match(l.strip()) for l in body.splitlines()) if m]
    rows = [l.split("\t") for l in lines_file.read_text().splitlines() if l.strip()]
    if len(voices) != len(rows):
        print(f"  {fixture}: {len(voices)} voices vs {len(rows)} clips — skipped", file=sys.stderr)
        return []
    return [Turn(voices[i], decode(pathlib.Path(r[1])), r[2]) for i, r in enumerate(rows)]


def clip_start() -> float:
    """The corpus-time offset of the fixture window, read from the script that defines it rather
    than repeated here — if the window ever moves, the turns move with it."""
    match = re.search(r"^CLIP_START=([\d.]+)", MAKE_AMI_FIXTURES.read_text(), re.MULTILINE)
    if not match:
        raise SystemExit(f"no CLIP_START in {MAKE_AMI_FIXTURES}")
    return float(match.group(1))


def ami_turns(audio: pathlib.Path) -> list[Turn]:
    turns_file = BUILD / "ami" / "turns.txt"
    if not turns_file.exists() or not audio.exists():
        return []
    signal = decode(audio)
    offset = clip_start()
    turns = []
    for row in turns_file.read_text().splitlines():
        parts = row.split("|")
        if len(parts) < 4 or not parts[3].strip():
            continue
        start = int((float(parts[0]) - offset) * SAMPLE_RATE)
        end = int((float(parts[1]) - offset) * SAMPLE_RATE)
        turns.append(Turn(parts[2], signal[max(0, start) : max(0, end)], parts[3]))
    return turns


def report(name: str, turns: list[Turn], real: bool) -> bool:
    print(f"\n=== {name} — {len(turns)} turns, "
          f"{len({t.speaker for t in turns})} speaker(s){'  [real speech]' if real else ''} ===")
    for turn in turns:
        print("   " + turn.label)

    if len({t.speaker for t in turns}) < 2:
        print("   only one speaker — nothing to separate")
        return False

    rows = []
    for i in range(len(turns)):
        for j in range(i + 1, len(turns)):
            same = turns[i].speaker == turns[j].speaker
            rows.append((same, term_f0(turns[i], turns[j]), cosine(turns[i].bands, turns[j].bands)))

    print(f"   {'':6} {'F0 Δ Hz':>16}   {'band cos':>16}")
    for field, label, fmt in ((1, "F0 Δ Hz", "{:7.1f}"), (2, "band cos", "{:7.4f}")):

        def overlap_of(indices) -> str:
            within = [rows[k][field] for k in indices if rows[k][0] and not np.isnan(rows[k][field])]
            across = [rows[k][field] for k in indices if not rows[k][0] and not np.isnan(rows[k][field])]
            if not within or not across:
                return "     n/a"
            w, a = np.array(within), np.array(across)
            # Overlap is the honest summary: the share of cross-speaker pairs that sit closer
            # together than the median same-speaker pair. Zero means a threshold exists; heavy
            # overlap means any threshold trades errors for errors.
            overlap = float((a < np.median(w)).mean())
            return (f"same {fmt.format(w.mean())} ± {fmt.format(w.std()):>7}  "
                    f"diff {fmt.format(a.mean())} ± {fmt.format(a.std()):>7}  "
                    f"overlap {overlap*100:3.0f}%")

        print(f"   {label:>8}: all pairs   {overlap_of(range(len(rows)))}")
        # Same measurement with turns shorter than half a second removed from both sides. A one-word
        # reply gives the pitch estimate almost nothing to work with, and if the overlap lives in
        # those pairs then the engine's fix is to inherit a speaker rather than to listen harder.
        long_enough = {i for i, t in enumerate(turns) if t.seconds >= 0.5}
        kept = [k for k, (i, j) in enumerate(pairs(turns)) if i in long_enough and j in long_enough]
        print(f"   {'':>8}  ≥0.5s turns {overlap_of(kept)}")
    return True


def pairs(turns: list[Turn]):
    return [(i, j) for i in range(len(turns)) for j in range(i + 1, len(turns))]


def term_f0(a: Turn, b: Turn) -> float:
    return abs(a.f0 - b.f0) if a.f0 > 0 and b.f0 > 0 else float("nan")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", help="Only this fixture.")
    parser.add_argument(
        "--audio",
        default="ami-meeting",
        help="Which real fixture to cut the AMI turns from: ami-meeting (headset) or "
             "ami-meeting-far (tabletop array).",
    )
    parser.add_argument("--synthetic", action="store_true", help="Also measure the `say` fixtures.")
    args = parser.parse_args()

    measured = False

    turns = ami_turns(ROOT / "Fixtures" / "audio" / f"{args.audio}.wav")
    if turns:
        measured |= report(args.audio, turns, real=True)

    if args.synthetic or args.fixture:
        for fixture in sorted(p.name for p in BUILD.iterdir() if p.is_dir() and p.name != "ami"):
            if args.fixture and fixture != args.fixture:
                continue
            synthetic = synthetic_turns(fixture)
            if synthetic:
                measured |= report(fixture, synthetic, real=False)

    return 0 if measured else 1


if __name__ == "__main__":
    raise SystemExit(main())
