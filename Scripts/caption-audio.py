#!/usr/bin/env python3
"""Caption a recording the way the app would, with speaker colours, from the command line.

This is the fastest way to see what the engine actually does to a real conversation: point it at
any audio file and it prints a speaker-attributed transcript, colour-coded, one turn per line.

    Scripts/caption-audio.py ~/recordings/sunday-lunch.m4a
    Scripts/caption-audio.py dinner.wav --html /tmp/dinner.html --title "Sunday lunch"
    Scripts/caption-audio.py --mic 60          # record a minute and caption it

It runs two models, both through FluidAudio's CLI, and joins them here:

  * **Parakeet TDT v3** for the words, with per-word timings. This is the engine that wins on every
    real recording in the fixture set and runs at a real-time factor of 0.009 — see ENGINES.md.
  * **a diarizer** for the speaker segments. `sortformer` by default; see `--diarizer`.

The join is the part that does not exist upstream, and it is deliberately simple: each word takes
the speaker whose segment covers its midpoint, and runs of words by the same speaker become turns.
A word covered by no segment inherits the nearest one in time, because a hole in the diarizer's
output means it did not detect speech there, not that nobody was speaking.

Read the numbers before trusting the colours. On DiPCo — ten sessions of a simulated dinner party
recorded in a lab, not ten real homes — one-colour-per-speaker attribution is wrong often enough
that the colours are a useful hint and not a transcript of who spoke. ENGINES.md has the
measurements, including which diarizer they are measurements *of*.

Everything runs locally. No audio leaves the machine, and nothing here writes to the network.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

# Eight distinguishable hues, readable on both light and dark terminals, chosen so that adjacent
# speakers do not look alike. The app will want the same property from its palette.
PALETTE = [
    "#1f77b4",  # blue
    "#d62728",  # red
    "#2ca02c",  # green
    "#9467bd",  # purple
    "#ff7f0e",  # orange
    "#17becf",  # cyan
    "#8c564b",  # brown
    "#e377c2",  # pink
]

ANSI = ["\033[34m", "\033[31m", "\033[32m", "\033[35m", "\033[33m", "\033[36m", "\033[91m", "\033[95m"]
RESET = "\033[0m"
DIM = "\033[2m"

# A new visual turn starts when the speaker changes or this much silence passes with the same
# speaker. 800 ms is the app's own rule, kept here so the command line and the app agree.
TURN_GAP_SECONDS = 0.8

# A speaker change has to last this long to be shown. The diarizer's own resolution is about
# 500 ms, so a word-by-word join manufactures switches it never claimed — "this is the | kick off |
# meeting for our project" came back as three turns by two speakers in the first test. Nobody
# reading a caption can use a colour that flickers mid-sentence, and the fix belongs here rather
# than in the diarizer: it is a statement about what is legible, not about who spoke.
MIN_TURN_SECONDS = 0.4


def find_cli(explicit: str | None) -> pathlib.Path:
    """The FluidAudio CLI, from the flag, the environment, or the places it gets installed.

    `~/.local/bin` comes first among the fallbacks because it is the one that survives a reboot:
    a Swift release build of the CLI is self-contained (the CoreML models are downloaded once into
    ~/Library/Application Support/FluidAudio and reloaded from there), so copying the single binary
    out of the build tree is enough to keep this working. The source trees are only a fallback for
    a machine where that copy has not been made.
    """
    candidates = [
        explicit,
        os.environ.get("FLUIDAUDIO_CLI"),
        str(pathlib.Path.home() / ".local/bin/fluidaudiocli"),
        "/tmp/fluidaudio-eval/src/.build/release/fluidaudiocli",
        str(pathlib.Path.home() / "fluidaudio/src/.build/release/fluidaudiocli"),
    ]
    for candidate in candidates:
        if candidate and pathlib.Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return pathlib.Path(candidate)
    raise SystemExit(
        "no FluidAudio CLI found. Build it with:\n"
        "  git clone --depth 1 https://github.com/FluidInference/FluidAudio.git ~/fluidaudio/src\n"
        "  cd ~/fluidaudio/src && swift build -c release --product fluidaudiocli\n"
        "  cp .build/release/fluidaudiocli ~/.local/bin/\n"
        "then pass --cli PATH or set FLUIDAUDIO_CLI. See ENGINES.md."
    )


def run(command: list[str]) -> None:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stderr.strip()[-2000:]}"
        )


def record(seconds: int, destination: pathlib.Path) -> None:
    """Capture from the default input device.

    macOS gates the microphone behind a per-application permission, so the first run from a new
    terminal will fail until that prompt is accepted. The error names it rather than looking like
    a missing file.
    """
    if not shutil.which("ffmpeg"):
        raise SystemExit("recording needs ffmpeg on PATH")
    print(f"Recording {seconds}s — say something.", file=sys.stderr)
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "avfoundation", "-i", ":0", "-t", str(seconds), str(destination)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            "could not record from the microphone. macOS asks each app for microphone access the "
            "first time — grant it to your terminal in System Settings → Privacy & Security → "
            f"Microphone, then retry.\n{result.stderr.strip()[-800:]}"
        )


def transcribe(cli: pathlib.Path, audio: pathlib.Path, work: pathlib.Path) -> list[dict]:
    """Word timings from Parakeet, via `transcribe --word-timestamps --output-json`."""
    out = work / "words.json"
    run([str(cli), "transcribe", str(audio), "--word-timestamps", "--output-json", str(out)])
    if not out.exists():
        raise SystemExit("transcribe produced no JSON — is --word-timestamps supported?")
    payload = json.loads(out.read_text())
    words = payload.get("wordTimings") or []
    if not words:
        raise SystemExit("transcribe returned no word timings; nothing to caption")
    print(
        f"  {len(words)} words in {payload.get('processingTimeSeconds', 0):.1f}s "
        f"({payload.get('rtfx', 0):.0f}× realtime), confidence {payload.get('confidence', 0):.2f}",
        file=sys.stderr,
    )
    return words


def diarize(cli: pathlib.Path, audio: pathlib.Path, work: pathlib.Path, engine: str) -> list[tuple[int, float, float]]:
    """`(speaker index, start, end)` segments."""
    out = work / "speakers.json"
    if engine == "sortformer":
        # Sortformer is capped at four speakers, which is the shape of the app's actual setting.
        run([str(cli), "sortformer", str(audio), "--output", str(out)])
        payload = json.loads(out.read_text())
        segments = [
            (int(s["speakerIndex"]), float(s["startTimeSeconds"]), float(s["endTimeSeconds"]))
            for s in payload["segments"]
        ]
    else:
        run([str(cli), "lseend", str(audio), "--variant", "dihard3", "--output", str(out)])
        if not out.exists():
            raise SystemExit("lseend produced no JSON — this build may not support --output")
        payload = json.loads(out.read_text())
        segments = [
            (int(s["speakerIndex"]), float(s["startTimeSeconds"]), float(s["endTimeSeconds"]))
            for s in payload["segments"]
        ]
    segments.sort(key=lambda s: s[1])
    print(f"  {len(segments)} speaker segments, {len({s[0] for s in segments})} distinct speakers", file=sys.stderr)
    return segments


def speaker_for(midpoint: float, segments: list[tuple[int, float, float]]) -> int | None:
    """The speaker covering this moment, or the nearest one when the diarizer has a hole.

    Nearest rather than None on purpose: a gap means the diarizer did not detect speech there, and
    the word demonstrably exists, so dropping it would silently delete text — the one failure a
    caption aid must not have.
    """
    for speaker, start, end in segments:
        if start <= midpoint <= end:
            return speaker
    if not segments:
        return None
    nearest = min(segments, key=lambda s: min(abs(midpoint - s[1]), abs(midpoint - s[2])))
    return nearest[0]


def smooth(spoken: list[dict], minimum: float) -> None:
    """Absorb speaker runs shorter than `minimum` into the turn that precedes them.

    In place, on the `speaker` field. Runs are merged repeatedly, because absorbing one short run
    can join two runs of the same speaker that the short one was separating. The first run is
    never merged away — there is nothing before it to merge into — so it is returned as-is even
    when short, which is the right call for a recording that opens mid-sentence.
    """
    changed = True
    while changed:
        changed = False
        runs: list[tuple[int | None, list[dict]]] = []
        for word in spoken:
            if runs and runs[-1][0] == word["speaker"]:
                runs[-1][1].append(word)
            else:
                runs.append((word["speaker"], [word]))
        if len(runs) < 2:
            return
        for index in range(1, len(runs)):
            speaker, group = runs[index]
            if group[-1]["end"] - group[0]["start"] >= minimum:
                continue
            previous = runs[index - 1][0]
            for word in group:
                word["speaker"] = previous
            changed = True
            break


def build_turns(words: list[dict], segments: list[tuple[int, float, float]], minimum: float) -> list[dict]:
    """Group words into speaker turns."""
    spoken: list[dict] = []
    for word in words:
        start, end = float(word["startTime"]), float(word["endTime"])
        text = (word.get("word") or "").strip()
        if not text:
            continue
        spoken.append({"speaker": speaker_for((start + end) / 2, segments), "start": start, "end": end, "text": text})

    if minimum > 0:
        smooth(spoken, minimum)

    turns: list[dict] = []
    for word in spoken:
        if (
            turns
            and turns[-1]["speaker"] == word["speaker"]
            and word["start"] - turns[-1]["end"] <= TURN_GAP_SECONDS
        ):
            turns[-1]["text"] += " " + word["text"]
            turns[-1]["end"] = word["end"]
        else:
            turns.append(
                {"speaker": word["speaker"], "start": word["start"], "end": word["end"], "text": word["text"]}
            )

    for turn in turns:
        # Parakeet emits punctuation attached to words; tidy the joins without touching word choice.
        turn["text"] = turn["text"].replace(" ,", ",").replace(" .", ".").replace(" ?", "?")
    return turns


def render_terminal(turns: list[dict], label: callable) -> None:
    for turn in turns:
        colour = ANSI[turn["speaker"] % len(ANSI)] if turn["speaker"] is not None else DIM
        who = label(turn["speaker"])
        print(f"{DIM}{turn['start']:7.1f}s{RESET} {colour}{who:>10}{RESET}  {turn['text']}")


def render_html(turns: list[dict], label: callable, title: str, destination: pathlib.Path) -> None:
    """A page in the app's own visual language: big text, one colour per speaker, no chrome.

    Deliberately not a chat bubble or a table. The person this is for will read it from a metre
    away, so the type is large, the turns are separated by space rather than rules, and the only
    colour is the speaker's.
    """
    body = []
    for turn in turns:
        if turn["speaker"] is None:
            colour, name = "#888888", "—"
        else:
            colour = PALETTE[turn["speaker"] % len(PALETTE)]
            name = label(turn["speaker"])
        body.append(
            f'<div class="turn" style="--c:{colour}">'
            f'<div class="who">{html.escape(name)}'
            f'<span class="t">{turn["start"]:.0f}s</span></div>'
            f'<div class="said">{html.escape(turn["text"])}</div>'
            f"</div>"
        )
    destination.write_text(
        f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ margin:0 auto; max-width:52rem; padding:2rem 1.25rem 6rem;
         font:400 20px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
  h1 {{ font-size:1.6rem; font-weight:600; margin:0 0 .25rem; }}
  .meta {{ opacity:.6; font-size:.85rem; margin-bottom:2.5rem; }}
  .turn {{ border-left:5px solid var(--c); padding:.1rem 0 .1rem 1rem; margin:0 0 1.6rem; }}
  .who {{ color:var(--c); font-weight:650; font-size:.8rem; letter-spacing:.06em;
          text-transform:uppercase; }}
  .who .t {{ opacity:.45; font-weight:400; margin-left:.6rem; letter-spacing:0; }}
  .said {{ font-size:1.65rem; line-height:1.45; }}
</style></head><body>
<h1>{html.escape(title)}</h1>
<p class="meta">{len(turns)} turns · {len({t["speaker"] for t in turns})} speakers ·
Parakeet TDT v3 + Sortformer · colours are a hint, not a guarantee</p>
{"".join(body)}
</body></html>
"""
    )
    print(f"\nHTML written to {destination}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("audio", nargs="?", type=pathlib.Path, help="Any audio or video file.")
    parser.add_argument("--mic", type=int, metavar="SECONDS",
                        help="Record from the microphone for this long, then caption it.")
    parser.add_argument("--html", type=pathlib.Path, help="Also write a colour-coded page here.")
    parser.add_argument("--title", default=None, help="Heading for the HTML page.")
    parser.add_argument("--diarizer", choices=("sortformer", "lseend"), default="sortformer",
                        help="sortformer is the default: it scores far higher on real far-field "
                             "audio than lseend's best variant. See ENGINES.md.")
    parser.add_argument("--cli", help="Path to the FluidAudio CLI.")
    parser.add_argument("--min-turn", type=float, default=MIN_TURN_SECONDS, metavar="SECONDS",
                        help=f"Shortest speaker change to display (default {MIN_TURN_SECONDS}). "
                             "Shorter runs are absorbed into the turn before them. 0 disables.")
    parser.add_argument("--keep", action="store_true", help="Keep the intermediate JSON.")
    args = parser.parse_args()

    if not args.audio and not args.mic:
        parser.error("give an audio file, or --mic SECONDS to record one")

    cli = find_cli(args.cli)
    work = pathlib.Path(tempfile.mkdtemp(prefix="caption-"))
    audio = args.audio
    if args.mic:
        audio = work / "mic.wav"
        record(args.mic, audio)
    if not audio.exists():
        raise SystemExit(f"no such file: {audio}")

    print(f"Captioning {audio}", file=sys.stderr)
    words = transcribe(cli, audio, work)
    segments = diarize(cli, audio, work, args.diarizer)
    turns = build_turns(words, segments, args.min_turn)

    label = lambda index: "—" if index is None else f"Speaker {index + 1}"  # noqa: E731
    render_terminal(turns, label)
    if args.html:
        title = args.title or audio.stem.replace("_", " ").replace("-", " ").title()
        render_html(turns, label, title, args.html)

    if args.keep:
        print(f"\nintermediates kept in {work}", file=sys.stderr)
    else:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
