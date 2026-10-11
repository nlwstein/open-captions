# Engine comparison: WhisperKit vs Parakeet

> **Start here if you are asking which recogniser the app should use.** It ships **Nemotron 0.6B
> streaming at 1120 ms with an automatic gain stage**, and the section that decided that is
> [The recogniser was dropping two thirds of the words](#the-recogniser-was-dropping-two-thirds-of-the-words).
> This document began as a two-engine comparison and grew into the record of how the choice was made.
> The speaker-grouping sections below are still the evidence behind *that* decision, which has not
> changed; the recogniser conclusions near the top have, and that section supersedes them.

**What the fixture comparison found, and what it still supports:** Parakeet's 0.6B TDT model is
roughly 60× faster than WhisperKit `large-v3-turbo` at comparable accuracy, and it wins clearly on the
only *real* recordings in the fixture set — while losing badly on two synthetic ones, a split whose
cause is still unresolved. That comparison is why the app moved off WhisperKit. It is not why the app
chose the engine it now runs; that came from far-field audio, where every model in this table turned
out to be level-starved rather than simply weak.

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

> **⚠ The streaming Parakeet rows above are superseded, and the app no longer ships that engine.**
> They are a mean over the eight fixtures, and they are not *wrong* — but they score a recogniser that,
> on real far-field conversational audio, was transcribing **38% of the words that were actually said**
> (23.8% on the harder of two five-minute windows). Nothing in this fixture set measured how much of
> the reference *survived*, so a model that omits half of every sentence scored nearly as kindly as one
> that transcribes it with a couple of errors. Jump to
> [The recogniser was dropping two thirds of the words](#the-recogniser-was-dropping-two-thirds-of-the-words),
> which measured that, and replaced both the engine and the input level as a result.

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

### DiPCo: the same measurement at a dinner table, and the model matters more than the room

**Correction, added after this section was written: every number below is LS-EEND, and LS-EEND is not
the engine.** The section ends by concluding that speaker colours must not ship. That conclusion was
drawn from the wrong model and it does not hold. Run the same ten sessions through streaming
**Sortformer** — the other diarizer in the same package, and the one the app would actually use — and
it wins on every session, on both the headline score and colour constancy:

| DiPCo, all ten sessions | Sortformer | LS-EEND (`dihard3`) |
|---|---|---|
| all turns | **49.5%** | 39.9% |
| turns ≥ 2 s | **72.3%** | 52.2% |
| turns ≥ 5 s | **82.3%** | 56.6% |
| one colour per speaker | **83.3%** | 50.0% |

Sortformer is ahead on **10 of 10 sessions** flat and **10 of 10** on constancy. The ≥ 2 s figure is
**72%**, not 48%: placing it beside the AMI meetings, the dinner table is *not* worse than the
meeting room — 72% at a table against AMI's 68% and 81%.

Three checks were run against the possibility that this is a flattering comparison.

- **`dihard3` is LS-EEND's best variant, not a straw man.** `ami`, the CLI default, detects *nothing*
  on S02 — all four speakers at 0.0 s active. The others score `callhome` 36%, `dihard2` 43%,
  `dihard3` 46% on the same session. The row above is the strongest LS-EEND has.
- **Sortformer's fixed four slots are not the advantage they look like.** It is architecturally
  capped at four speakers, and DiPCo has exactly four, so this corpus is the most favourable case the
  model will ever get. `dihard3` is built for ten. The margin survives anyway.
- **Streaming beats the fused offline model.** On S02, the streaming path scores 71% where
  `--offline` scores 40%, with constancy of 100% against 17%.

**What breaks the old conclusion is not that the room is harmless — it is that the room was never the
whole loss.** The close-talk control below is still the clearest single result in this section, and
the overlap breakdown still prices contention at about twelve points. What changes is the ceiling: a
better diarizer, not a better microphone, was worth twenty-four points at ≥ 2 s.

**The honest caveat is colour drift, not accuracy.** Constancy is 83% across windows on average, but
that average hides S08 at 33% and S04 at 67% — roughly one session in five moves a colour mid-way
through a conversation, and that is the failure a reader cannot detect. Accuracy is good enough to
ship on this evidence; identity stability is the thing still worth engineering.

### Enrolment does not do it, and costs fifteen points to find that out

**`SortformerDiarizer.enrollSpeaker` is a naming API, not a speaker-recognition one, and calling it
makes the diarization measurably worse.** This was going to be the answer to colour drift — introduce
the diarizer to Mum's voice before the session so her colour is hers and not whichever slot she
happened to land in. It is not, and the reason is visible in the implementation.

`enrollSpeaker` feeds the clip through the model, accumulates `speechFrames` per slot, takes
`bestSlot` — whichever of the four tracks dominated *that clip* — and calls
`_timeline.upsertSpeaker(named:atIndex:)`. `DiarizerSpeaker` holds an `id`, an `index`, a `name` and
its segments. **There is no embedding anywhere in it.** So the name is attached to a slot index, and
the slot index is decided afresh from the enrolment clip every time it is called. Enrol the same
person on two different days and they land wherever the tracks fall, which is the drift it was meant
to fix.

It is also not free. On S02 (`U01.CH1`, the same input as the 71% above), enrolling all four
participants from ~22 s of their own close-talk audio each:

| S02, full session | flat | one colour per speaker | windows constant |
|---|---|---|---|
| no enrolment | **69%** | 69% | 9/10 |
| four enrolled speakers | 54% | 54% | 9/10 |

**Fifteen points of accuracy, no constancy gained.** The mapping is not merely relabelled either —
enrolment moved slots 1 and 3 onto each other *and* changed the segment boundaries, so the model's
actual output differs rather than the same tracks wearing new numbers. The mechanism is the
side-effects: each `enrollSpeaker` call resets the timeline twice and pre-creates speaker objects at
the chosen indices, and the streaming state the session then starts from is not the state it would
have started from alone.

Two things this measurement needed to be believable, both of which were checked:

- **The engine is bit-for-bit deterministic.** Two identical S02 runs produced identical segments and
  identical turns, so a difference between two runs is a difference the code caused. Every A/B in
  this document rests on that, and it is worth re-checking after any FluidAudio bump.
- **The comparison is same-input.** Both runs read the corpus's own 16 kHz `S02_U01.CH1.wav`, which
  takes the loader's untouched path — see the loader section below, and note that the 69% baseline
  above is measured through the *old* loader and would need re-running if the fast path ever
  changes.

**What this means for the app.** Names still work — but they are the *human's* labels typed onto
slots, which is what the harness's keyboard already does, and they inherit the drift rather than
fixing it. Any real fix has to store a voice's embedding and match against it, which is what the
*offline* diarizer's WeSpeaker embeddings are for; the streaming path has no such thing. Until then
the honest design is the one already in the harness: numbers by default, names as a human overlay,
and the slot number kept beside every name so a drift reads as a mismatch rather than as the app
telling someone their daughter is their son.

### The file loader was the bug: a 35% that nothing but the resampler explained

**A streaming run that scored 35% where this document claims 71% was reading correct audio through a
broken sample-rate converter.** Finding that took three wrong answers, each of which looked right
until it was measured, so the wrong turns are recorded here rather than only the conclusion.

The trigger was the sample recordings in `~/Downloads/live-caption-samples/` — three 192 kHz copies of
S02, twelve times the corpus rate and 691 MB each. Replaying one through the harness scored 35% where
the same session scored 69% from the corpus's own 16 kHz file. Guesses, in order:

- **Playback speed.** `--speed 25` feeds audio faster than the model consumes it. **Ruled out:** the
  diarizer's `audioBuffer` is an unbounded array that is appended to and consumed from the front, so
  a slow consumer makes the buffer grow and never drops samples.
- **The seven-channel mix.** A plain sum of seven far-field capsules looks like it should comb-filter
  the speech. **Ruled out:** with the loader fixed it scores **72%**, *better* than a single capsule's
  70% on the same window. Averaging a real array is a noisy but honest sum, not a broken one.
- **The sample rate itself.** **Ruled out:** a 16 kHz file re-encoded to float32 and back scores
  identically, and 48 kHz copies of the full session score the same 69% as native.

What was actually wrong is in the loader this project was calling. WhisperKit's
`AudioProcessor.loadAudioAsFloatArray` builds an `AVAudioConverter` per read and calls
`convert(to:error:withInputFrom:)` **exactly once**, which leaves the converter's filter unprimed and
its latency uncompensated. At 16 kHz nothing is resampled and the path is exact — which is why every
number in this document measured before this was found still stands. At 192 kHz the conversion is
12:1 and the loss is real:

| S02, full session | flat | windows constant |
|---|---|---|
| corpus `U01.CH1` at its native 16 kHz | **69%** | 9/10 |
| the same audio as a 192 kHz copy, library loader | 55% | **4/10** |
| the same audio at 192 kHz, our loader | **66%** | **10/10** |

**Eleven points and six windows of colour stability, from a converter configuration.** The fix is in
`AudioFile.load`: files that need resampling are converted here instead, with one converter held
across the whole file and the input block written as a *source the converter pulls from*, which is the
shape the API documents. `sampleRateConverterQuality` is also set explicitly rather than left at the
default. Files already at 16 kHz still take the library's path untouched, so the common case carries
no new code and no new risk.

Two things worth keeping from this, beyond the fix. **The engine is deterministic** — two identical
runs produce byte-identical segments and turns — so a difference between two runs is a difference the
code caused, which is what made an eleven-point claim safe to make at all. And **a near-perfect
waveform correlation is not evidence that a pipeline is unchanged**: the loaded 192 kHz audio
correlated with the original at **r = 0.9994** at zero shift while scoring fourteen points worse. The
residual was 0.06% of the signal and enough to move a thresholded model.

Everything below this correction is LS-EEND, kept because the close-talk/array control and the
overlap cross-tab are the measurements that explain *why* the two models differ, and because the
wrong turn is worth being able to retrace.

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

**Overlap and the room both cost, and only a cross-tab separates them.** Either breakdown on its own
misleads: length alone flatters a meeting full of half-second backchannels, and overlap alone
flatters one that is mostly long turn-taking. Holding both fixed is the comparison that travels
between corpora — `diarization_score.py --cross`:

| | clear (< 10% clashed) | mixed (10–50%) | contested (≥ 50%) |
|---|---|---|---|
| DiPCo, < 2 s | 101/302 — 33% | 149/376 — 40% | 946/3,325 — 28% |
| DiPCo, ≥ 2 s | 285/523 — **54%** | 613/1,097 — 56% | 615/1,455 — **42%** |
| AMI, ≥ 2 s | 419/580 — **72%** | 47/72 — 65% | 5/20 — 25% |

Two readings come out of it and both are needed.

- **Overlap costs about twelve points.** On DiPCo turns of two seconds or more, uncontested ones
  score 54% against 42% for majority-contested ones. And it is the normal condition there, not an
  edge case: 68% of DiPCo's turns are majority-contested, against 40% and 58% in the two AMI
  meetings. The corpus exists to study speech *separation* — that is the Interspeech paper's subject
  — and the audio does what it says it does.
- **The room costs about eighteen.** On turns that are both long (≥ 2 s) *and* uncontested (< 10%
  clashed) — the fairest comparison available, and the one the AMI result rested on — DiPCo scores
  **54% against AMI's 72%**. Same measurement, same diarizer, turns where nothing else is competing
  for the microphone, and the room still gives up eighteen points.

The AMI contested cell (5/20) is twenty turns and carries no weight; it is in the table for shape,
not for use. The DiPCo and AMI cells beside it are 500–1,500 turns each.

**Speed is not the constraint.** All ten sessions — 320 minutes of audio — diarized in 132 seconds
end to end, about **145× realtime**, consistent with AMI's 146–167×. The whole-corpus run costs less
than a coffee.

**What LS-EEND's DiPCo numbers mean — and the correction at the top of this section is what
governs.** Read on their own, a colour that is right half the time on the turns someone would read is
worse than no colour: the reader cannot tell which turns to distrust, and a caption aid for someone
with cognitive decline must not invent structure. That was the reasoning behind "do not ship", and
it was sound given these numbers. **It was applied to the wrong model.** Sortformer's 72% at ≥ 2 s
and 83% constancy is the figure the shipping decision rests on, and 72% is above the AMI number that
first looked good enough. The rest of this section is kept because it prices the two causes
separately, and the fix that follows from it is different depending on which one you believe: the
close-talk row below says the model was fine and the room was the problem, while the Sortformer
comparison says the model was the problem and the room costs less than this section claims. Two
things remain true and neither was measured on a phone: DiPCo's best array is seven microphones at a
fixed position on a table, and **two thirds of the turns in that setting have someone else talking
over them**, which no diarizer can resolve on its own.

## The recogniser was dropping two thirds of the words

**Bottom line: Parakeet EOU 120M — the engine this document's table above points at, and the one the
app was built around — transcribes 38.2% of the words that were actually said on real far-field
conversational audio, and it fails by going silent rather than by guessing wrong.** On the harder of
two DiPCo windows it deletes 475 of 695 reference words and emits nothing in their place. Moving to
a 0.6B streaming model and lifting the input level takes pooled WER from **62.6% to 37.5%** and word
recall from **38.2% to 63.9%** — the app goes from getting a bit over a third of the words to getting
nearly two thirds.

### Why the table at the top of this document did not catch it

EOU scored 31.3% mean WER across the eight fixtures, and that number is not wrong — it answers a
different question. Most of the fixture set is synthetic or close-talk, and a scorer that weighs a
substitution and a deletion equally reports a model that omits half of every sentence almost as
kindly as one that transcribes it with a couple of errors, especially when the reference is dense
with "ummm" and "uhhh", which are cheap to hit and inflate the denominator. **Nothing in the fixture
set measured how much of the reference survived**, and on real four-person dinner-table audio that is
the number that decides whether a caption is usable.

### How this was measured

Two five-minute windows of DiPCo `S02`, channel `U01.CH1` — the far-field table array, not a close
mic — scored against the corpus's official reference transcripts with `Scripts/dipco-recall-score.py`:

| Window | Offset | Reference words | EOU raw WER | Nemotron +gain WER |
|---|---|---|---|---|
| 1 | 0–300 s | 695 | 76.0% | 44.3% |
| 2 | 900–1200 s | 884 | 52.0% | 31.3% |

**The two windows are not the same difficulty**, by 24 points on the same engine, so both are shown
rather than pooled. Their spread is why the pooled column below is quoted alongside them and never
instead of them.

Every hypothesis is the harness's own streaming output, taken from the `--dump` JSON by
concatenating turns in start-time order. Three metrics, because one hides the thing that matters:

- **WER** — standard Levenshtein over all tokens, including disfluencies.
- **Content recall** — the fraction of reference *content* words that survive. Content words are
  everything that is not a filler or a function word, and only substitutions and deletions count
  against it, so it cannot be gamed by emitting extra words. This is the "misses obvious words"
  metric.
- **Negation + number** — the tokens where an error changes what the reader believes was said.

The scorer is `Scripts/dipco-recall-score.py`, stdlib-only so it needs neither the package nor a
virtualenv, and every number in this section came out of it:

```bash
# One hypothesis. Prints a human line and a machine-readable POOL line.
python3 -I Scripts/dipco-recall-score.py .fixture-build/wer/reference/dipco-s02.txt HYP.txt TAG

# The harness's own output, per window. `--dump` writes turns; concatenate them in start-time order.
swift run -c release caption-harness stream --from-file CH1_WINDOW.wav \
  --asr nemotron-1120ms --speed 8 --max-seconds 300 --plain --dump out.json
```

`--max-gain-db 32` is the default; `--no-gain` takes the stage out of the path, and both appear in
the tables below. The two references are `dipco-s02.txt` (window 1, 0–300 s) and `dipco-s02b.txt`
(window 2, 900–1200 s), both cut from DiPCo `S02` channel `U01.CH1`.

### The numbers

Both windows pooled, 1 579 reference words:

| Engine | W1 | W2 | Pooled WER | Content recall | Neg+num |
|---|---|---|---|---|---|
| Nemotron 0.6B, 1120 ms, fixed +33 dB | 44.3% | **31.3%** | 37.0% | **64.8%** | **69.1%** |
| **Nemotron 0.6B, 1120 ms, `AutomaticGain` — what ships** | 44.3% | 30.8% | **37.5%** | 63.9% | 65.5% |
| Parakeet Unified 0.6B, 1120 ms, +33 dB | 43.6% | 35.4% | 39.0% | 61.3% | 52.7% |
| Parakeet Unified 0.6B, 2080 ms, +33 dB | 44.6% | 39.0% | 41.5% | 59.9% | 47.3% |
| Parakeet Unified 0.6B, 1120 ms, raw | 47.1% | 38.6% | 42.3% | 59.1% | 52.7% |
| Parakeet EOU 120M, 320 ms, +33 dB | 58.8% | 43.2% | 50.1% | 51.6% | 61.8% |
| **Parakeet EOU 120M, 320 ms, raw — what the app shipped** | **76.0%** | **52.0%** | **62.6%** | **38.2%** | 43.6% |

Window 1 only, because these runs were never repeated on window 2 — the offline decodes, the
Whisper model and the chunk-size sweep:

| Engine | WER | Content recall | Neg+num |
|---|---|---|---|
| Parakeet TDT v3, one 300 s batch decode, +33 dB | 43.5% | 55.5% | 57.6% |
| Nemotron 0.6B, 2240 ms, +33 dB | 44.3% | 53.7% | 57.6% |
| Parakeet TDT v3, one 300 s batch decode, raw | 45.9% | 50.2% | 54.5% |
| WhisperKit `large-v3-turbo`, +33 dB | 46.6% | 50.9% | 48.5% |
| Nemotron 0.6B, 560 ms, +33 dB | 48.8% | 47.3% | 60.6% |
| WhisperKit `large-v3-turbo`, raw | 61.9% | 35.9% | 39.4% |

### The deletion profile is the finding, not the WER

On window 1, EOU produced **53 substitutions, 475 deletions and zero insertions**. That asymmetry is
diagnostic. Read side by side with the reference, EOU's output is plainly tracking the same
conversation — lasagna, oranges, Michigan all appear — it is simply not producing about half of it.

A model that is *wrong* needs a better model. A model that is *absent* is more likely being fed,
buffered or drained incorrectly, and that is worth ruling out before concluding anything about the
model. The harness is the obvious suspect, because it replays a file faster than real time and could
in principle be overflowing a buffer EOU is still reading. It is not the cause — see the two
controls below — and the loss is in the recogniser.

### Two controls, both confirmed by file hash

**Feed rate is exonerated.** The same window, engine and gain, replayed at **1× instead of 8×**,
produced a **byte-identical transcript** — 92 substitutions, 311 deletions, 6 insertions both times.
`ctl_eou320_speed1.hyp.txt` and `g33lim_eou320.hyp.txt` have the same MD5 (`6877ef90…`). EOU loses
those words at any speed.

**The chunk-size flag was doing nothing.** `--asr parakeet-eou-1280ms` produced a transcript
**byte-identical** to `--asr parakeet-eou-320ms` — same MD5 again, the same `6877ef90…` file. The
cause was in the initialiser: it read `options.chunkSize`, which defaults to `.ms320`, and used the
variant name only to decide *which family* to build, so all three EOU tiers silently built the same
320 ms manager. The doc comment on `chunkSize` claimed the opposite, so the intent was always there;
the code just did not do it. Fixed by resolving `chunkSize` against the variant name, with an
explicit `--chunk-ms` still able to override.

Re-run after the fix, the three tiers separate — the runs now label themselves `EOU 160ms`, `EOU
320ms` and `EOU 1280ms`, where before all three said `320ms` — and the numbers are worth keeping for
a second reason. **EOU's accuracy is not monotonic in chunk size:**

| EOU chunk, gained | WER | Content recall | Deletions |
|---|---|---|---|
| 160 ms | 69.1% | 29.5% | 430 |
| **320 ms** | **58.6%** | **42.7%** | 314 |
| 1280 ms | 69.9% | 28.1% | 434 |

More lookahead makes this engine *worse*, the opposite of what the Nemotron tiers showed. The reason
is in the name: for an end-of-utterance model the chunk is how long it waits before deciding an
utterance has ended, so a 1280 ms chunk makes it hold and then drop — 434 deletions against 314. The
tier the app actually shipped, 320 ms, was already the best of the three. The flag was inert, so that
was luck rather than judgement; it is now a measurement.

Two settings that should differ producing **identical output** is the signature of an inert flag. A
near-identical score would have looked like noise and been ignored.

These three runs feed the harness a file with the +33 dB already baked in and leave the automatic
stage in the path, where on that input it asks for 0.00 dB — which is why the 320 ms row reads 58.6%
here and 58.8% in the tables above, the latter being the raw file through a fixed limiter. Two errors
apart, and the three rows are directly comparable to each other, which is what the table is for.

### Input level is as large a lever as the model

DiPCo's far-field channel is roughly 30 dB below the level ASR front ends are usually trained on:
mean −59.7 dBFS, peak −21.3 dBFS. FluidAudio does no amplitude normalisation at all —
`Shared/AudioMelSpectrogram.swift` states `normalize: "NA"`, and its `logValue` is a plain
`log(value + 2^-24)`, so whatever level arrives is the level the mel filterbank sees.

Crossing the two engines with the level fix is the cleanest way to read how much of the complaint
each one addresses. Both columns are pooled over the two windows and the same 1 579 reference words:

| | no gain | +33 dB |
|---|---|---|
| Parakeet EOU 120M, 320 ms | 62.6% | 50.1% |
| Nemotron 0.6B, 1120 ms | 47.0% | 37.0% |

Read down either column and the two levers come out at nearly the same size. Swapping the model is
worth **15.6 points** raw and 13.1 gained; fixing the level is worth **12.5 points** on EOU and 9.5 on
Nemotron. Neither dominates the other. What separates them is cost: the level fix is the same model
on the same real-time budget, which is why it is worth taking first.

Two cells in that table are the before and after. EOU at 320 ms with no gain, 62.6%, is **what the app
shipped**. Nemotron at 1120 ms with the automatic stage — which ties the fixed +33 dB rather than
beating it — is what it ships now, at **37.5%**.

It also helps every engine, not just these two. **Gain is worth more to EOU than any model exchange
within its own family** — +33 dB takes it from 76.0% to 58.8% on window 1 and 52.0% to 43.2% on
window 2, and the 17.2 points that buys on window 1 is more than the 11.3 points separating its best
and worst chunk sizes.

WhisperKit is the sharpest illustration that this is not a Parakeet quirk. `large-v3-turbo` is the
strongest engine on the fixture set — **17.9% mean WER, the best of anything in this document** — and
it does beat EOU on real audio as well, 61.9% against 76.0%. But gaining that same audio moves it
15.3 points, to 46.6%, which is still **behind** the streaming 0.6B model's 44.3%. The engine that
wins every synthetic fixture lands mid-pack on real audio, for exactly the same reason the worst one
does: neither is being handed audio at a level it was trained on.

**This is not a reason to apply 33 dB of gain to everything.** docs/RESEARCH.md's Finding 3 records the
opposite result on `ami-meeting-far`: boosting that clip made it worse (23.5% → 26.1%), because
lifting the signal lifts the microphone's noise floor with it. DiPCo is an extreme case at −59.7
dBFS mean. What the two results jointly say is that the app needs a gain stage that tracks speech
level rather than a fixed multiplier.

### The gain stage, and what it costs

`AutomaticGain` aims a percentile of recent frame levels at −25 dBFS rather than detecting speech,
because a detector cannot work on this audio: DiPCo spans only **−67 to −50 dBFS across thirty
minutes**, so speech sits 13 dB above the room and any margin wide enough to exclude room tone also
excludes most of the speech.

The design is checked against the audio rather than tuned. Run the rule on raw DiPCo and it asks for
**+32 dB**; run it on the same audio already boosted by 33 dB and it asks for **0.00 dB**. A fixed
multiplier cannot produce both answers, and +32 dB is within a decibel of the +33 dB that was found
best by hand — the constant falls out of the corpus rather than being fitted to it.

Both windows, so the comparison is not a story about one of them:

| Nemotron 0.6B, 1120 ms | Window 1 | Window 2 | **Pooled WER** | Content recall | Neg+num |
|---|---|---|---|---|---|
| No gain | 63.2% | 34.3% | **47.0%** | 54.7% | 50.9% |
| Fixed +33 dB, tuned by hand on this corpus | 44.3% | 31.3% | **37.0%** | 64.8% | 69.1% |
| `AutomaticGain`, never tuned to it | 46.0% | 30.8% | **37.5%** | 63.9% | 65.5% |

Three things are in that table, and only one of them is the one you would expect.

**Gain is worth 9.5 points pooled on this engine, and 12.5 on EOU** — on both windows, and it is the
half of the fix that costs nothing: the same model on the same real-time budget. Swapping the model is
worth 13.1 points at this level (EOU's 50.1% to Nemotron's 37.0%, both already gained) and 15.6 raw.
The two together are what took the app from 62.6% to 37.5%.

**The stage ties a hand-tuned constant rather than beating it.** 37.5% against 37.0% is five tenths
of a point, eight words out of 1 579, and the ordering *flips* between the windows: the constant is
1.7 points better on window 1, the stage 0.5 better on window 2. A claim that the adaptive stage is
more accurate would not survive this table, and is not made.

**What the stage buys is not needing to be tuned**, which was the actual problem. The +33 dB was
found by sweeping this corpus. `ami-meeting-far` measures a peak of −17.13 dBFS — already usable —
and handing *it* +33 dB makes it worse, so the constant that wins here loses elsewhere. Asked the same
question, the stage answers differently on every recording it has been shown, and the answers track
the audio rather than the corpus:

| Clip | Character | p90 frame level | Gain the rule asks for |
|---|---|---|---|
| DiPCo `S02` | far-field table array, four speakers | −58.1 dBFS | **+32 dB** (clamped; it wants 33.1) |
| `ami-meeting-far` | real, distant microphone | −42.7 dBFS | **+18 dB** |
| `ami-meeting` | real, close table array | −38.6 dBFS | **+13 dB** |
| `ami-meeting-synth` | synthetic, normal level | −19.3 dBFS | **0 dB** |

That is a 32 dB span decided from the audio alone, with no branch on which file it is looking at. It
generalises; a constant cannot.

One honest note on that table: the stage is not simply a no-op on good audio. `ami-meeting` is a real
close-array recording and it still asks for +13 dB, because the rule aims at −25 dBFS and that
recording's speech sits below it. Whether that is the right target for audio that is already being
transcribed well is not something this project has measured — the only clip where the stage's
engagement was priced end to end is `ami-meeting-far`, below.

**The honest cost.** That +18 dB still costs 4 points on `ami-meeting-far` (21.8% → 26.1%): on an
already-usable clip, lifting the signal lifts the microphone's noise floor with it. The clip is 119
reference words, so the whole difference is three deletions, but it reproduces an independently
measured result in the same direction and should be read as real rather than as noise.

The stage stays on by default because of the size of the two effects rather than their signs. Where it
engages hard it is worth **9.5 points**, on audio the app would otherwise fail on completely. Where it
costs something it costs 4 points on a clip that was already at 22%.
`--no-gain` takes it back out of the signal path.

### The gain ceiling is a plateau, and the clamp turns out to be load-bearing

`maxGainDb` is the one constant in the stage that could have been fitted to this corpus, so it was
swept across **both** windows rather than argued about — 26, 28, 30, 32, 34 and 40 dB:

| `maxGainDb` | 26 | 28 | 30 | **32 (shipped)** | 34 | 40 |
|---|---|---|---|---|---|---|
| Window 1 WER | 46.8% | 46.6% | 45.6% | **46.0%** | 46.2% | 46.9% |
| Window 2 WER | 31.2% | 30.8% | 31.0% | **30.8%** | 31.0% | 30.3% |
| **Pooled WER** | 38.1% | 37.7% | 37.4% | **37.5%** | 37.7% | 37.6% |
| Pooled content recall | 63.6% | 64.1% | 63.9% | **63.9%** | 63.6% | 63.6% |
| Pooled errors, of 1 579 | 601 | 596 | 591 | **592** | 595 | 594 |

**The entire range, 26 to 40 dB, spans seven tenths of a point — ten errors.** There is no peak to
find, and the two windows do not even agree on which end is better: window 1 prefers 30 dB, window 2
prefers 40. A parameter whose optimum moves when you change the window is not a parameter worth
tuning, and the honest reading is that **this corpus does not constrain it at all.** That is a
negative result and is recorded as one: 32 dB is kept because it sits in a band where nothing matters,
not because it was found to be best.

It is worth saying plainly why the small differences are not noise either. Three independent pairs of
runs — the same window at 1× and at 8×, at 1× and at 20×, and twice at 32 dB — produced
**byte-identical transcripts**, the last pair sharing MD5 `720fff068f7b…`. Run-to-run variation is
exactly zero, so a 0.4-point difference between neighbouring values is reproducible rather than
jitter. Reproducible is not the same as *meaningful*: the ordering simply reverses on the other
window, which is what fitting looks like from the inside.

What the sweep *did* turn up is a mechanism, and it explains why the clamp is worth having even
though this corpus cannot show it. At 40 dB the clamp stops binding — the corpus asks for 33.1 dB, so
the stage *tracks* its target instead of resting against its ceiling — and the character of the
applied gain changes completely. Measured across window 1:

| `maxGainDb` | gain p5 | p50 | p95 | **wobble** | slew rate |
|---|---|---|---|---|---|
| 32 | 31.33 | **32.00** | **32.00** | **0.67 dB** | 0.000 dB/s |
| 40 | 31.33 | 34.02 | 36.21 | **4.87 dB** | 0.101 dB/s |

At 32 dB the gain is pinned: its median and its 95th percentile are both exactly the ceiling, and it
moves two thirds of a decibel across five minutes. At 40 dB it is genuinely tracking, moving nearly
**5 dB** while it transcribes. So on audio this quiet the clamp is not a safety limit the corpus
merely happens to sit against — it is what converts a *tracking* stage into a *constant* one.

The obvious inference is that tracking is worse, and window 1 says so: 46.9% against 46.0%, its worst
content recall of the sweep. **The pooled number says otherwise** — 40 dB scores 37.6% against 32 dB's
37.5%. Window 2 improves by as much as window 1 loses (30.3% against 30.8%) and the two cancel. That
is recorded here because the window-1 result alone is a perfectly plausible 0.9-point story, and it
would have been wrong.

So the clamp is load-bearing in principle and inert in practice on this corpus. It would start to
matter on audio quieter than DiPCo's −59.7 dBFS mean, where the gain the rule asks for exceeds any
sensible ceiling — a regime this project has not measured against.

### The spread gate does not do what its name says

`AutomaticGain` has a second guard, `minimumSpreadDb`, meant to stop it amplifying a room with nobody
in it: speech modulates, a silent room does not, so a large spread between the 90th and 10th
percentile of frame levels is evidence of speech. It was designed against two synthetic fixtures —
hum plus hiss at 0.01 dB, white noise at 0.37 dB — and a 2.0 dB gate sits comfortably above both.

Then a real room was recorded, and it comes in at **3.15 dB** — *above* the gate. A room with nobody
in it varies more than white noise does, because rooms contain chairs and distant traffic and people
breathing. So the guard does not separate silence from speech. It separates **stationary** noise — a
fan, a hum, a hiss — from everything else, and on ordinary room tone it does not fire at all: 96
seconds of it is tracked as something to aim at, and the rule asks **21.4 dB**.

The gate is left where it is, because the alternative was costed. Raising it to 5 dB would exclude
that room tone, and the margin it has to work in is **1.34 dB** — 3.15 against the quietest real
speech window's 4.49, measured across all ninety of the corpus's twenty-second windows. That is the
entire gap available, and 5 dB does not sit cleanly inside it: a twentieth of those windows already
fall below 5 dB, so a gate wide enough to exclude an empty room starts closing on real speech, and its
cost would land on the audio the component exists to rescue.

What makes that trade acceptable is that the thing the gate fails to prevent does not matter, which is
a measurement rather than a hope. 96 seconds of recorded room tone, taken through the stage at its
full 21.4 dB, was transcribed by **Nemotron, Parakeet EOU and Parakeet Unified: zero words from all
three**, and zero from the same file with the stage bypassed. Amplifying an empty room wastes power
and invents nothing. The gate's weakness is an exposure worth documenting, not a defect worth trading
real speech to fix.

### A Mac buys headroom, not accuracy

The obvious use of a Mac is to stop streaming altogether: transcribe a growing window with a large
batch model and accept a second or two of latency. That was worth testing properly, because if
offline were substantially better it would change the design. **It is not.**

On window 1, same gain, same window:

| | WER | Content recall | Deletions |
|---|---|---|---|
| Parakeet TDT v3, one 300 s batch decode — full context, no latency constraint | 43.5% | 55.5% | 103 |
| Nemotron 0.6B streaming, 1.12 s of lookahead | 44.3% | 54.1% | 223 |

**Eight tenths of a point.** The offline decode is marginally ahead on WER, marginally behind on
content recall, and its error profile is different — far fewer deletions, more substitutions. What
it is not is *better by a margin worth having*.

That is the most important number in this section, because it relocates the problem. The remaining
error is not something a bigger model or more context fixes — it is a property of *this audio*: a
four-person dinner party recorded far-field, with heavy overlap, disfluency and cross-talk. The same
family scores 5.9% on `ami-meeting`, which is a real recording through a good close array, and 0–4%
on the clean synthetic fixtures; on this it scores 37%. **Choosing a better engine has stopped being
the lever; the lever is the audio and the level.**

**What it actually costs on a Mac, measured on two of them.** The same binary and the same five-minute
window, on this M2 Pro and on an M4 Mac mini:

| Machine | Background load | Nemotron 1120 ms | EOU 320 ms |
|---|---|---|---|
| **M4 Mac mini** | desktop running, nothing else | **7.59×** | 8.85× |
| M2 Pro laptop | idle | 6.10× | 7.06× |
| M2 Pro laptop | macOS Photos analysis running | **3.88×** | 4.75× |

In real-time-budget terms those three rows cost **13%**, **16%** and **26%** of one core respectively.
Figures are the median of three runs where three were taken; the M4 spread was under 1%.

The M4 is about **25% faster than the M2 Pro**, and it is as reproducible as the transcripts are:
three consecutive runs of each engine gave 7.59, 7.59, 7.60 and 8.80, 8.91, 8.84. This is a machine
that runs the whole pipeline — 0.6B recogniser, streaming diarizer and gain stage — in about an
eighth of the time the audio takes to arrive.

**Read the third row carefully, because it is the one a real user will hit.** macOS's
`mediaanalysisd` and its on-device inference service were between them consuming most of a core while
that row was measured — Photos doing its background analysis, nothing to do with this app — and
throughput fell by a third. Nothing about the engine changed; the machine was simply busy. A captioner
sharing a laptop with the operating system still has nearly 4× the speed it needs, so the conclusion
holds, but the margin is not as unconditional as a single idle-machine figure implies.

Latency moves more than throughput does, and that is the number to watch. The worst single processing
pass over a five-minute window is **0.13 s** on the M4, **0.16 s** on the idle M2 Pro and **0.40 s** on
the loaded one — a two-and-a-half-fold swing from background load alone. The engine carries 1120 ms of
lookahead, so none of those stall a caption. But one earlier M4 run reported a **1.26 s** pass, and
three immediate repeats on the same machine with the same binary reported 0.13 s every time. Something
outside the app can produce a stall an order of magnitude above the normal worst case, and a caption
that freezes for a second is more visible to the person reading it than a caption that arrives a
second late. That is the failure mode worth instrumenting on the real hardware.

### Thirty minutes without a leak

Every figure in this document up to this point comes from a five-minute window. A caption reader
leaves the thing on for a meal, so the shipping configuration was run over the full **thirty minutes**
of DiPCo `S02` in one continuous session, on both machines:

| | M2 Pro laptop | M4 Mac mini |
|---|---|---|
| Audio transcribed | 1 800 s (30.0 min) | 1 800 s (30.0 min) |
| Throughput | 3.51× real time | **7.28× real time** |
| Slowest single processing pass | 0.41 s | **0.13 s** |
| Words emitted | 3 995 | 3 978 |
| Turns | 402 | 405 |
| RSS while models load | 1 527 MB | not sampled |
| RSS, settled → final | 1 067 MB → **977 MB** | not sampled |

**The M4 gives up 4% of its throughput over half an hour** — 7.59× on a five-minute window against
7.28× on thirty minutes — and its worst processing pass is **unchanged at 0.13 s**. Nothing degrades
with time, which is the question a five-minute benchmark cannot answer and the reason this run exists.

The laptop column is where the memory result lives. **It finishes 91 MB lighter than it settled**:
memory peaks while the models load and then declines across the rest of the run, so there is no upward
trend to fit a leak to.

Two caveats, both about the laptop column. Its run executed alongside other work on the same machine,
so its throughput of 3.5× is contended and understates the hardware — the idle figure is the 6.10× in
the table above. And the memory result does not depend on how much of the CPU was free, but **the
latency result does**: that 0.41 s is itself an example, against 0.16 s for the same window on the
same laptop while idle.

### Chunk size: 1120 ms is the sweet spot

Nemotron at three tiers, all on the gained window-1 audio:

| Chunk | WER | Content recall | Neg+num |
|---|---|---|---|
| 560 ms | 48.8% | 47.3% | 60.6% |
| **1120 ms** | **44.3%** | **54.1%** | 57.6% |
| 2240 ms | 44.3% | 53.7% | 57.6% |

1120 ms and 2240 ms are the same accuracy, so **1120 ms is free**: identical quality at half the
latency. 560 ms costs 4.5 points of WER for half the latency again, which is the wrong trade for a
caption reader who is already reading a second behind.

### What this changes for the app

1. **The default recogniser has changed.** Nemotron 0.6B at 1120 ms, not the 120M EOU model at
   320 ms. Pooled across both windows: **62.6% → 37.5% WER and 38.2% → 63.9% content recall** — the
   app went from getting a bit over a third of the words to getting nearly two thirds of them.
   The cost is latency: 1120 ms of lookahead instead of 320 ms. The ASSETS 2026 caption-latency
   study found latency measurably affects deaf and hard-of-hearing viewers, which is the audience
   this app serves, so this is a real trade and not a free win. Nemotron's 560 ms tier is the escape
   hatch if it turns out to read badly, at 4.5 points of WER.
2. **The input gain stage is built and on by default.** Worth **9.5 points of pooled WER on the
   engine that ships, and 12.5 on the one it replaced** — the same order as swapping the model, not an
   afterthought to it — and it matches a hand-tuned fixed gain (37.5% against 37.0%) *without* being
   tuned to this corpus. That last part is the whole
   point: the constant that wins here loses on an already-usable clip, and a device in someone's
   kitchen cannot be handed a constant chosen on a research corpus. It costs 4 points on that one
   clip. See above.
3. **An M4 Mac is sufficient, and measured on an actual M4.** The shipping configuration runs
   **7.6× faster than real time at 13% of a real-time budget** on an M4 mini and 6.1× on an M2 Pro,
   so roughly seven eighths of the machine is idle while it listens, with the diarizer already inside
   that figure. Even sharing the machine with macOS doing its own background work, it held 3.9×.
   What a Mac does *not* buy is accuracy: see the offline comparison above.
4. **What is still unmeasured on the Mac is heat, not speed.** Every number here is an M2 Pro laptop
   or an M4 mini, both of which have a fan. The target machine is a fanless M4 MacBook Air, and
   nothing in this project has run long enough on one to know whether sustained transcription
   throttles. That is the one hardware question left, and it needs the Air rather than a proxy.
5. **Latency, not throughput, is the metric that will need a decision.** A worst-case processing pass
   of 0.13–0.40 s is invisible under 1120 ms of lookahead; the single 1.26 s stall observed was not.
   If the Air throttles, that is the number that will show it first, and it is the one the smoke test
   should watch.


## What was not measured

- **Nothing on a device, and on a Mac only one question is left.** The streaming figures are an M2
  Pro; one engine's rows were reproduced on an M4 mini to within half a point, so the relative
  ordering travels. What has not been run is a long session on the actual target hardware — a fanless
  M4 MacBook Air — so whether sustained transcription throttles there is still open. That is the one
  hardware question remaining, and it needs the Air rather than a proxy.
- **No home recording.** The gain stage was validated on `ami-meeting-far`, a MacBook microphone and
  96 seconds of room tone. It has never heard a kitchen, a television in the next room, or a
  dishwasher — the conditions the app exists for. Its guards are designed for those cases and the
  design is argued from the audio, but argued is not measured.
- **No streaming test of Parakeet TDT.** The 0.009 figure is a full-file batch decode. Feeding it a
  live loop of sliding windows is a different measurement and it has not been run.
- **Three meetings of 171, all AMI, plus all ten DiPCo sessions.** The AMI meetings cover two of the
  three recording sites and both four- and five-speaker setups; DiPCo is ten sessions of a simulated
  dinner party in a lab, not ten homes. Nothing here is a single-room fluke any more, and the DiPCo
  spread (26–65% at ≥ 2 s for LS-EEND, 40–71% flat for Sortformer) is the honest error bar.
- **No third corpus.** CHiME-6 (real dinner parties, OpenSLR SLR150) also fits the app's setting and
  has not been run. Its value now is as a check on DiPCo's 48%, not as the first look at a home.
- **"The room" is still a black box.** The cross-tab prices the room at eighteen points on clean,
  long turns, but reverberation, background noise, moving speakers, table reflections and the
  corpus's simulated-not-real dinner-party framing all differ from AMI at once and none was varied
  on its own. That matters for the fix: a beamformer or dereverberation front end addresses some of
  those and not others.
- **No speech separation.** Two thirds of DiPCo's turns have someone talking over them, which is not
  a diarization problem and is not fixable by a better diarizer — a single-stream output cannot
  colour two simultaneous voices correctly whatever it does. Nothing here tested a separation front
  end, so 42% is a floor on contested turns rather than a verdict on LS-EEND.
- **No published-number comparison.** Our metric is turn attribution, not DER, so these figures
  cannot be placed beside the AMI-SDM leaderboard without a conversion that has not been written.
- **Only the default int8 encoder.** The CLI exposes `--encoder-precision int8-v2` and `--dual-decode-arbitration`;
  neither was tried.
- **No word→speaker attribution.** Neither package provides it end to end; Parakeet exposes per-token
  timings and a diarizer timeline, and joining them is still ours to write.
- **WhisperKit only on window 1.** Its fixture-set figure comes from `reports/latest.md`, measured on
  the same machine in a previous session; its DiPCo figures are window-1 only. So are the offline
  Parakeet TDT decode, the 560 ms and 2240 ms Nemotron tiers and the 320 ms Unified tier — the window-1
  table is where one-off runs live, and none of those rows should be read as pooled.
- **The offline decode was window-1 only.** The full-context comparison that concludes a Mac buys
  headroom rather than accuracy rests on one window of one corpus. It is a large enough effect
  (0.8 points) that a second window would not plausibly reverse it, but it was not run.

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

# Sortformer, the diarizer that actually wins. No --offline: the streaming path is both the
# faster one and the better one, and it is what the app can use.
for s in S01 S02 S03 S04 S05 S06 S07 S08 S09 S10; do
  /tmp/fluidaudio-eval/src/.build/release/fluidaudiocli sortformer \
    ".corpora/dipco/$s/${s}_U01.CH1.wav" --output "/tmp/sf-$s.json"
done

# --stability N is the colour-constancy check: solve the cluster->speaker mapping independently
# in each of N time windows and count how often a window agrees with the file-wide answer.
uv run --no-project python -I Scripts/diarization_score.py "$s" "/tmp/sf-$s.json" \
  --turns /tmp/sf-turns.jsonl --stability 6

# whole AMI meetings, no window chosen
Scripts/ami-farfield-benchmark.sh EN2001a TS3003a --variant dihard3

# the ten DiPCo dinner parties. 12.5 GB, fetched separately:
#   hf download huckiyang/DiPCo --repo-type dataset --local-dir .corpora/dipco
Scripts/dipco-farfield-benchmark.sh S01 S02 S04 S07 S08 --device U01
Scripts/dipco-farfield-benchmark.sh S03 S05 S06 S09 S10 --device U04
```

`Scripts/caption-audio.py <file>` runs the same DiPCo pipeline in one command when the CLI is on
`PATH` as `~/.local/bin/fluidaudiocli`: it normalises the array channel, diarizes, scores, and
reports constancy without needing the corpus layout or a virtualenv.

`score` exists for exactly this: it takes text some other process produced and puts it through the
same `TranscriptEvaluator` and `CriticalInfoScorer` as everything else in `reports/`, so an engine
can be compared before anyone commits to integrating it.

Version note: FluidAudio was evaluated at commit `fc8c3e4` (2026-10-09). The package is moving fast
— its source comments cite issues up to #897 in a one-day-old checkout — so it is now pinned by
exact revision in `Package.swift` rather than tracked, because it ships model-download URLs and
CoreML shapes that a moving dependency would change underneath these measurements.
