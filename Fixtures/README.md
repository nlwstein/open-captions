# Fixtures

Audio the pipeline is measured against, each with a reference transcript and optional metadata.

## Layout

```
Fixtures/
  audio/<name>.wav       16 kHz mono, what the recognizer consumes
  reference/<name>.txt   what was actually said, one utterance per line
  metadata/<name>.json   scene description and the names to score strictly
```

Files are matched by filename stem, so adding a fixture means dropping three files in — there is
no registry to update.

## How ground truth is established

There are two kinds of fixture here, and they establish the reference differently.

**Synthesized from a known script** (`Scripts/make-fixtures.sh`). The reference is the text that was
fed to the speech synthesizer rather than somebody's careful transcription of a recording. That
removes the reference from the list of things that could be wrong: when the recognizer disagrees
with the reference, the recognizer is what erred. The trade-off is that synthesized speech is not
real speech, and the noise beds built around it are not real noise either. Measured against recorded
meetings those fixtures turn out to be much *harder* than the scenario they were meant to stand in
for — see the README's "Finding 1".

**Human-annotated corpus recordings** (`Scripts/make-ami-fixtures.sh`). The `ami-*` fixtures are
real meetings from the AMI Meeting Corpus, where the reference is a professional verbatim
transcription aligned to the audio by the corpus authors. Nobody here chose the words, so the
reference cannot have been tuned to flatter the recognizer.

Either way, **recordings of the actual target environment should still be added** — the AMI
meetings are real speech, but they are not this user's family and not her doctor's office. See
"Adding a real recording" below.

## The fixtures

| Fixture | Speakers | Noise | What it tests |
|---|---|---|---|
| `quiet-single-speaker` | 1 | none | The accuracy ceiling. One speaker in a quiet room; if this is poor, nothing downstream is worth measuring. |
| `doctor-visit` | 2 | none | The one that matters most. Dense in names, dosages, and negations, where a single dropped word changes what the patient should do. |
| `family-dinner` | 3 | babble + pink | The real target scenario. Short turns over a bed of other conversations. Turn segmentation should recover roughly one block per line. |
| `noisy-restaurant` | 2 | crowd + pink | Two people at a table, a room of strangers underneath. The crowd bed **overlaps** rather than taking turns, so it is loud but unintelligible — the contrast with `family-dinner` is the point. |
| `fast-speech` | 1 | none | Throughput. Long unbroken utterances at 280 words per minute; watch the real-time factor. |
| `ami-meeting` | 4 | real room | **Real speech.** A recorded four-person meeting over headset microphones. The control the synthetic fixtures are measured against. |
| `ami-meeting-far` | 4 | real room, far-field | The same meeting through one tabletop array microphone — the distance and reverberation that a phone on a table actually sees. |
| `ami-meeting-synth` | 4 | none | The same words, same four turn-takers, re-synthesized. Exists only to separate "synthetic voices" from "this conversation". |

The two noise beds are built differently on purpose, and the difference turned out to be the most
useful result so far. `make_babble` concatenates a few complete sentences, so each is intelligible.
`make_crowd` staggers eight voices 850 ms apart so they overlap, so none is. A recognizer transcribes
the first as content and ignores the second. See the README's "Finding 5".

## The AMI fixtures

Three fixtures come out of one 46-second window of `ES2002a`, the kick-off meeting where four
participants introduce themselves. It was chosen because it is a real multi-speaker conversation
with clean turn boundaries at both ends, only 1.6% of its speech has two people talking at once,
and it is dense in exactly the thing that matters here: four names, two of them repeated back.

All three share **one reference transcript, byte for byte**. That is the point of building them
together — any difference in score is the channel, not the words.

| Fixture | Channel | What it isolates |
|---|---|---|
| `ami-meeting` | mix of four headset microphones | Real voices, real room, near-field. |
| `ami-meeting-far` | one tabletop array microphone (`Array1-01`) | What distance and reverberation cost, holding everything else fixed. |
| `ami-meeting-synth` | `say`, one voice per participant | What synthetic voices cost, holding everything else fixed. |

The twin is placed on the original turn timing with the original speaker-to-voice assignment
(three male, one female, mixed accents), so it reproduces the turn-taking and not just the words.

**Level.** The corpus is mastered far below these fixtures — `ami-meeting` arrives at −39.7 LUFS
against roughly −19 for the `say` renders, and the array microphone at −46.3. Left alone that is a
confound rather than a property of real speech: at matched level the same close-mic window scores
16.0% WER with a 96.3% critical-information score, against 24.4% and 51.9% at its native level. So
every clip the script emits is given a single static gain to put its peak at −1.5 dBFS, which is
the band the rest of the library already occupies. No compression and no limiting — a limiter is
processing the recognizer would otherwise never see.

### Attribution

The audio and annotations are the **AMI Meeting Corpus**, meeting `ES2002a`, released under the
[Creative Commons Attribution 4.0 International licence](https://creativecommons.org/licenses/by/4.0/).
Corpus home: <https://groups.inf.ed.ac.uk/ami/corpus/>.

> Carletta, J., Ashby, S., Bourban, S., Flynn, M., Guillemot, M., Hain, T., Kadlec, J., Karaiskos, V.,
> Kraaij, W., Kronenthal, M., Lathoud, G., Lincoln, M., Lisowska, A., McCowan, I., Post, W.,
> Reidsma, D., & Wellner, P. (2006). The AMI Meeting Corpus: A pre-announcement. In *Machine Learning
> for Multimodal Interaction* (MLMI 2005), LNCS 3869, pp. 28–39. Springer.

Changes made to the source material, as the licence requires stating: the recordings were trimmed
to a 55.60–102.30 s window, downmixed to 16 kHz mono, peak-normalized as described above, and the
reference transcript was derived from the corpus word annotations for that window by
`Scripts/ami_annotations.py`.

## Regenerating

```bash
Scripts/make-fixtures.sh                    # the synthetic fixtures
Scripts/make-fixtures.sh doctor-visit       # just one

Scripts/make-ami-fixtures.sh                # the ami-* fixtures
Scripts/make-ami-fixtures.sh --corpus DIR   # use an already-downloaded corpus
```

Both need macOS `say`, `ffmpeg`, and `ffprobe`; the AMI script also needs `curl` and `unzip`, and
downloads about 62 MB the first time (into `.corpora/`, which is gitignored).

The generated WAVs are committed so the baseline stays stable — voices differ between macOS
versions, so regenerating can shift the numbers.

Regeneration is otherwise byte-reproducible: the pink-noise generator is seeded (`seed=20261008`),
because an unseeded `anoisesrc` invents a new noise floor on every run. That was worth fixing —
two baselines taken either side of a rebuild differed everywhere by up to −44 dB, which is small,
but small enough to be mistaken for the effect of whatever change was being measured.

## Adding a real recording

**Real recordings are never committed.** They are the user's family, in her doctor's office, and
this repository is not where that goes. Keep them outside the working tree and pass the path in —
`evaluate` accepts a path to any audio file, not just a fixture name:

```bash
caption-harness evaluate ~/recordings/sunday-lunch.wav
```

Scored against a sibling `.txt` of the same name, so `~/recordings/sunday-lunch.txt` is enough; no
metadata and no repository. The synthetic fixtures stay in git so the baseline is reproducible on a
clean checkout, and real audio stays on the machine that recorded it.

Resample to what the recognizer consumes:

```bash
ffmpeg -i ~/recordings/sunday-lunch.m4a -ar 16000 -ac 1 -c:a pcm_s16le \
  ~/recordings/sunday-lunch.wav
```

Type what was said into `~/recordings/sunday-lunch.txt`, one utterance per line, then:

```bash
swift run -c release caption-harness evaluate ~/recordings/sunday-lunch.wav
```

Names are the one thing a sibling `.txt` cannot express, and they matter most — proper-noun
detection only finds names the recognizer already capitalized, so a mis-heard name is invisible to
the scorer unless it was declared. Declaring them needs a metadata file, which means reproducing
the library layout somewhere outside the repository:

```
~/recordings/
  audio/sunday-lunch.wav
  reference/sunday-lunch.txt
  metadata/sunday-lunch.json
```

```json
{
  "title": "Sunday lunch",
  "scene": "kitchen table, four people",
  "speakerCount": 4,
  "noise": "real",
  "knownNames": ["margaret", "feldman", "lisinopril"],
  "notes": "Recorded on the target phone, held at table level."
}
```

Then pass the directory: `caption-harness evaluate --fixtures ~/recordings sunday-lunch`.
Until `knownNames` is populated, expect the critical information score to *overstate* accuracy on
real audio — it can only score the names it is told about.
