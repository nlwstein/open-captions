# Engine comparison: WhisperKit vs Parakeet

**Bottom line: Parakeet's 0.6B TDT model is roughly 60× faster than the WhisperKit model the app
currently uses, at comparable accuracy — and it wins clearly on the only *real* recordings in the
fixture set.** That changes what the app can afford to do. It does not yet make Parakeet the engine:
it loses badly on two synthetic fixtures, and the reason for that split is unresolved. Read the
caveats before acting on the headline.

Everything here was measured on the M2 Pro, against the eight fixtures, using this repo's own scorer
(`caption-harness score`, see below) so the numbers are directly comparable to `reports/latest.md`.

## The numbers

| Engine | Model size | Mean WER | Mean critical info | Real-time factor |
|---|---|---|---|---|
| **WhisperKit** `large-v3-turbo` | 809M | **17.9%** | **87.0%** | 0.571 |
| **Parakeet TDT v3** (batch) | 614M | 22.3% | 78.3% | **0.009** |
| Parakeet EOU 120M, 320 ms chunks (streaming) | 120M | 31.3% | 72.9% | 0.17 |
| Parakeet EOU 120M, **160 ms — its default** | 120M | 42.1% | 59.8% | 0.17 |

Real-time factor below 1 means it keeps up with speech as it is spoken. WhisperKit's is the figure
our live loop measures, with decode workers pinned to one — see the fairness caveat.

Per fixture, WER:

| Fixture | Real? | WhisperKit | Parakeet TDT | Difference |
|---|---|---|---|---|
| ami-meeting | **real** | 16.0% | **5.9%** | −10.1 |
| ami-meeting-far | **real** | 26.1% | **12.6%** | −13.5 |
| ami-meeting-synth | synth | 12.6% | **11.8%** | −0.8 |
| doctor-visit | synth | **2.8%** | 4.2% | +1.4 |
| fast-speech | synth | 1.5% | 1.5% | 0.0 |
| quiet-single-speaker | synth | 0.0% | 0.0% | 0.0 |
| noisy-restaurant | synth | **32.8%** | 67.2% | +34.4 |
| family-dinner | synth | **51.0%** | 75.0% | +24.0 |

**Parakeet wins every fixture that is a real recording and loses every fixture where the gap is
large.** That is the whole result, and it points in two directions at once. Either Parakeet is better
on real speech and the synthetic fixtures are misleading — which Finding 1 already argues — or
something about text-to-speech audio defeats its front end specifically, in which case the synthetic
fixtures are telling us about a real weakness that our real fixtures are too easy to expose.

Both hypotheses survive this data. Nothing measured here separates them, and that is the main reason
this is a comparison rather than a migration.

## What is solid regardless of that split

**Speed is not close, and it is measured on long audio.** Parakeet TDT transcribed all 289.4 s of
the fixture set concatenated into one file in **2.61 s — a real-time factor of 0.009, about 111×
realtime**. The per-fixture runs (0.26–0.99 s each) agree, and that is on a 614M-parameter model
doing a full batch decode, not a toy.

The practical consequence: the app currently fails to keep up on one fixture
(`ami-meeting-synth`, RTF 1.046 — the transcript falls behind while someone is still talking). At
0.009 there is room for a second model, a diarization pass and a re-decode of the whole session, all
inside real time. **Engine headroom has stopped being the binding constraint**, which is the single
most useful thing this evaluation produced.

**Parakeet EOU's default chunk size is wrong.** The streaming model ships at 160 ms and that is its
worst setting by a wide margin — 42.1% mean WER against 31.3% at 320 ms. On `family-dinner` the
default does not merely do worse, it returns **nothing at all**, reproducibly, across repeated runs;
320 ms returns text on the same audio. The upstream doc comment claims the opposite ordering
("~5.73% WER" at 320 ms, "8-9%" at 160 ms on LibriSpeech), so this is not a tuning subtlety — the
shipped default silently produces an empty transcript on the hardest realistic input.

**Streaming costs a lot of accuracy here.** EOU is the only genuinely streaming ASR in the package
and it is ~10 points of WER behind its own non-streaming sibling at best. Its end-of-utterance signal
is also latched — it confirms once per session and then never again until `reset()`
(`StreamingEouAsrManager.swift:320-322`, and `eouDetected` is cleared only in `reset()`), and the
confirmation callback hands back the *accumulated* transcript rather than the utterance. Both are
workable, and both mean the turn-splitting logic stays ours, as it is now.

## Speaker grouping: the default model was one failure; **the room is another**

**On ten DiPCo dinner-party sessions — real people, a dining table, piped-in music, genuine overlap —
one colour per speaker is right 36% of the time overall and about half the time on turns long enough
to read, against 68–81% on the AMI meetings. The AMI number flattered the room.** Everything below
the AMI results establishes that, and the short version is the tables at the end of this section.

**Correction.** An earlier version of this section reported that LS-EEND groups a headset recording
at 77% and a tabletop-array recording at 8%, and concluded that far-field diarization was the wall.
That conclusion was wrong, and the reason it was wrong is worth keeping: `lseend` has four variants
and **defaults to `ls_eend_ami`**, which is the single worst of them on distant microphones. Every
figure below the headline came from a run that never passed `--variant`. Passing it changes the
answer completely.

| Variant | ami-meeting (headsets) | ami-meeting-far (array) |
|---|---|---|
| `ami` — **the default** | **10/13 — 77%** | **1/13 — 8%** |
| `dihard3` | 9/13 — 69% | **9/13 — 69%** |
| `callhome` | 8/13 — 62% | 8/13 — 62% |
| `dihard2` | 8/13 — 62% | 9/13 — 69% |

The default is the best on headsets and catastrophic on the array. Every other variant is
*consistent* across the two channels, and `dihard3` is the one to use: 69% on both.

Scored with `Scripts/diarization_score.py` against `Fixtures/annotations/`, which pairs each
reference line with who actually said it. The score is computed after choosing the best possible
relabelling of the diarizer's clusters, so it is an upper bound rather than a pessimistic one.

**What `dihard3` misses on the far-field fixture is one speaker and two backchannels.** It finds
three clusters where there are four — C is never found at all, and both of C's turns (30.39–31.57,
31.57–33.11) land on D. The other two misses are D's sub-0.4 s backchannels ("Mm-hmm." 0.24 s and
"Great" 0.35 s), one falling in a gap and one absorbed into the long turn around it. Every longer
turn by every other speaker is correct. For a caption aid that is a much better failure profile than
the number suggests: the losses are a quiet participant and two acknowledgements too short to be
worth a colour of their own.

**Two alternative explanations were tested and both are ruled out.**

- *Audio level.* The obvious one, and the one this repo's Finding 3 would predict. It is not it: the
  two recordings measure mean −30.5 dB against −29.7 dB, peak −1.5 dB on both.
- *A single array element is unfairly hard.* `Array1-01` is **one element** of AMI's eight-element
  circular array, not a beamformed mix, and a real phone does not hand the diarizer one raw capsule.
  So all eight elements were downloaded and summed into a single channel, peak-normalised to the same
  −1.5 dB, and re-run: **the scores are identical, variant for variant** (69/62/69/8). The diarizer's
  behaviour does not depend on which element, or how many, it is given.

That second result is the reassuring one. The 69% is not an artifact of the channel we happened to
pick, and it means the number is a property of the model and the room rather than of our fixture.

**Speed is not a consideration either way** — 167× realtime on the headset fixture, 146–166× across
all variants and channels. Diarization is free at this scale.

### The 69% does not survive whole meetings — and the reason matters more than the number

Thirteen turns in a hand-cut 47-second window cannot support a percentage, and picking the window is
a judgement call that can flatter whichever model is being measured. So the same question was asked
of **two complete meetings**, scored turn by turn against the corpus's own annotations — 2,343 turns
in one, 382 in the other, no window chosen at all:

```bash
Scripts/ami-farfield-benchmark.sh EN2001a TS3003a --variant dihard3
```

| | EN2001a — 87 min, 5 speakers | TS3003a — 25 min, 4 speakers |
|---|---|---|
| all turns | 978/2343 — **42%** | 167/382 — **44%** |
| turns ≥ 2 s | 386/567 — **68%** | 85/105 — **81%** |
| turns ≥ 5 s | 208/278 — 75% | 41/46 — 89% |

The flat figure is nearly twenty points below the window's 69%, and the obvious reading — far-field
diarization is worse than we thought — is the wrong one. **About half the turns in a real meeting are
shorter than half a second**, which is the diarizer's own step size, so it cannot resolve them by
construction. Accuracy rises monotonically with turn length in both meetings:

| Turn length | EN2001a | TS3003a |
|---|---|---|
| 0–0.5 s | 312/1109 — 28% | 31/146 — 21% |
| 0.5–1 s | 131/377 — 35% | 24/74 — 32% |
| 1–2 s | 149/290 — 51% | 27/57 — 47% |
| 2–5 s | 178/289 — 62% | 44/59 — 75% |
| ≥ 5 s | 208/278 — 75% | 41/46 — 89% |

That also reconciles the window with the meetings, which is the part worth keeping: **the 47-second
clip was never lucky.** Its thirteen turns are all long, so it measured the ≥ 2 s band and got 69%
— squarely between the 68% and 81% those meetings show for the same band. The window and the full
meetings agree. Only the flat average disagrees, and it disagrees because it is averaging in 1,109
turns of "Mm-hmm."

**What this means for the app is better than the headline suggests.** A caption aid colours turns
someone is going to read; the sub-half-second backchannels are not those turns. In the band that
matters the diarizer is right roughly seven to eight times in ten, on real meetings, far-field, at
150× realtime. The failure it does have is the one to expect from a 500 ms step: it merges a quick
"Mm-hmm" into the long turn around it, which loses a colour nobody needed.

**The default variant's collapse is confirmed at meeting scale, and it is not a window artefact
either.** On the same two meetings, `ami` scores **4%** (94/2343, finding 1 cluster where there are
5) and **12%** (47/382, 1 where there are 4). Every length band is flat near zero, which is what a
model that has stopped discriminating looks like — as opposed to `dihard3`'s clean gradient. The
footgun below is the single most expensive thing in this document.

**A footgun worth carrying forward:** the default variant is the one that fails. Anyone who runs
`fluidaudiocli lseend` without `--variant` and tests on distant microphones will conclude, as this
document did, that far-field diarization does not work. It is worth checking whether the library's
Swift API exposes the same default.

### DiPCo: the same measurement at a dinner table, and it is much worse

AMI is design meetings in an instrumented room. The app is for a family dinner in a home, so the
question "does the room matter" is not academic. **DiPCo** is ten sessions of four Amazon volunteers
around a dining table, recorded for Interspeech 2020 — a *simulated* dinner party (the corpus says
so), but with a real dining table, real overlapping conversation, music piped into several sessions,
and five seven-microphone devices around the room. It is a different room and a different kind of
speech from AMI, and it is the closest public audio to this app's setting. Note that it is not
literally a home: "in a home" would be a claim the corpus does not make. All ten sessions were
scored the same way, `dihard3`, whole session, no window chosen:

```bash
Scripts/dipco-farfield-benchmark.sh S01 S02 S04 S07 S08 --device U01
Scripts/dipco-farfield-benchmark.sh S03 S05 S06 S09 S10 --device U04
```

| | DiPCo — ten dinner-table sessions | AMI — two meetings |
|---|---|---|
| all turns | 2,709/7,078 — **38%** | 42% / 44% |
| turns ≥ 2 s | **48%** | 68% / 81% |
| one colour per speaker | **36%** | 39% / 44% |

Per session, the ≥ 2 s figure ranges from **26% (S07) to 65% (S10)** — a factor of two and a half
between two sessions of the same corpus. A single number is the wrong shape for this result; the
spread is the result.

| Turn length | DiPCo | AMI (EN2001a) |
|---|---|---|
| 0–0.5 s | 17/53 — 32% | 312/1109 — 28% |
| 0.5–1 s | 591/2154 — 27% | 131/377 — 35% |
| 1–2 s | 588/1796 — 33% | 149/290 — 51% |
| 2–5 s | 807/1721 — 47% | 178/289 — 62% |
| ≥ 5 s | 706/1354 — 52% | 208/278 — 75% |

The gradient is in the same direction and much shallower. **And the AMI explanation does not apply
here**: only 53 of DiPCo's 7,078 turns are shorter than the diarizer's 500 ms step, so almost nothing
is being asked that the resolution forbids. The 38% is not a resolution artefact the way AMI's 42%
partly was — it is the model, in that room.

**A close-talk control says the loss is the room, not the pipeline and not the corpus.** The same
conversation, same reference turns, same variant, run on a mix of the four participants' own
close-talk headsets:

| S02, dihard3 | flat | ≥ 2 s | clusters found |
|---|---|---|---|
| tabletop array (`U01.CH1`) | 204/448 — 46% | 138/231 — 60% | 5, three of them mapped to P08 |
| **headsets (close-talk)** | **261/448 — 58%** | **158/231 — 68%** | **4 — a clean one-to-one** |

That is the whole result in two rows. Given close-talk microphones the diarizer finds exactly the
four people and assigns them one cluster each; the reference, the timestamps and the scoring are all
sound. Put the same conversation through an array on the table and it invents a fifth cluster, maps
three of them to one person, and drops twelve points. It also means DiPCo close-talk (68% at ≥ 2 s) lands where AMI's
*array* lands (68–81%), so the AMI array was an unusually forgiving room rather than DiPCo being
unusually hard.

**Two mundane explanations were checked and ruled out.**

- *The device choice is not the cause.* Five sessions ship `U01`–`U03` and five ship `U04`–`U05`,
  never both — a corpus packaging quirk, not a scoring choice (the transcriptions carry all five
  devices for all ten sessions). Re-running one session per family across every array it has moves
  the result by a few points and never reorders anything: S02 scores 46/48/50% on `U01`/`U02`/`U03`,
  S03 scores 34/36% on `U04`/`U05`.
- *The timelines are not skewed.* The diarizer's segments span 88% (S01) and 84% (S04) of the time
  the reference says someone was speaking, which is the right order for a model that merges short
  backchannels into their neighbours. A misaligned timeline would read far lower, and the close-talk
  control would not reach 68%. That said, **a sixth of the speech region has no cluster assigned at
  all**, and every turn falling there scores as wrong by construction — worth knowing before reading
  the 38% as pure confusion.

**Overlap is real here and AMI barely has any** — measured as the share of speaking time with more
than one voice active, DiPCo runs 11–37% (pooled 28%) against 5–8% in the two AMI meetings. It is the
most likely single cause and it does not explain the spread on its own: S10 has 28% overlap and
scores 65%, S07 has 33% and scores 26%. Depth and duration of overlap were not separated.

**Speed is not the constraint.** All ten sessions — 320 minutes of audio — diarized in 132 seconds
end to end, about **145× realtime**, consistent with AMI's 146–167×. The whole-corpus run costs less
than a coffee.

**What this means for the app, and it is not what the AMI numbers suggested.** A colour that is right
half the time on the turns someone would read, and wrong the other half, is worse than no colour:
the reader cannot tell which turns to distrust, and a caption aid for someone with cognitive decline
must not invent structure. The AMI result ("seven to eight times in ten in the band that matters")
supported shipping speaker colours. **The DiPCo result does not.** The honest options are to show
speaker change without claiming identity — a break or a bullet rather than a name or a colour — or to
treat diarization as the feature to get right before the UI, which is what the measurement now
supports. Nothing here says the approach is hopeless; the close-talk row says the model is fine and
the room is the problem, and room robustness is exactly what a phone on a table needs.

## What was not measured

- **Nothing on a device.** All of this is an M2 Pro. The relative ordering should hold; the absolute
  real-time factors will not.
- **No streaming test of Parakeet TDT.** The 0.009 figure is a full-file batch decode. Feeding it a
  live loop of sliding windows is a different measurement and it has not been run.
- **Three meetings of 171, all AMI, plus all ten DiPCo sessions.** The AMI meetings cover two of the
  three recording sites and both four- and five-speaker setups; DiPCo is ten homes. Nothing here is
  a single-room fluke any more, and the DiPCo spread (26–65% at ≥ 2 s) is the honest error bar.
- **No third corpus.** CHiME-6 (real dinner parties, OpenSLR SLR150) also fits the app's setting and
  has not been run. Its value now is as a check on DiPCo's 48%, not as the first look at a home.
- **No separation of what makes DiPCo hard.** Overlap, reverberation, background noise and moving
  speakers all differ from AMI at once, and the close-talk control isolates "the room" without
  saying which part of it. If this becomes the blocking feature, that is the next thing to pull
  apart — anechoic-versus-reverberant and overlap-free-versus-overlapped subsets of the same
  sessions would each be cheap to build.
- **No published-number comparison.** Our metric is turn attribution, not DER, so these figures
  cannot be placed beside the AMI-SDM leaderboard without a conversion that has not been written.
- **Only the default int8 encoder.** The CLI exposes `--encoder-precision int8-v2` and `--dual-decode-arbitration`;
  neither was tried.
- **No word→speaker attribution.** Neither package provides it end to end; Parakeet exposes per-token
  timings and a diarizer timeline, and joining them is still ours to write.
- **WhisperKit was not re-run today.** Its figures come from `reports/latest.md`, measured on the
  same machine and fixtures but in a previous session.

## Fairness caveat: the two real-time factors are not the same measurement

WhisperKit's 0.571 is measured with `concurrentWorkerCount: 1` — deliberately serialized, because
the number the live loop needs is *how long one window takes*, not how many windows per second the
machine can push. Parakeet's 0.009 is an unconstrained batch decode of a whole file. So the honest
statement is "Parakeet's batch throughput has enormous headroom over what WhisperKit achieves under
the constraint our live loop imposes", not "Parakeet is exactly 63× faster end to end". The
conclusion that headroom is no longer the binding constraint does not depend on the exact ratio.

## How to reproduce

Parakeet runs through its own CLI, so none of this required adding a dependency to the package:

```bash
git clone --depth 1 https://github.com/FluidInference/FluidAudio.git /tmp/fluidaudio-eval/src
cd /tmp/fluidaudio-eval/src && swift build -c release --product fluidaudiocli   # ~5 minutes

# batch, 0.6B TDT v3 — models download to ~/Library/Application Support/FluidAudio/Models
for f in Fixtures/audio/*.wav; do
  /tmp/fluidaudio-eval/src/.build/release/fluidaudiocli transcribe "$f" | tail -1 \
    > /tmp/hyp/$(basename "$f" .wav).txt
done

# streaming EOU. NOTE: 160 is the tool's default and its worst setting —
# add --chunk-size 320.
swift run -c release caption-harness score --text-dir /tmp/hyp --json > /tmp/score.json

# diarization. NOTE: --variant defaults to ls_eend_ami, which is the one that fails
# on distant microphones. Always pass it.
for v in ami dihard3 callhome dihard2; do
  /tmp/fluidaudio-eval/src/.build/release/fluidaudiocli lseend \
    Fixtures/audio/ami-meeting-far.wav --variant "$v" > "/tmp/far-$v.log"
  uv run --no-project python -I Scripts/diarization_score.py ami-meeting-far "/tmp/far-$v.log"
done

# whole AMI meetings, no window chosen
Scripts/ami-farfield-benchmark.sh EN2001a TS3003a --variant dihard3

# the ten DiPCo dinner parties. 12.5 GB, fetched separately:
#   hf download huckiyang/DiPCo --repo-type dataset --local-dir .corpora/dipco
Scripts/dipco-farfield-benchmark.sh S01 S02 S04 S07 S08 --device U01
Scripts/dipco-farfield-benchmark.sh S03 S05 S06 S09 S10 --device U04
```

`score` exists for exactly this: it takes text some other process produced and puts it through the
same `TranscriptEvaluator` and `CriticalInfoScorer` as everything else in `reports/`, so an engine
can be compared before anyone commits to integrating it.

Version note: FluidAudio was evaluated at commit `fc8c3e4` (2026-10-09). The package is moving fast
— its source comments cite issues up to #897 in a one-day-old checkout — so pin a commit rather than
tracking a branch if this becomes a dependency.
