# live-caption

On-device live captioning for an elderly user: a giant start/stop button and large auto-scrolling
text, running WhisperKit on the Neural Engine. No settings, no model pickers.

**This repository currently contains the measurement harness, not the app.** The app is
deliberately not started yet — there is no point building a UI around a pipeline whose accuracy
in a noisy room is unknown.

## Quick start

```bash
swift run -c release caption-harness list
swift run -c release caption-harness evaluate --all --model-cache .models
```

The first run downloads the model (~1.5 GB) into `.models/`.

> **Use `-c release` for anything you intend to quote.** Debug builds are several times slower and
> the latency figures are meaningless. Accuracy figures are the same either way.

## What the harness does

| Command | Purpose |
|---|---|
| `make test` | Every fixture, written to `reports/latest.md` — the report that drives the next change |
| `make test-clean` | Only the clean fixture. If this is not near-perfect, nothing else is worth measuring |
| `make test-hard` | Only the degraded synthetic fixtures: crowd noise and multiple speakers |
| `make test-real` | Only the recorded fixtures — real voices in a real room, close-mic and far-field |
| `make unit` | The scoring and segmentation logic. No model, no audio, fast |
| `list` | Show the fixtures and what each one covers |
| `transcribe <file>` | One file, with timestamps and latency. `--json` for machine-readable output |
| `evaluate <fixture>` | Score one fixture: WER, critical information, latency |
| `evaluate --all` | Every fixture, plus a summary. `--output <file>` writes JSON |
| `report <fixture>` | The markdown report on stdout, without running the `make` target |

Useful flags: `--model` (compare model sizes), `--vad` (voice-activity chunking on/off),
`--turns` (print the visual blocks the app would show), `--auto-language`, `--no-prewarm`.

`reports/` is generated, so it is gitignored: run `make test` to regenerate rather than editing it.
The committed reference point is `evaluations/baseline.json`; `evaluations/2026-10-08-pre-scorer-fix.json`
is kept alongside it as the before/after of the critical-information scorer change.

## The three measurements, and why there are three

A single accuracy number would hide the failure that matters. The harness reports all three side
by side because a model can win on one and lose on another.

**Word error rate** — the conventional measure, on punctuation-stripped text. A second
*semantic* WER folds away spelling differences that carry no meaning before counting: spelled-out
numbers become digits ("fifteen" agrees with "15") and titles collapse to one form ("Doctor
Feldman" agrees with "Dr. Feldman"). The gap between the two is the recognizer's formatting noise
rather than its comprehension — and because it is not comprehension, it should not be allowed to
inflate the error count.

**Critical information** — did the names, numbers, and negations survive? This is the DeafBench
idea: WER weights every word equally, which is backwards for a captioning aid. Dropping "the" is
harmless. Dropping the "not" in *"do not take the second pill"* inverts the instruction. The
scorer aligns reference and hypothesis once, then checks three categories against that alignment
and reports each failure with severity:

| Severity | Meaning |
|---|---|
| `severe` | A negation lost, altered, or invented — or a wrong number. Changes what the user should do. |
| `moderate` | A different name than the one spoken. |
| `minor` | One character's difference — probably the same name mis-spelled. |

The score is the **mean of the three per-category recalls**, with a category that has no tokens in
the reference counting as a full mark — a scene with no numbers in it should not be penalised for
having no numbers. So the detail tables will not add up to the score by hand, and should not: a
scene with one name and three negations is scored out of two categories, not out of four tokens.

The count of severe misses is the number to act on. A transcript can score 95% overall and still
contain a polarity flip.

**Latency** — time to first word, total time, and real-time factor (processing time ÷ audio
duration). A real-time factor below 1 is the bar for keeping up with live speech; above 1 the app
falls behind a talkative speaker. The recognizer's own pipeline timings are reported alongside so
the harness's wall-clock numbers can be sanity-checked against WhisperKit's.

## First results

Measured 2026-10-08 on an M2 Pro with `openai_whisper-large-v3_turbo`, whole-file decoding, one
decode worker, on an otherwise idle machine. Raw output in `evaluations/baseline.json`; the rendered
report in `reports/latest.md`.

**Bottom line: the synthetic fixtures were overstating the difficulty, and adding recorded speech is
what showed it.** A real four-person meeting — real voices, real room, real crosstalk — comes back at
**16.0% WER with 96.3% of the critical information intact**. The synthetic dinner-table fixture scores
51.0% and 77.8% on the same model. These are not a harder version of the target scenario; they are a
different and largely artificial one. The worst result here belongs to the fixture that is closest to
the app's actual use: the same meeting through a tabletop microphone.

| Fixture | Kind | WER | Critical info | Severe | RTF | Fallbacks |
|---|---|---|---|---|---|---|
| quiet-single-speaker | synthetic | 0.0% | 100% | 0 | 0.482 | 0 |
| fast-speech (280 wpm) | synthetic | 1.5% | 100% | 0 | 0.583 | 0 |
| doctor-visit | synthetic | 2.8% | 100% | 0 | 0.381 | 0 |
| noisy-restaurant | synthetic | 32.8% | 100% | 0 | 0.628 | 0 |
| family-dinner | synthetic | **51.0%** | **77.8%** | **2** | 0.532 | 0 |
| **ami-meeting** | **recorded**, close-mic | **16.0%** | **96.3%** | 0 | 0.470 | 0 |
| **ami-meeting-far** | **recorded**, far-field | **26.1%** | **55.6%** | **1** | 0.444 | 0 |
| ami-meeting-synth | synthetic twin | 9.2–12.6% | 67–100% | 0–1 | 0.4–1.0 | 1–5 |

The last row is a range because that fixture does not decode reproducibly — see Finding 2. Every
other row was bit-identical across runs.

Mean WER 17.8%, mean critical information 87.0%, 3 severe misses, 5 decode fallbacks — all from the
run above, so the two means move with the twin's instability by a point or so.

Accuracy is deterministic **on the fixtures that decode cleanly**. Seven of the eight returned
bit-identical word error rates across repeated runs. The eighth is `ami-meeting-synth`, which falls
back to higher decoding temperatures every time it runs, and a fallback re-decodes with sampling —
so its row is a sample rather than a measurement, and its score moved by 2.5 points of WER between
runs here. The `Decode fallbacks` column is the tell: non-zero means that row should not be
compared to a previous run's. Finding 2 is about why that fixture, of all of them, does this.

Latency is never that stable, and did vary: an earlier run of this suite shared the machine with
another build and reported real-time factors of 0.430–0.713 against 0.377–0.626 here, with identical
accuracy. The report prints a warning above the table when it detects that contention, so a
contaminated latency run cannot be mistaken for a real one.

### Finding 1: the synthetic fixtures, not the synthetic voices, are what make them unrealistic

The idea worth testing was that text-to-speech voices are harder for the model than human ones. The
three `ami-*` fixtures were built to settle it: `ami-meeting` and `ami-meeting-synth` share one
reference transcript **byte for byte**, the same four turn-takers, and the same turn timing. Only the
voices differ — four recorded people against four `say` voices, one per participant.

| | WER | Critical info | Names |
|---|---|---|---|
| `ami-meeting` — four recorded people | 16.0% | 96.3% | 8/9 |
| `ami-meeting-synth` — four `say` voices | 9.2–12.6% | 67–100% | 9/9 |
| `ami-meeting-synth`, attenuated to match loudness | 10.9–11.8% | 67–100% | — |

**The synthetic voices came out ahead.** They are not harder; if anything Whisper prefers them, which
matches the common finding that TTS audio is unusually clean and well-formed. The result survives
matching the twin's loudness to the real clip's (−30 LUFS), so it is not a level artifact either.

So the synthetic fixtures are unrealistic for a different reason, and the table above points at it:
`family-dinner` scores 51.0% while sitting **8.5 dB louder** in integrated loudness than the real
recording that scores 16.0%. What `family-dinner` has that a recorded meeting does not is its bed —
three complete, intelligible sentences laid 11.7 dB under the foreground, coherent enough to be
transcribed as content and loud enough to displace the foreground entirely for the last 14 seconds.
Real crosstalk in the AMI window occupies **1.6%** of speech time, between people who are all in the
same conversation.

The mechanism Finding 5 describes is real, and it is worth designing against. The magnitude measured
on a synthetic bed is not a number to plan around.

### Finding 2: text-to-speech makes the decode unstable, not inaccurate

`ami-meeting-synth` falls back to higher decoding temperatures on **every** run — 1 to 5 times. No
other fixture has ever produced a single fallback. A fallback re-decodes with sampling instead of
greedy search, so its result is not reproducible, and six runs of byte-identical input gave:

| | across six runs |
|---|---|
| Word error rate | 9.2% – 12.6% |
| Critical information | 100% five times, 66.7% once |
| Decode fallbacks | 1 – 5, never zero |

Every other fixture reproduced bit-identically. That qualifies a claim made earlier in this README:
accuracy is deterministic *except* where the decoder falls back, and the only fixture that falls back
is the synthetic one. The `Decode fallbacks` column is the tell — a non-zero count means that row is
a sample, not a measurement, and should not be compared against a previous run's.

The instability is a property of the audio rather than of the options: it persisted at both levels
tested. It is also not simply "many `say` voices", since `family-dinner` is three of them plus a bed
and decodes cleanly every time. What separates this fixture is not yet identified; a per-voice sweep
would settle it (see Known gaps). The practical consequence does not depend on the answer: **a
synthetic fixture cannot anchor a baseline**, because the number it produces depends on the run.

### Finding 3: input level is worth more than any model change available

`ami-meeting` arrives from the corpus quiet — −39.7 LUFS, 21 dB below the synthetic fixtures. Applying
one static gain of +9.8 dB, with nothing else changed:

| `ami-meeting` | WER | Critical information | Names |
|---|---|---|---|
| as the corpus ships it | 24.4% | 51.9% | 5/9 |
| one static gain to −1.5 dBFS peak | **16.0%** | **96.3%** | **8/9** |

That is a larger improvement than any model swap or decoding option tested here, for one number in
an ffmpeg command line. The app records its own audio, so this is entirely under its control: the
level handed to the recognizer is a design parameter, and the recording path should apply automatic
gain control rather than trusting whatever the microphone delivers.

Gain is not free, though. The far-field clip scored slightly *worse* normalized than at its native
level (23.5% → 26.1%), because lifting the signal lifts the microphone's noise floor with it. An AGC
that tracks speech level and does not simply maximize peak is the right shape; a naive one is not.

### Finding 4: far-field is the scenario, and it is the weak one

`ami-meeting` and `ami-meeting-far` are the same conversation recorded simultaneously through four
headset microphones and one tabletop array microphone. Same words, same speakers, same reference,
same level (peaks −1.4 and −1.5 dBFS). Only the microphone differs.

| | WER | Critical info | Names | Negations |
|---|---|---|---|---|
| headset microphones | 16.0% | 96.3% | 8/9 | 1/1 |
| one tabletop array microphone | **26.1%** | **55.6%** | **6/9** | **0/1** |

The far-field recording is the one that loses a negation outright — "that's David, Andrew and Craig,
isn't it?" loses the "isn't it" — and the one that turns "user interface" into "agent face". It also
produced no decode fallbacks and no instability; it is simply harder audio, and it fails on meaning
rather than on words. WER understates it by a wide margin: 10 points of WER separate the two, but 41
points of critical information do.

**The close-mic result is not the app's result.** A phone on a table is the far-field case.

### Finding 5: background speech becomes caption text, and the intelligible kind does real damage

This is the result to act on. The two noisy fixtures were built to be a controlled comparison:
both put their background at **the same level relative to the foreground** — 11.7 dB down in
`family-dinner`, 11.6 dB in `noisy-restaurant` — and differ only in whether that background is
followable. Measured in-mix, over windows containing no foreground speech:

| Fixture | Bed | Foreground | Bed is | Names | Numbers | Negations | Critical info |
|---|---|---|---|---|---|---|---|
| `family-dinner` | −33.4 dB | −21.7 dB | 11.7 dB down | 1/1 | — | **1/3** | **77.8%** |
| `noisy-restaurant` | −27.3 dB | −15.7 dB | 11.6 dB down | 1/1 | 1/1 | 2/2 | **100%** |

`family-dinner`'s bed is **babble**: a few voices taking turns, each sentence intelligible. Whisper
transcribed them as content. The foreground is transcribed correctly for the first 25 seconds and
then the bed **takes over completely** — the final 14 seconds of the recording are the background
conversation appearing on screen as if spoken to the user, and four foreground utterances vanish
with it, including both remaining negations:

```
[ 9.84s → 12.64s] We saved you a plate. The roast is still warm.     ← correct
[23.40s → 25.50s] Tell him you're with him. He works too hard.       ← "we missed him" already gone
[26.02s → 29.18s] I told him the car needs to go back to the back door this time.
[31.44s → 33.72s] Did you remember to lock the back door this time?
[33.90s → 36.72s] The gun region needs attention after all that rain.
[37.02s → 38.68s] And as you said, I was going to lock the back door by Tuesday.
```

Everything from 26.02 s on is the bed, which actually reads *"I told him the car needs a new battery
before winter"*, *"did you remember to lock the back door this time"*, *"the garden really needs
attention after all that rain"*, and *"the weather would turn by Tuesday"*. The foreground lines
that were displaced — *"I'll call him tomorrow and say hello"*, *"He'd like that. He never calls
anyone anymore"*, *"The garden looks lovely this year"*, *"The tomatoes did well. The peppers did
not"* — are simply gone, and nobody reading the caption could tell which half was the conversation
they were in.

`noisy-restaurant`'s bed is **crowd**: eight voices staggered to overlap, so no single one is
followable. It leaks too — one crowd line surfaces three times as *"The special today is the
lampshade"* (the bed reads *"the special today is the lamb shank"*) — but it does not take over.
The foreground stays recognisable throughout, and every name, number, and negation survives.

**So both conditions contaminate; only the intelligible one destroys the transcript.** The reading
that fits: Whisper has no notion of which speech is addressed to the user, but it will not invent
much from a wall of overlapping voices, whereas an intelligible sentence nearby is transcribed as
readily as the one in front of it. A family dinner, a waiting room, or a consulting room with a
second conversation in it is therefore the *dangerous* condition — not the loud restaurant.

Two of the three negations were lost to it: *"never"* was heard as *"did"* and *"not"* as
*"tuesday"* — the latter being a word from the bed, not from the foreground. That is exactly the
failure the critical information score exists to catch, and WER alone would have hidden which two
words mattered. Note also that the score is not infallible here: in `noisy-restaurant`, *"one at
noon"* became *"one at a time"* and still scored as a correct number, because the number word
survived and *noon* is not counted as one. Times and durations are worth adding to the scorer's
number category.

### Finding 6: turn segmentation recovers intended utterances

The 800 ms rule reproduced the scripted line boundaries exactly where the audio was clean —
9 blocks for the 9 doctor-visit lines, 4 blocks for 4 quiet-single-speaker lines. It degraded only
where background speech filled the gaps between turns: `family-dinner` gave 7 blocks for 12 lines,
`noisy-restaurant` 6 for 8. The segmentation logic is sound; the input is what defeats it.

### Finding 7: latency is comfortable, but streaming is still unproven

Real-time factor ran 0.377–0.626, so decoding keeps up with live speech with roughly 1.6× headroom
even before the model is tuned. Time to first word was 1.86–1.92 s — suspiciously uniform across
fixtures of very different difficulty, which is worth reading as a sign that this is what a
whole-file decode costs rather than a property of the audio.

**That comparison is not yet meaningful.** These figures are whole-file: the model waits for the
entire clip before emitting anything, so "time to first word" here measures a full decode, not a
streaming increment. Confirming or refuting the sub-200 ms the brief anticipates needs
`AudioStreamTranscriber` driven from a live source, which is not wired up yet (see Known gaps). The
headroom on an M2 Pro is also a proxy — an A17 Pro has a smaller Neural Engine, so treat these as
an upper bound.

The numbers are worth keeping as a regression baseline; they are not yet a verdict on the device.

### Finding 8: VAD chunking halves the severe misses, and costs almost nothing

`--vad` routes windowing through WhisperKit's energy-based `EnergyVAD`, which skips low-energy
stretches instead of decoding them. Decoding is deterministic, so these deltas are effects of the
option rather than run-to-run noise:

| Fixture | WER | → `--vad` | Severe misses | → `--vad` |
|---|---|---|---|---|
| quiet-single-speaker | 0.0% | 0.0% | 0 | 0 |
| fast-speech | 1.5% | 1.5% | 0 | 0 |
| doctor-visit | 2.8% | 4.2% | 0 | 0 |
| noisy-restaurant | 32.8% | **25.0%** | 0 | 0 |
| family-dinner | 51.0% | **50.0%** | **2** | **1** |

The single severe miss it removes is the one that matters most: *"The tomatoes did well. The
peppers did **not**."* comes back with its negation intact. Both metrics that carry consequence —
severe misses and critical information — improve on the two hard fixtures, and the clean fixtures
are untouched apart from a 1.4-point WER wobble on `doctor-visit` that changes no critical token.

This is surprising, and worth stating plainly: the design notes dismiss energy VAD as a poor fit
for a noisy room, on the grounds that background noise keeps energy high so silence is never
detected. On these fixtures it nonetheless helps, most likely because chopping a long window into
shorter ones stops one bad stretch from steering the whole decode — which is the shape of the
failure in Finding 1. It is currently opt-in (`--vad`); making it the default is the next change to
land, and WhisperKit's energy detector is still the wrong detector — see Known gaps.

## Layout

```
Sources/CaptionKit/
  Metrics/          WER, critical-information scoring, text normalization  (no WhisperKit dependency)
  Model/            Transcript, segments, words, latency — the app-facing model
  ASR/              WhisperKit engine wrapper, actor-isolated
  Segmentation/     Turn splitting on sustained silence
  Fixtures/         Fixture discovery and metadata
  Evaluation/       Fuses the three measurements into one report
Sources/CaptionHarness/   The CLI
Fixtures/                 Audio, reference transcripts, metadata — see Fixtures/README.md
Scripts/
  make-fixtures.sh        Regenerates the synthetic fixtures from their scripts
  make-ami-fixtures.sh    Cuts the recorded fixtures out of the AMI corpus, and their twin
  ami_annotations.py      Turns AMI word annotations into a reference transcript
```

The committed fixtures are 4.6 MB synthetic and 4.3 MB recorded. The AMI corpus they are cut from
is a 62 MB download, fetched on demand into a gitignored `.corpora/`.

`Metrics/` deliberately has no WhisperKit dependency, so the scoring logic is unit-tested without
loading a model, and a second recognizer could be scored by the same code.

## Design decisions worth knowing

**Turn segmentation is not diarization.** Every silence over 800 ms starts a new visual block. It
cannot tell who spoke — only that speech stopped and restarted. That is enough for the visual job
and costs a fraction of real diarization, which matters when this runs continuously on a phone.
WhisperKit does ship `SpeakerKit` if real speaker labels are ever wanted.

**Word timings are required, not optional.** Without them a turn can only break at recognizer
segment boundaries, and Whisper packs up to 30 seconds into one segment regardless of who was
speaking — so every speaker in that window collapses into a single block.

**Decode concurrency is pinned to 1.** WhisperKit defaults to 16 concurrent decode workers on
macOS. That is right for bulk transcription and wrong for measuring latency, because the reported
time then reflects many windows decoded in parallel rather than the wait a real user experiences.

## Known gaps

- **VAD is energy-based, not Silero.** WhisperKit 1.1.1 ships only `EnergyVAD`. The design called
  for Silero via CoreML/ONNX. Energy detection is a poor fit for a noisy room — background noise
  keeps energy high, so silence is never detected. `VoiceActivityDetector` is an `open` class and
  injectable through `WhisperKitConfig`, so Silero drops in behind the same interface. Not yet done.
  This matters more than it did before the first results: the `family-dinner` run showed that the
  dominant error is unsought speech, which is precisely what a speech-aware VAD could gate.
- **No streaming measurement yet.** The harness measures whole-file latency. True streaming
  latency needs a sliding-window loop; see the note in `WhisperEngine` about why WhisperKit's own
  `AudioStreamTranscriber` cannot be driven from a file.
- **Nothing from the target environment is recorded yet.** The `ami-*` fixtures are real speech in a
  real room, which closes most of the gap, but they are a research meeting: studio headset
  microphones on four cooperative adults. They are not a dining room, and they are not a phone on a
  table in a doctor's office. Recordings from the target device should still be added — by path,
  never committed; see `Fixtures/README.md`.
- **No fixture for intelligible background speech that is real rather than synthesized.** Finding 5
  says the dangerous condition is a nearby conversation that can be followed. The only fixture that
  reproduces it is built from `say` voices, and Finding 1 shows those fixtures overstate difficulty
  badly — so the *size* of that effect is an open question even though the mechanism is clearly real.
  A real recording of two overlapping conversations is what would settle it.
- **The twin's voices are not equally hard.** `ami-meeting-synth` mis-hears one participant
  consistently — "I'm Craig and I'm User Interface" comes back as "I'm great good I'm user
  interface". Some of the synthetic penalty may be one poor voice rather than text-to-speech in
  general; separating those needs a per-voice sweep.
- **No iOS target, no Xcode project.** A SwiftPM package cannot build an app target; the app will
  need an Xcode project depending on this package. `xcodegen` is installed for that.
- **`Swift 5` language mode.** Set explicitly in `Package.swift` to keep the bootstrap moving.
  Swift 6 strict concurrency would be worth adopting before the app is built.

## Verifying

```bash
make unit           # 88 tests, no model required
make test           # runs the fixtures and writes reports/latest.md
```
