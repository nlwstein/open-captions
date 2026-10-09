#!/usr/bin/env bash
#
# Generates the audio fixtures the harness is measured against.
#
# Ground truth comes for free: every fixture is built by speaking a known script, so the reference
# transcript is the input text rather than somebody's careful transcription of a recording. That
# makes the scoring trustworthy — when the recognizer disagrees with the reference, the reference
# is not the thing that is wrong.
#
# Requires macOS `say`, `ffmpeg`, and `ffprobe`.
#
# Usage: Scripts/make-fixtures.sh [fixture-name ...]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/Fixtures"
BUILD="$ROOT/.fixture-build"

mkdir -p "$FIXTURES/audio" "$FIXTURES/reference" "$FIXTURES/metadata" "$BUILD"

for tool in say ffmpeg ffprobe; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

# Voices are chosen from the voices macOS ships with. Distinct voices matter: the point of the
# multi-speaker fixtures is that a human can tell who is talking, so the harness can too.
VOICE_A="Samantha"   # en_US female
VOICE_B="Daniel"     # en_GB male
VOICE_C="Kathy"      # en_US female
VOICE_D="Ralph"      # en_US male
VOICE_E="Sandy"      # en_US female

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

# speak <voice> <rate> <text> <output.caf>
speak() {
  local voice="$1" rate="$2" text="$3" out="$4"
  say -v "$voice" -r "$rate" -o "$out" --data-format=LEF32@16000 "$text"
}

# duration_of <file> -> seconds, e.g. 2.531
duration_of() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
}

# render_lines <fixture> <rate> <<< "voice|start_ms|text"
# Renders each line to its own file under $BUILD/<fixture>/ and writes the list of rendered files
# to $BUILD/<fixture>/lines.tsv as: start_ms<TAB>path<TAB>text
render_lines() {
  local fixture="$1" rate="$2"
  local dir="$BUILD/$fixture"
  rm -rf "$dir"
  mkdir -p "$dir"

  local index=0
  : > "$dir/lines.tsv"
  while IFS='|' read -r voice start_ms text; do
    [ -z "${text:-}" ] && continue
    local clip="$dir/line_$(printf '%03d' "$index").caf"
    speak "$voice" "$rate" "$text" "$clip"
    printf '%s\t%s\t%s\n' "$start_ms" "$clip" "$text" >> "$dir/lines.tsv"
    index=$((index + 1))
  done
}

# mix_lines <fixture> [noise-amplitude] [bed-kind] [bed-level]
# Mixes rendered lines at their offsets into Fixtures/audio/<fixture>.wav, optionally adding
# continuous background noise. bed-kind is `babble` (a few identifiable voices), `crowd` (a room
# full of overlapping ones), or empty for pink noise alone.
mix_lines() {
  local fixture="$1"
  local noise_amplitude="${2:-}"
  local bed_kind="${3:-}"
  local bed_level="${4:-0.22}"
  local dir="$BUILD/$fixture"

  # Total length is the furthest line end, so the noise track spans exactly the speech.
  local total=0
  local inputs=() filter="" index=0
  while IFS=$'\t' read -r start_ms clip text; do
    local seconds
    seconds=$(duration_of "$clip")
    local end
    end=$(awk -v s="$start_ms" -v d="$seconds" 'BEGIN { printf "%.3f", s / 1000 + d }')
    total=$(awk -v a="$total" -v b="$end" 'BEGIN { print (b > a) ? b : a }')

    inputs+=(-i "$clip")
    filter="${filter}[${index}:a]adelay=${start_ms}|${start_ms},volume=1.0[l${index}];"
    index=$((index + 1))
  done < "$dir/lines.tsv"

  local mix_inputs=""
  for ((i = 0; i < index; i++)); do
    mix_inputs="${mix_inputs}[l${i}]"
  done

  if [ -n "$noise_amplitude" ]; then
    # Speech-shaped background: pink noise, plus a bed of other voices reading unrelated text at
    # low level. Real room noise is dominated by other people talking, and a recognizer that copes
    # with pink noise alone would flatter us.
    if [ -n "$bed_kind" ]; then
      local bed="$dir/bed.caf"
      case "$bed_kind" in
        babble) make_babble "$bed" "$total" "$dir" ;;
        crowd) make_crowd "$bed" "$total" "$dir" ;;
        *) echo "Unknown bed kind: $bed_kind" >&2; exit 1 ;;
      esac

      inputs+=(-i "$bed")
      filter="${filter}[${index}:a]volume=${bed_level}[bed];"
      mix_inputs="${mix_inputs}[bed]"
      index=$((index + 1))
    fi

    local inputs_count=$index
    # The seed is fixed so regenerating the fixtures reproduces the same bytes. Without it
    # anoisesrc invents a new noise floor on every run, and two baselines taken either side of a
    # rebuild differ everywhere by up to -44 dB — small, but enough that a measured change could
    # not be attributed to the change rather than to the fixture.
    filter="${filter}anoisesrc=color=pink:amplitude=${noise_amplitude}:sample_rate=16000:duration=${total}:seed=20261008,volume=0.5[pink];"
    filter="${filter}${mix_inputs}[pink]amix=inputs=$((inputs_count + 1)):normalize=0:duration=longest[mixed]"
  else
    filter="${filter}${mix_inputs}amix=inputs=${index}:normalize=0:duration=longest[mixed]"
  fi

  ffmpeg -hide_banner -loglevel error -y \
    "${inputs[@]}" \
    -filter_complex "$filter" \
    -map "[mixed]" -ar 16000 -ac 1 -c:a pcm_s16le \
    "$FIXTURES/audio/$fixture.wav"
}

# make_babble <output> <seconds> <dir>
# Several voices reading unrelated sentences, concatenated into a continuous murmur.
make_babble() {
  local out="$1" seconds="$2" dir="$3"
  local chatter=(
    "and then she said the weather would turn by Tuesday"
    "I told him the car needs a new battery before winter"
    "we should probably get going before it gets dark"
    "did you remember to lock the back door this time"
    "the garden really needs attention after all that rain"
  )
  local voices=("$VOICE_C" "$VOICE_D" "$VOICE_E" "$VOICE_A" "$VOICE_B")
  local parts=() i=0
  for line in "${chatter[@]}"; do
    local clip="$dir/babble_$i.caf"
    say -v "${voices[$((i % ${#voices[@]}))]}" -r 200 -o "$clip" --data-format=LEF32@16000 "$line"
    parts+=(-i "$clip")
    i=$((i + 1))
  done
  # Loop the murmur to fill the requested duration.
  local concat_inputs=""
  for ((j = 0; j < i; j++)); do concat_inputs="${concat_inputs}[${j}:a]"; done
  ffmpeg -hide_banner -loglevel error -y "${parts[@]}" \
    -filter_complex "${concat_inputs}concat=n=${i}:v=0:a=1,aloop=loop=-1:size=2e9,atrim=0:${seconds}[b]" \
    -map "[b]" -ar 16000 -ac 1 "$out"
}

# make_crowd <output> <seconds> <dir>
# A room full of other people. The difference from make_babble is overlap: a dinner table is a few
# voices taking turns, a restaurant is many talking at once, so no single one is intelligible and
# the result is a wall of speech rather than a sequence of sentences.
make_crowd() {
  local out="$1" seconds="$2" dir="$3"
  local chatter=(
    "the special today is the lamb shank"
    "I think we're going to need a bigger table"
    "she said the flight was delayed again"
    "can you pass the water please"
    "they moved to Portland last September"
    "the game starts at eight if you want to watch"
    "I've been meaning to call her for weeks"
    "no I already paid the parking meter"
  )
  local voices=("$VOICE_A" "$VOICE_B" "$VOICE_C" "$VOICE_D" "$VOICE_E")
  local parts=() filter="" index=0 offset=0
  for line in "${chatter[@]}"; do
    local clip="$dir/crowd_$index.caf"
    say -v "${voices[$((index % ${#voices[@]}))]}" -r 195 -o "$clip" --data-format=LEF32@16000 "$line"
    parts+=(-i "$clip")
    # Staggered so speakers overlap rather than queue.
    filter="${filter}[${index}:a]adelay=${offset}|${offset}[k${index}];"
    index=$((index + 1))
    offset=$(( offset + 850 ))
  done
  local mix=""
  for ((j = 0; j < index; j++)); do mix="${mix}[k${j}]"; done
  # normalize=0 sums instead of averaging, so the level does not drop as voices are added; the
  # fixed 0.9 keeps the few voices overlapping at any instant just under full scale.
  ffmpeg -hide_banner -loglevel error -y "${parts[@]}" \
    -filter_complex "${filter}${mix}amix=inputs=${index}:normalize=0:duration=longest,volume=0.9,aloop=loop=-1:size=2e9,atrim=0:${seconds}[c]" \
    -map "[c]" -ar 16000 -ac 1 "$out"
}

# write_reference <fixture>
write_reference() {
  local fixture="$1"
  cut -f3 "$BUILD/$fixture/lines.tsv" > "$FIXTURES/reference/$fixture.txt"
}

# write_metadata <fixture> <json>
write_metadata() {
  printf '%s\n' "$2" > "$FIXTURES/metadata/$1.json"
}

# With no arguments on the command line, every fixture is built.
BUILD_ALL=0
if [ "$#" -eq 0 ]; then
  BUILD_ALL=1
fi

should_build() {
  local name="$1"
  if [ "$BUILD_ALL" -eq 1 ]; then
    return 0
  fi
  for wanted in "$@"; do
    if [ "$wanted" = "$name" ]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------

# A quiet room, one speaker, no noise. The ceiling on what this pipeline can do: if accuracy is
# poor here, nothing downstream is worth measuring.
build_quiet_single_speaker() {
  echo "building quiet-single-speaker"
  render_lines "quiet-single-speaker" 170 <<LINES
$VOICE_A|0|Good morning. It's nice to see you today.
$VOICE_A|4200|I put the kettle on, so we can sit in the kitchen.
$VOICE_A|9000|Did you sleep well last night?
$VOICE_A|12500|Your sister called while you were resting.
LINES
  mix_lines "quiet-single-speaker"
  write_reference "quiet-single-speaker"
  write_metadata "quiet-single-speaker" '{
  "title": "Quiet room, one speaker",
  "scene": "living room, one person talking",
  "speakerCount": 1,
  "noise": "none",
  "knownNames": ["sister"],
  "notes": "Baseline. Establishes the accuracy ceiling for this pipeline; compare every other fixture against this one."
}'
}

# A doctor's visit. This is the fixture that matters most and the reason the critical-information
# score exists: it is dense with exactly the tokens whose loss changes what the user should do.
build_doctor_visit() {
  echo "building doctor-visit"
  render_lines "doctor-visit" 165 <<LINES
$VOICE_B|0|Morning, Margaret. I'm Doctor Feldman.
$VOICE_B|4300|Your blood pressure is 148 over 92 today.
$VOICE_B|9600|I'd like you to start lisinopril, 10 milligrams, once a day.
$VOICE_A|16800|Okay. Should I still take the metformin?
$VOICE_B|21000|Yes, keep taking the metformin. That hasn't changed.
$VOICE_B|27000|Do not take it with grapefruit juice.
$VOICE_B|31500|And don't skip a dose, even if you feel fine.
$VOICE_B|37000|If you don't feel better in 3 days, call the office.
$VOICE_B|42800|The number is 555-0142.
LINES
  mix_lines "doctor-visit"
  write_reference "doctor-visit"
  write_metadata "doctor-visit" '{
  "title": "Doctor visit, two speakers",
  "scene": "consulting room, doctor and patient",
  "speakerCount": 2,
  "noise": "none",
  "knownNames": ["margaret", "feldman", "lisinopril", "metformin"],
  "notes": "The fixture that matters most. Dense in names, dosages, and negations, where a dropped word changes what the patient should do. Drug names are supplied via knownNames because they are not capitalised in speech."
}'
}

# A family dinner: three speakers, short turns, other conversations underneath. This is the
# scenario the app is actually for, and the one where energy-based VAD and single-speaker
# assumptions break down.
build_family_dinner() {
  echo "building family-dinner"
  render_lines "family-dinner" 185 <<LINES
$VOICE_C|0|So how was the drive up here?
$VOICE_D|2600|Long. There was construction almost the whole way.
$VOICE_E|6200|You must be exhausted. Sit down, I'll get you a drink.
$VOICE_C|10200|We saved you a plate. The roast is still warm.
$VOICE_D|13800|Thank you. It smells wonderful.
$VOICE_E|16500|Did Michael end up coming with you?
$VOICE_D|19800|No, he had to work. He sends his love though.
$VOICE_C|23400|Tell him we missed him. He works too hard.
$VOICE_E|27200|I'll call him tomorrow and say hello.
$VOICE_D|30400|He'd like that. He never calls anyone anymore.
$VOICE_C|34000|The garden looks lovely this year.
$VOICE_E|37200|The tomatoes did well. The peppers did not.
LINES
  mix_lines "family-dinner" "0.010" babble 0.22
  write_reference "family-dinner"
  write_metadata "family-dinner" '{
  "title": "Family dinner, three speakers over babble",
  "scene": "dining table, three people, background conversation",
  "speakerCount": 3,
  "noise": "babble + pink noise",
  "knownNames": ["michael"],
  "notes": "The real target scenario. Short turns separated by 2.5-4s gaps, with a babble bed built from other voices. Turn segmentation should recover roughly one block per line."
}'
}

# A restaurant: two people at a table, a room full of strangers underneath. Louder and denser than
# the dinner table, and the noise is *speech* rather than hum, which is the condition a captioning
# aid is most likely to meet in public.
build_noisy_restaurant() {
  echo "building noisy-restaurant"
  render_lines "noisy-restaurant" 175 <<LINES
$VOICE_D|0|Do you want the table by the window? It's quieter over there.
$VOICE_A|4400|That would be nice. Thank you, dear.
$VOICE_D|8600|I'll have the soup. What about you?
$VOICE_A|12400|Just a coffee. I'm not very hungry.
$VOICE_D|16800|Did you remember your tablets?
$VOICE_A|20200|Yes, they're in my bag. I never forget them now.
$VOICE_D|24200|Doctor Ellis said one at noon, remember.
$VOICE_A|28400|I know. I'll take it when we get home.
LINES
  mix_lines "noisy-restaurant" "0.020" crowd 0.35
  write_reference "noisy-restaurant"
  write_metadata "noisy-restaurant" '{
  "title": "Restaurant, two speakers over a crowd",
  "scene": "restaurant table, strangers talking all around",
  "speakerCount": 2,
  "noise": "crowd babble (overlapping voices) + pink noise",
  "knownNames": ["ellis"],
  "notes": "Denser and louder than family-dinner: the crowd bed overlaps rather than taking turns, so the background is unintelligible as language but still speech-shaped. Contains two negations and a dosage number."
}'
}

# Fast speech stresses the decoder's ability to keep up. A real-time factor above 1 here means
# the app would fall behind a talkative speaker.
build_fast_speech() {
  echo "building fast-speech"
  render_lines "fast-speech" 280 <<LINES
$VOICE_A|0|I was just saying to your father that we ought to go up to the lake again this summer like we used to when the children were small and everything took longer than it does now.
$VOICE_A|12000|The doctor said the tests came back fine but he wants to see you again in 6 weeks just to be sure and you should keep taking the tablets in the meantime.
LINES
  mix_lines "fast-speech"
  write_reference "fast-speech"
  write_metadata "fast-speech" '{
  "title": "Fast speech, one speaker",
  "scene": "one person talking quickly",
  "speakerCount": 1,
  "noise": "none",
  "notes": "Stress test for throughput. Long unbroken utterances at 280 words per minute; watch the real-time factor."
}'
}

ALL_FIXTURES=(
  quiet-single-speaker
  doctor-visit
  family-dinner
  noisy-restaurant
  fast-speech
)

for name in "${ALL_FIXTURES[@]}"; do
  if should_build "$name" "$@"; then
    "build_${name//-/_}"
  fi
done


echo
echo "Fixtures written to $FIXTURES"
ls -1 "$FIXTURES/audio"
