# The feedback loop.
#
# Every target here measures the pipeline rather than eyeballing it: the harness runs the fixtures
# and writes the report that drives the next change. `make test` is the one command.

SHELL := /bin/bash
# pipefail matters: `tee` would otherwise mask a harness failure and the target would "pass".
.SHELLFLAGS := -eu -o pipefail -c

HARNESS     := .build/release/caption-harness
MODEL       := openai_whisper-large-v3_turbo
MODEL_CACHE := .models
REPORTS     := reports

# Fixture groups. Clean is the ceiling on the pipeline; hard is the scenario the app is for;
# real is recorded speech, which the synthetic fixtures turn out to overstate the difficulty of.
CLEAN := quiet-single-speaker
HARD  := noisy-restaurant family-dinner
REAL  := ami-meeting ami-meeting-far

SOURCES := $(shell find Sources -name '*.swift' 2>/dev/null) Package.swift

.PHONY: all build test test-clean test-hard test-real unit live live-file stream stream-file fixtures clean

all: test

# ---------------------------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------------------------

## Runs every fixture and writes reports/latest.md — the full report.
test: $(HARNESS)
	@mkdir -p $(REPORTS)
	$(HARNESS) report --all --model-cache $(MODEL_CACHE) | tee $(REPORTS)/latest.md

## Runs only the clean fixture. If this is not near-perfect, nothing else is worth measuring.
test-clean: $(HARNESS)
	@mkdir -p $(REPORTS)
	$(HARNESS) report $(CLEAN) --model-cache $(MODEL_CACHE) | tee $(REPORTS)/clean.md

## Runs the degraded fixtures: crowd noise and multiple speakers.
test-hard: $(HARNESS)
	@mkdir -p $(REPORTS)
	$(HARNESS) report $(HARD) --model-cache $(MODEL_CACHE) | tee $(REPORTS)/hard.md

## Runs the recorded-speech fixtures: real voices in a real room, close-mic and far-field.
## The synthetic twin is left out — it exists to be compared against, not to be a scenario.
test-real: $(HARNESS)
	@mkdir -p $(REPORTS)
	$(HARNESS) report $(REAL) --model-cache $(MODEL_CACHE) | tee $(REPORTS)/real.md

## Runs the scoring and segmentation logic. No model, no audio, so it is fast enough to run often.
unit:
	swift test

# ---------------------------------------------------------------------------------------------
# Live capture
# ---------------------------------------------------------------------------------------------

## Captions the microphone until Ctrl-C — the demo the app's screen is designed from. Tag names
## with NAMES="mum,david" so they are highlighted as they are spoken.
live: $(HARNESS)
	$(HARNESS) live --model-cache $(MODEL_CACHE) --names "$(NAMES)"

## Replays one fixture through the live loop: same buffering, same turn rule, no person needed.
## Usage: make live-file FIXTURE=family-dinner
live-file: $(HARNESS)
	$(HARNESS) live --from-file Fixtures/audio/$(FIXTURE).wav --model-cache $(MODEL_CACHE) --verbose

# ---------------------------------------------------------------------------------------------
# The app's engine, live
# ---------------------------------------------------------------------------------------------

## The engine the app will ship, running live with one colour per speaker. This is the one to sit
## in front of: `live` above is the older Whisper loop and has no diarization at all, so it cannot
## show what speakers feel like. Ctrl-C to stop.
## RECORD=run.wav also writes everything it heard, so a run worth reporting can be replayed.
stream: $(HARNESS)
	$(HARNESS) stream $(if $(RECORD),--record "$(RECORD)",)

## The same pipeline off a recording instead of the microphone — how it is tested without asking
## anyone to talk into a laptop. `make stream-file FIXTURE=family-dinner SPEED=4` to hurry it.
## SPEED is a wall-clock multiplier, so leave it at 1 to judge the latency honestly.
## FIXTURE is a fixture name, or any path to any wav: the real DiPCo recordings are far better
## material than the synthetic fixtures, which are text-to-speech of an imaginary family.
## SECONDS stops after that much audio — a full DiPCo session is 25 minutes.
##   make stream-file FIXTURE=~/Downloads/live-caption-samples/S02-seven-channel-mix.wav SECONDS=90
## RECORD=run.wav also writes what it heard, so the same audio can be replayed after a change.
STREAM_AUDIO = $(if $(findstring /,$(FIXTURE)),$(FIXTURE),Fixtures/audio/$(FIXTURE).wav)
STREAM_LIMIT = $(if $(SECONDS),--max-seconds $(SECONDS),)
stream-file: $(HARNESS)
	$(HARNESS) stream --from-file "$(STREAM_AUDIO)" --speed $(or $(SPEED),1) $(STREAM_LIMIT)

# ---------------------------------------------------------------------------------------------
# Building and fixtures
# ---------------------------------------------------------------------------------------------

build: $(HARNESS)

$(HARNESS): $(SOURCES)
	swift build -c release

## Regenerates the synthetic fixtures from their scripts. Not a dependency of `test`: the WAVs are
## committed, and regenerating them mid-comparison would move the baseline underneath you.
fixtures:
	Scripts/make-fixtures.sh

clean:
	swift package clean
	rm -rf $(REPORTS)
