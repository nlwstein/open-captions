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
make live                      # captions the microphone until Ctrl-C
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
| `make live` | Captions the microphone until Ctrl-C. `NAMES="mum,david"` highlights names |
| `make live-file` | Replays one fixture through the live loop: `FIXTURE=doctor-visit` |
| `list` | Show the fixtures and what each one covers |
| `transcribe <file>` | One file, with timestamps and latency. `--json` for machine-readable output |
| `evaluate <fixture>` | Score one fixture: WER, critical information, latency |
| `evaluate --all` | Every fixture, plus a summary. `--output <file>` writes JSON |
| `report <fixture>` | The markdown report on stdout, without running the `make` target |
| `live` | Live capture from the microphone, or `--from-file` to replay a recording |

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
decode worker, on an otherwise idle machine. Raw output of the latest run is committed as
`evaluations/baseline.json`; `make test` renders `reports/latest.md`, which is generated rather than
committed. Because one fixture does not decode reproducibly (Finding 2), the means below are quoted
as a range across runs.

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
| ami-meeting-synth | synthetic twin | **9.2–38.7%** | **44–100%** | 0–1 | 0.4–1.0 | 5 |

The last row is a range because that fixture does not decode reproducibly — see Finding 2. Every
other row was bit-identical across runs.

Mean WER **17.8–21.1%**, mean critical information **84.3–87.0%**, 3–4 severe misses, 5 decode
fallbacks. **The whole of that spread is the one synthetic twin.** Seven of the eight fixtures
returned bit-identical word error rates across every run; `ami-meeting-synth` alone moved the mean
by three points, because on its worst run it lost the back half of the conversation.

That fixture falls back to higher decoding temperatures on every run — all five decode fallbacks in
the summary belong to it — and a fallback re-decodes with *sampling* rather than greedily, so its
row is a sample, not a measurement. The `Decode fallbacks` column is the tell: non-zero means that
row should not be compared against a previous run's. Finding 2 is about why this fixture does it,
and Finding 10 is about what the fallback ladder does when it runs out — which is the same
mechanism, and the reason the swing is so large.

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

| | across seven runs |
|---|---|
| Word error rate | 9.2% – 38.7% |
| Critical information | 100% five times, 66.7% once, 44.4% once |
| Decode fallbacks | 1 – 5, never zero |

Every other fixture reproduced bit-identically. That qualifies a claim made earlier in this README:
accuracy is deterministic *except* where the decoder falls back, and the only fixture that falls back
is the synthetic one. The `Decode fallbacks` column is the tell — a non-zero count means that row is
a sample, not a measurement, and should not be compared against a previous run's.

**The 38.7% run is the one that explains the rest.** Its transcript stops mid-sentence — "And I'm
Andrew and I'm a marketing." — and the rest of the conversation is simply absent. That is the
fallback ladder being spent: WhisperKit retries a failing window at rising temperatures, and when
the last attempt fails too it returns that attempt anyway, which the segment seeker then judges
silent and discards. Finding 10 works through the mechanism; it is the same failure the live loop
has to defend against, and it is why one fixture can move the eight-fixture mean by three points.

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

### Finding 7: whole-file latency is comfortable, and streaming needed a different model

Real-time factor ran 0.377–0.626, so decoding keeps up with live speech with roughly 1.6× headroom
even before the model is tuned. Time to first word was 1.86–1.92 s — suspiciously uniform across
fixtures of very different difficulty, which is worth reading as a sign that this is what a
whole-file decode costs rather than a property of the audio.

**These figures are whole-file**, so that 1.9 s is a full decode rather than a streaming increment.
The sliding-window loop that answers the streaming question now exists — `make live` — and the
answer is in [Finding 9](#finding-9-live-capture-cannot-use-the-model-the-report-measures): on this
model it cannot keep up at all. The headroom on an M2 Pro is also a proxy, since an A17 Pro has a
smaller Neural Engine; treat it as an upper bound.

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
failure in Finding 1. It is currently opt-in (`--vad`), and WhisperKit's energy detector is still
the wrong detector — see Known gaps.

#### The two rows that did not move did not move because the flag never ran

**`--vad` is silently inert on any input of 30 seconds or less.** The two rows above that do not
move at all — quiet-single-speaker and fast-speech — are the only two fixtures shorter than 30 s,
and the flag cannot fire on an input that short. Their stillness is not evidence that VAD is safe on
clean audio; it is evidence that VAD was never applied.

The mechanism is one line. `WhisperKit.transcribe` decides whether to chunk at all before it looks
at the strategy (`WhisperKit.swift:1028`):

```swift
let isChunkable = audioArray.count > featureExtractor.windowSamples ?? Constants.defaultWindowSamples
switch (isChunkable, decodeOptions?.chunkingStrategy) {
    case (true, .vad):
```

`windowSamples` is the model's own audio input width — `Constants.defaultWindowSamples` is
`480_000`, which is exactly 30 s at 16 kHz (`Models.swift:1463`). Under that, `isChunkable` is
false, the switch falls through to the unchunked path, and `chunkingStrategy: .vad` is discarded
without a word. The flag is not degraded on short input; it is a no-op.

Checked against the fixture lengths, the table splits exactly where that line predicts: the two
fixtures under 30 s — quiet-single-speaker (14.7 s) and fast-speech (17.2 s) — are inert, and all
three that moved, including the 1.4-point wobble on doctor-visit, are over it (46.3 s, 30.9 s,
40.3 s). The split is too clean to be coincidence, and it is the reason `--vad` has **not** been made
the default. A flag whose effect depends on how long someone has been talking is not a setting: on a
live stream it means the decoder's behaviour changes at the 30-second mark, mid-sentence, with
nothing in the output to say which mode produced it.

The external evidence points the same way, which is what prompted the check: three independent
projects report WhisperKit's VAD chunking failing *silently* on long meetings — duplicated
sentences at fixed timestamps, truncation with no error, and empty windows for any clip ≤1.0 s. Those
are reports rather than reproductions, and none is on our fixtures, so this is a reason to test
before adopting rather than a reason to conclude. What is established here is narrower and does not
rest on them: the flag does nothing at all below 30 s.

## Live capture

`make live` captions the Mac's microphone until Ctrl-C: finished turns stack up as blocks of text,
the turn still being spoken sits beneath them in grey, and names, numbers and negations are coloured
as they arrive. `make live-file FIXTURE=doctor-visit` replays a fixture through the identical loop,
which is how the live path is tested without asking anyone to talk into a laptop.

Nothing here is scored — a live conversation has no reference transcript. It answers the other
question: whether the engine keeps up, and what that costs in accuracy.

### Finding 9: live capture cannot use the model the report measures

The report measures `large-v3-turbo`. The live loop cannot, and the difference is not a tuning
preference:

| Model | Mean WER | Mean critical info | Time to first word | Live-loop RTF |
|---|---|---|---|---|
| large-v3-turbo | 17.8% | 87.0% | 2054 ms | **3.40** |
| small | 28.5% | 78.3% | 169 ms | **0.12–0.42** |
| base | 32.1% | 71.6% | 171 ms | not run |

Time to first word is from a 10-second clip; the RTF column is from the live loop itself, decoding a
growing slice every few seconds. At 3.40 the queue of undecoded audio grows faster than the
recognizer drains it, so the text falls further behind the conversation for as long as it runs: on
`ami-meeting`, turbo took **170.9 s of wall clock to caption 46.7 s of audio**. `small` averages
0.5–1.5 s per decode and keeps up with room to spare. `live` therefore defaults to `small` and says
so on stderr; `--model` overrides it.

**That switch is the main open risk in this design.** `small` costs 11 points of mean WER and 9
points of critical information against turbo, and on `noisy-restaurant` it is far worse than a
smooth degradation — decoded whole-file, it returns *nothing at all* for the 30.9-second fixture.

### Finding 10: a decode that fails every retry returns its worst attempt, silently

WhisperKit retries a window that fails its quality checks at rising temperatures. Two things follow
that are easy to miss:

- **The ladder ends and returns anyway.** `TranscribeTask` tries `0...temperatureFallbackCount` and
  then returns whatever the last attempt produced, failed or not. Nothing is raised.
- **Those retries sample, not decode.** Despite the name, `GreedyTokenSampler` is greedy only at
  temperature 0: above that it scales the logits and takes a top-k multinomial draw
  (`TokenSampler.swift:49-58`). So a fixture that needs fallbacks does not decode reproducibly run to
  run, which is the effect `ami-meeting-synth` has shown all along.

So a window the decoder cannot handle at any temperature comes back as a result, and it is the
worst one. `SegmentSeeker` then judges it silent (`noSpeechProb > 0.6`, `avgLogProb <= -1.0`) and
advances the seek by a full 30 seconds, dropping the audio outright.

Note that fallbacks here are counted per *slice* by the live loop, so they are not comparable with
the whole-file `Decode fallbacks` column in the report — a different window, and the loop's retry
adds its own attempts. Finding 2's "no other fixture has ever produced a single fallback" is about
the whole-file harness, and still holds there.

Measured on a 15.1 s slice of `family-dinner` beginning at 25.2 s: **0 words, 5 fallbacks, three
runs out of three.** The same audio from 24.5 s gave 36 words with no fallback at all, and from
23.2 s gave 43. The loss is real and silent — and it is a property of *where the slice starts*, not
of the audio in it.

### Finding 11: the live loop now loses no speech at all

Because the failure depends on the slice start rather than the audio, it is recoverable: when a
decode returns no new words over audio the level meter called speech, the loop re-decodes from two
seconds earlier. Repeating the identical decode would land on the identical failure; moving the
start does not.

Across all eight fixtures, that guard rescued 4 slices and lost 0:

| Fixture | Audio | After the last word | Of that, heard as speech | Slices rescued |
|---|---|---|---|---|
| ami-meeting | 46.7 s | 0.7 s | 0.0 s | 0 |
| ami-meeting-far | 46.7 s | 0.7 s | 0.7 s | 1 |
| ami-meeting-synth | 46.7 s | 4.1 s | **0.0 s** | 1 |
| doctor-visit | 46.3 s | 0.3 s | 0.1 s | 0 |
| family-dinner | 40.3 s | 0.5 s | 0.5 s | 1 |
| fast-speech | 17.2 s | 0.3 s | 0.3 s | 0 |
| noisy-restaurant | 30.9 s | 0.4 s | 0.2 s | 1 |
| quiet-single-speaker | 14.7 s | 0.4 s | 0.2 s | 0 |

The two columns are the point of the measurement. "After the last word" counts audio the transcript
never reached, which is trailing silence on most fixtures. "Heard as speech" is how much of that the
level meter judged to be speech — the column that would be large if speech had been missed. It was
**11.1 s on `family-dinner` before the guard existed, and 0.5 s after.** `ami-meeting-synth` shows
the columns diverging the other way: 4.1 s of tail that the meter says is silent, confirmed by
transcribing it standalone (`[BLANK_AUDIO]`, no fallbacks).

One incidental result worth keeping: on `noisy-restaurant`, `small` **decoded whole-file returns
nothing**, but the same model in the live loop returns a usable transcript — "Yes, they're in my
bag. I never forget them now." and "I know. I'll take it when we get home." come back verbatim.
Short slices plus the recovery guard beat one long window on the hardest fixture in the set. A fixed
30-second window is not the neutral default it looks like.

### Finding 12: on non-speech, `small` and `base` invent turns, and the loop prints them

The live loop shows whatever the decoder returns. Given audio that contains no speech, it returns
filler, and there is nothing between the two — no confidence check, no speech probability, no list of
known artefacts. Twelve seconds of pink noise at room-tone level, through the identical harness
(`--from-file`, so the input is byte-identical for each model):

| Model | Emitted | Reached the transcript | Live RTF |
|---|---|---|---|
| base | `[BLANK _AUDIO]` | **yes** | 0.41 |
| small | `[no audio]` | **yes** | 0.30 |
| large-v3-turbo | nothing, on all four decodes | no | 1.59 |

This is not an artefact of synthesised noise. Two runs against the Mac's own room tone with nobody
speaking produced `[BLANK _AUDIO]` and `[INAUDIBLE]`. Warm-up is not the cause: the run that
hallucinated `[INAUDIBLE]` used `--no-warm-up`, and neither run echoed the fixture text the warm-up
had just decoded.

The timestamps give it away. `base` put its last word at **29.1 s inside a 12.0 s slice**; on the
microphone, 29.4 s inside an 11.8 s one. The decoder is not reporting on audio it heard.

Turbo's silence is the informative result: it is the model behaving, not the library. WhisperKit
*looks* like it filters these windows and does not. `SegmentSeeker` skips a window when
`noSpeechProb > 0.6`, but WhisperKit never populates the field — `TextDecoder.swift:821` reads
`let noSpeechProb: Float = 0 // TODO: implement no speech prob`. So the skip is unreachable, the
`DecodingFallback` silence branch is dead code, and `noSpeechThreshold` cannot fire under any input.

**This is a library gap, not a model choice, and it is not our bug to investigate further** — the
maintainers have tracked it since 2024 (issue #27, still open) and a fix was only opened as an
unmerged PR on 2026-10-10. The measurement above is unaffected either way: `small` is confidently
wrong on non-speech, so even a working no-speech check would be overridden by the `avgLogProb`
escape hatch that `SegmentSeeker` applies next.

The related gap matters more for the fix. OpenAI Whisper suppresses roughly 80 non-speech tokens by
default, which is what stops `[BLANK_AUDIO]` being generated at all; WhisperKit ships
`self.suppressTokens = suppressTokens ?? [] // nonSpeechTokens() // TODO: implement these as default`
(`Configurations.swift:240`), and `nonSpeechTokens()` does not exist in the package. So the decoder
is free to emit these tokens and the harness has to catch them after the fact — which is what
`SpeechGate` does below. Passing an explicit `suppressTokens` list is the untried alternative and
would prevent the text rather than discard it.

#### The fix, and the measurement that rejected the first version of it

`SpeechGate` now sits between the decoder and the screen. Its first version was wrong in a way worth
recording, because the wrongness is the finding.

Calibrated on near-field speech and room tone, the numbers looked like a clean gap:

| Audio | Text | `noSpeechProb` | `avgLogprob` |
|---|---|---|---|
| room tone | `[no audio]` | 0.00 | −0.48 … −0.62 |
| room tone | `[BLANK _AUDIO]` | 0.00 | −0.37 … −0.50 |
| speech, near field | the fixture's four lines | 0.00 | −0.18 … −0.21 |
| **speech, far field** | **`ami-meeting-far`** | 0.00 | **−0.41 … −0.70** |

Two rows were missing from that table, and they change the conclusion twice over.

**`noSpeechProb` is not a discriminator at all** — it read 0.00 for every row, filler included. That
is the measurement explaining why WhisperKit's own silence check cannot help here, and it is why the
gate cannot simply reuse it.

**Mean log-probability cannot carry the decision either.** On the first three rows a threshold of
−0.40 looks like it sits in a gap. Add the far field and the distributions overlap almost entirely:
real speech in a real room runs from −0.41 down to −0.70, which is inside the filler range. At −0.40
the gate threw away this, from `ami-meeting-far`:

> Well, this is the kickoff meeting for our project. And this is just what we're going to be doing
> over the next 25 minutes.

A complete and correct transcription of the fixture's opening, discarded. **A gate that eats real
speech is worse than the hallucination it was built to stop**, because the reader cannot tell what
was lost — and far field is the scenario the app exists for (Finding 4), not an edge case.

So the rule was demoted. The work is done by the structural test — *is the whole utterance one
bracketed annotation?* — which caught every hallucination actually observed and fired on none of the
real far-field speech. `avgLogprob` survives only as a backstop set below the worst real speech
measured, where it can catch gross decoder failure and nothing else. Both are pinned by tests,
including `testKeepsFarFieldSpeechThatAnEarlierVersionThrewAway`, which uses the dropped sentence
above as its fixture.

The transferable lesson: **a threshold calibrated on two conditions is not calibrated.** The
near-field rows were not a small gap, they were half a distribution.

### Finding 13: the opening seconds of a session are not captured at all

`live` loads and warms the model *before* it opens the audio source, so the microphone is not live
until that finishes. Whatever is said in the meantime is not misheard — it is absent.

Measured by padding `quiet-single-speaker` with ten seconds of digital silence
(`adelay=10000:all=1,apad=pad_dur=6`, verified with `silencedetect`), then playing it aloud into the
microphone from the same shell command that starts the capture, so playback and capture cannot race:

- capture began **≈2.1 s into playback** — 28.6 s captured against 30.7 s played
- all four lines came back verbatim, `Good morning!` included
- the same fixture with no lead lost `Good morning.` in both earlier runs, capture having started
  ≈0.65 s in

So the earlier miss was never acoustic, and never the room: it is startup latency, and it lands
exactly where it hurts. On the phone the first thing said is the thing that prompted the button
press, and it is the one sentence guaranteed to fall inside the warm-up.

**Fixed**, and the fix turned out to be three lines. `LiveTranscriber.run` now opens the stream and
*then* runs the warm-up, which it takes as a closure. The stream buffers unboundedly, so the model
load is paid in latency rather than in lost words — the opening sentence arrives a second late
instead of not at all. The ordering is the whole fix; no new component was needed, because the
buffering that made it possible was already there.

Replayed through `--from-file` the same padded file gives four clean turns, 0 recoveries and RTF
0.08, identical warm and cold — which is also the regression test for this path.

### Finding 14: cheap acoustic features cannot group speakers, and the measurement that said they could was measuring the wrong voices

Speaker grouping is the app's only visual structure — a caption aid that cannot show *who* is
talking is a wall of text. Every way of building it rests on one assumption: that a person sounds
more like themselves than like anyone else in the room. `Scripts/speaker_signal.py` tests that
directly, on isolated per-turn audio, so a failure cannot be blamed on segmentation.

Two hand-rolled features — median F0 by autocorrelation, and a 12-band mel-spaced energy profile.
They were chosen because they are cheap, but nothing below turns on cost: the target is an iPhone
15 Pro Max or newer, where an expensive component is acceptable as long as it keeps up **in real
time**. So this is not a search for a cheaper way to do it. It is a test of whether the raw acoustics
carry the answer at all. Distance is measured between pairs of turns by the same speaker against
pairs by different speakers; **overlap** is the share of different-speaker pairs sitting closer
together than the median same-speaker pair, so 50% is a coin flip.

| Audio | Feature | Same speaker | Different speakers | Overlap |
|---|---|---|---|---|
| `ami-meeting`, real, headset | F0 Δ | 37.5 ± 29.7 Hz | 57.1 ± 36.7 Hz | 29% |
| `ami-meeting`, real, headset | band cosine | 0.0345 | 0.0371 | **52%** |
| `ami-meeting-far`, real, array | F0 Δ | 69.5 ± 67.8 Hz | 99.7 ± 58.5 Hz | 14% |
| `ami-meeting-far`, real, array | band cosine | 0.0475 | 0.0519 | **52%** |
| synthetic twin, `say` voices | band cosine | 0.1011 | 0.1735 | 20% |

On real speech the band profile is a coin flip: same-speaker and different-speaker distances are
the same number to three decimal places. F0 looks better until the distributions are read — the
same-speaker spread (29.7 Hz on headset, 67.8 Hz far-field) is most of the way to the
different-speaker spread, so the 14–29% overlap flatters it.

The reason is visible in the per-turn figures. Speaker B in `ami-meeting` measures 190, 195, 198,
**213** and **232** Hz across five turns — a 42 Hz spread within one person, whose 232 Hz turn is
*"want to introduce yourself again?"*. F0 is tracking **intonation**, not identity: a question from
a low-pitched speaker overtakes a statement from a high-pitched one. The band profile fails for the
complementary reason — a 12-band energy average over a whole turn is mostly a function of which
vowels the sentence happens to contain. Both features measure *what was said* far more than *who
said it*, which is the well-known reason speaker recognition uses trained embeddings rather than
raw acoustics.

**The first version of this measurement said the opposite, and the reason is worth keeping.** It
read `.fixture-build/ami/turn_NNN.caf` and called those turns real speech. They are not:
`make-ami-fixtures.sh` renders them with `say`, one fixed macOS voice per participant, as the
synthetic twin. On those, band cosine separated cleanly — 0% overlap once turns under half a second
were excluded. That number was an artifact of text-to-speech, where a voice is bit-for-bit the same
speaker every time it talks, and it would have been recorded as a finding about people. The corrected
run reverses it. Measuring the twin is still worth doing, but only ever *against* the real set.

The conclusion is not "try harder on features", and it is not a cost problem to be traded away
against quality — the failing quantity here is accuracy, and a bigger compute budget does not buy
it. Hand-rolled acoustics are the wrong instrument because they measure the sentence rather than the
speaker. A trained embedding is the right one: `SpeakerKit` ships inside the WhisperKit package as
an exposed product, and is the remaining candidate. Its accuracy on these fixtures is
**unmeasured** — as is its real-time factor, which is the only cost question that matters here.

## Layout

```
Sources/CaptionKit/
  Metrics/          WER, critical-information scoring, text normalization  (no WhisperKit dependency)
  Model/            Transcript, segments, words, latency — the app-facing model
  ASR/              WhisperKit engine wrapper, actor-isolated
  Segmentation/     Turn splitting on sustained silence
  Live/             Capture sources, level meter, the sliding-window loop
  Fixtures/         Fixture discovery and metadata
  Evaluation/       Fuses the three measurements into one report
Sources/CaptionHarness/   The CLI
Fixtures/                 Audio, reference transcripts, metadata, speaker annotations
Scripts/
  make-fixtures.sh        Regenerates the synthetic fixtures from their scripts
  make-ami-fixtures.sh    Cuts the recorded fixtures out of the AMI corpus, and their twin
  ami_annotations.py      Turns AMI word annotations into a reference transcript
  speaker_annotations.py  Writes Fixtures/annotations/ — who spoke each reference line
  speaker_signal.py       Measures whether cheap acoustic features separate the real speakers
```

The committed fixtures are 4.6 MB synthetic and 4.3 MB recorded. The AMI corpus they are cut from
is a 62 MB download, fetched on demand into a gitignored `.corpora/`.

`Metrics/` deliberately has no WhisperKit dependency, so the scoring logic is unit-tested without
loading a model, and a second recognizer could be scored by the same code.

## Design decisions worth knowing

**Turn segmentation is not diarization.** Every silence over 800 ms starts a new visual block. It
cannot tell who spoke — only that speech stopped and restarted. That is enough for the visual job
and costs a fraction of real diarization, which matters when this runs continuously on a phone.
WhisperKit does ship `SpeakerKit` if real speaker labels are ever wanted — and Finding 14 measured
that the cheap alternative does not work on real speech, so real diarization is not a nicety to reach
for later. **A streaming one has now been measured, and it works in a meeting room but not yet in a
home:** Parakeet's LS-EEND gets 68–81% of two-second-plus turns right on complete far-field AMI
meetings, but **48%** on ten DiPCo dinner-table sessions — while the *same conversation* through the
participants' close-talk headsets scores 68%. The room is the loss, not the model, and a phone on a
table is the room. It is also only that good on its `dihard3` variant, which is not the default. See
[ENGINES.md](ENGINES.md).

**Word timings are required, not optional.** Without them a turn can only break at recognizer
segment boundaries, and Whisper packs up to 30 seconds into one segment regardless of who was
speaking — so every speaker in that window collapses into a single block.

**Decode concurrency is pinned to 1.** WhisperKit defaults to 16 concurrent decode workers on
macOS. That is right for bulk transcription and wrong for measuring latency, because the reported
time then reflects many windows decoded in parallel rather than the wait a real user experiences.

**The live loop decodes inline rather than on a timer.** A decode blocks the loop that reads audio,
so chunks queue behind it and the session shows up as lag rather than as missing words. Falling
behind is a display problem; dropping audio is a correctness problem, and only one of those can be
fixed by waiting.

**Live turns are committed, never revised.** A turn is final once at least 800 ms of audio has
arrived after its last word with no further words in it — the same rule the offline harness scores
with. The turn still
being spoken is shown in grey and replaced on each decode, so the screen never rewrites text the
user has already read. The commit point advances by *word start*, not word end, because each decode
re-aligns the audio and the word on the boundary returns with timings shifted a few hundredths of a
second later — which printed it twice ("…I'm the project manager." followed by a one-word turn
reading "manager.").

## Known gaps

- **VAD is energy-based, not Silero.** WhisperKit 1.1.1 ships only `EnergyVAD`. The design called
  for Silero via CoreML/ONNX. Energy detection is a poor fit for a noisy room — background noise
  keeps energy high, so silence is never detected. `VoiceActivityDetector` is an `open` class and
  injectable through `WhisperKitConfig`, so Silero drops in behind the same interface. Not yet done.
  This matters more than it did before the first results: the `family-dinner` run showed that the
  dominant error is unsought speech, which is precisely what a speech-aware VAD could gate.
- **The gate is structural, so it only stops hallucinations that look like artefacts.** Finding 12:
  `SpeechGate` removes bracketed filler, which is every hallucination observed so far, and no
  threshold on the decoder's confidence can safely do more — the measured distributions of real
  far-field speech and filler overlap. A *fluent* hallucination ("Thank you for watching.") would
  still reach the screen. Catching those needs a signal not yet tried: per-word probability, the
  audio-level history, or an n-gram repetition check. **An untried alternative sits upstream of all
  of them:** passing an explicit `suppressTokens` list, which is what OpenAI Whisper does by default
  and what WhisperKit leaves as a `TODO` (Finding 12). That would stop the tokens being generated
  rather than discard them after the fact, and it is a one-line experiment.
- **`SpeakerKit` is batch-only and is not the way to live speaker labels.** It ships inside the
  WhisperKit package and is unused here. Its public surface is a single whole-array
  `SpeakerKit.diarize(audioArray:)` with no session, no partial output and no windowing, so it can
  only label *completed* audio — the wrong shape for a caption that must colour a turn while it is
  still being spoken. Its open issues cluster on exactly the join between its segments and ours,
  including "the last turn is attributed to the wrong speaker" (a tail-padding effect, and the tail
  is always the turn on screen). The vendored copy's embedder and clustering types are `internal`,
  so a hand-rolled streaming wrapper on top of them is not available either. **A different engine is
  the alternative, and it has now been measured — see [ENGINES.md](ENGINES.md).** Parakeet's 0.6B TDT
  model runs this fixture set at a real-time factor of 0.009, and its streaming LS-EEND diarizer
  labels turns correctly at **68–81% for turns of two seconds or more**, far-field, at 150× realtime
  across two complete real meetings. Speaker grouping has a measurement rather than an assumption,
  and it comes with two caveats that each cost real time to find. **LS-EEND defaults to
  `ls_eend_ami`, which collapses to one cluster on far-field audio — 4% and 12% on those meetings,
  against `dihard3`'s 42% and 44% flat.** And a flat figure is the wrong figure: about half the
  turns in a real meeting are shorter than the diarizer's 500 ms step and cannot be resolved, which
  is what drags the flat number down while the turns anyone would read score far higher. **And the
  68–81% is an AMI number.** On ten DiPCo dinner-table sessions it is **38% flat and 48% for turns
  of two seconds or more**, ranging 26–65% between sessions, with only 53 of 7,078 turns shorter
  than the diarizer's step — so unlike AMI, the flat figure is not a resolution artefact. There the
  explanation is the room: the same conversation, same reference, same model, run on a mix of the
  four close-talk headsets, finds exactly four clusters in a clean one-to-one and scores 58%/68%.
  Splitting length and overlap together prices the two causes — on turns that are **both** ≥ 2 s and
  uncontested, DiPCo scores **54% against AMI's 72%**, so the room is worth about eighteen points,
  while two thirds of DiPCo's turns have someone talking over them and those cost about twelve more.
  A colour that is right half the time on the turns someone would read is worse than no colour, so
  **speaker identity is not shippable on the strength of the AMI result**, and the honest
  alternatives are showing turn changes without claiming who, or treating diarization as the feature
  to solve first. See [ENGINES.md](ENGINES.md); `Scripts/diarization_score.py`,
  `Scripts/ami-farfield-benchmark.sh` and `Scripts/dipco-farfield-benchmark.sh` produce the numbers.
- **Only `small` has been run live on speech.** `base` and `large-v3-turbo` have now been through the
  loop on non-speech (Finding 12), but neither has captioned a fixture: `base` was measured offline
  only, and turbo cannot keep up. Whether an intermediate model is the better trade — turbo's
  accuracy at a rate the loop can sustain — is unresolved, and it is still the first question after
  the gate above.
- **The live loop has never been run on real conversational audio.** Every number in Findings 9–11
  comes from replaying the fixtures through `--from-file`. In the microphone runs the audio was still
  a fixture played out of the speakers. That exercises the buffering, the turn rule, the recovery
  path, the room and the capture startup, but not a person who does not know they are being
  captioned.
- **The live RTF figures are from an M2 Pro.** An A17 Pro's Neural Engine is smaller, so the margin
  between `small` at 0.42 and the wall at 1.0 is the number that must be re-measured on device.
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
make unit           # 116 tests, no model required
make test           # runs the fixtures and writes reports/latest.md
make live-file FIXTURE=family-dinner   # the live loop, replayed, with per-decode diagnostics
```

**Run live measurements alone.** The live loop is a real-time system, so anything else on the
machine changes what it measures. This is not a theoretical caution: a fixture sweep run alongside
an unrelated batch analysis reported `family-dinner` losing its last three turns — 11.1 s of speech
never shown — and it looked exactly like the `SpeechGate` eating real speech. Re-run on an idle
machine, the same fixture and the same flags gave **zero drops and a 0.5 s tail**, and so did all
four cells of the warm-up × gate matrix around it.

What happened is worth knowing, because the failure was informative rather than random. Under CPU
contention the decoder exhausts its fallback ladder and returns an empty result, which the gate
correctly discards — so `gatedDecodes` rises and the transcript loses its tail. The drop count was
measuring how busy the machine was. The same signature is visible directly: a decode logged as
`0 words (0 decoded) … lp +0.00 cr 0.00 t 1.0`.

The tell is the real-time factor. The contended `family-dinner` run reported 0.53 against 0.24–0.29
for the same fixture on an idle machine. **A live RTF well above its own baseline means the numbers
are not comparable**, whatever else they say.
