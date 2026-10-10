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

## What was not measured

- **Nothing on a device.** All of this is an M2 Pro. The relative ordering should hold; the absolute
  real-time factors will not.
- **No streaming test of Parakeet TDT.** The 0.009 figure is a full-file batch decode. Feeding it a
  live loop of sliding windows is a different measurement and it has not been run.
- **No diarization at all.** Speaker grouping — the app's headline feature — is untouched by this
  document, and Parakeet's own streaming diarizers have not been run against the speaker annotations
  in `Fixtures/annotations/`.
- **Only the default int8 encoder.** The CLI exposes `--encoder-precision int8-v2` and `--dual-decode-arbitration`;
  neither was tried.
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
```

`score` exists for exactly this: it takes text some other process produced and puts it through the
same `TranscriptEvaluator` and `CriticalInfoScorer` as everything else in `reports/`, so an engine
can be compared before anyone commits to integrating it.

Version note: FluidAudio was evaluated at commit `fc8c3e4` (2026-10-09). The package is moving fast
— its source comments cite issues up to #897 in a one-day-old checkout — so pin a commit rather than
tracking a branch if this becomes a dependency.
