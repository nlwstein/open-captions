import Foundation

/// What the live loop has to say after a chunk of audio.
public struct LiveUpdate: Sendable {
    /// Turns closed since the previous update, in order. These are what the app appends to the
    /// screen and never revises.
    public var newTurns: [CaptionTurn] = []

    /// The turn still being spoken, if any. It may be re-decoded and replaced, so a view should
    /// render it as provisional rather than committing it to history.
    public var provisional: CaptionTurn?

    /// Seconds of audio received since the session began. The clock the turns are measured against.
    public var elapsed: Double = 0

    /// How far the transcript has been finalized. `elapsed - committedTo` is the lag a user sees.
    public var committedTo: Double = 0

    public var level: AudioLevelMeter = AudioLevelMeter()
    public var decodes: Int = 0
    public var lastDecodeSeconds: Double = 0
    public var fallbacks: Int = 0

    /// True on the last update of a session, after the tail has been forced out.
    public var isFinal: Bool = false

    public init() {}

    public var lag: Double { max(0, elapsed - committedTo) }
}

/// How the live loop decides a turn is finished.
///
/// Separated from the loop and made pure so it can be tested without a model: this is the rule the
/// app's screen behaviour depends on, and it is the same 800 ms rule the offline harness measures
/// turns with. A turn is final once at least `silenceGap` seconds of *decoded* audio follow it —
/// which is to say, once the recognizer has looked past it and found nothing.
public enum LiveTurnCommit {

    public static func split(
        turns: [CaptionTurn],
        horizon: Double,
        silenceGap: TimeInterval,
        committedTo: Double,
        force: Bool = false
    ) -> (closed: [CaptionTurn], provisional: CaptionTurn?) {
        let uncommitted = turns.filter { Double($0.end) > committedTo + 0.001 }
        guard let last = uncommitted.last else { return ([], nil) }

        if force {
            return (uncommitted, nil)
        }

        let cutoff = horizon - silenceGap
        let closed = uncommitted.filter { Double($0.end) <= cutoff }
        let provisional = Double(last.end) > cutoff ? last : nil
        return (closed, provisional)
    }
}

/// What a finished live session cost.
public struct LiveSession: Sendable {
    public var turns: [CaptionTurn] = []
    public var decodes: Int = 0
    /// Seconds spent inside the recognizer, summed. Against ``audioSeconds`` this is the live
    /// real-time factor — the number that decides whether the loop can keep up.
    public var decodeSeconds: Double = 0
    public var wallSeconds: Double = 0
    public var audioSeconds: Double = 0
    public var fallbacks: Int = 0
    /// Speech-bearing slices that a decode returned nothing for, and that re-decoding from an
    /// earlier start brought back. Non-zero means the recovery path is earning its keep.
    public var recoveries: Int = 0
    /// Audio after the last committed word. Mostly trailing silence, so read it beside
    /// ``uncoveredSpeech`` rather than on its own.
    public var trailingAudio: Double = 0
    /// Audio the level meter called speech that arrived *after* the last word the transcript
    /// committed. This is the number that means speech was missed: it was 11.1 s on `family-dinner`
    /// before the re-decode guard existed and 0 s after. Compare it with ``trailingAudio`` — when
    /// the two agree, the uncovered tail was silence.
    public var uncoveredSpeech: Double = 0
    /// Decodes whose text ``SpeechGate`` rejected. Each one is a turn that would otherwise have been
    /// shown to the user.
    public var gatedDecodes: Int = 0

    public var realTimeFactor: Double {
        audioSeconds > 0 ? decodeSeconds / audioSeconds : 0
    }

    public var meanDecodeSeconds: Double {
        decodes > 0 ? decodeSeconds / Double(decodes) : 0
    }
}

/// What one decode of the uncommitted tail saw. Only produced when a diagnostic sink is attached;
/// a live loop that silently drops audio is much harder to diagnose than one that says what it did.
public struct LiveDecodeDiagnostic: Sendable {
    public var sliceStart: Double = 0
    public var sliceSeconds: Double = 0
    public var words: Int = 0
    /// Words the decoder returned before the already-committed prefix was dropped.
    public var rawWords: Int = 0
    public var lastWordEnd: Double = 0
    public var turns: Int = 0
    public var closed: Int = 0
    public var committedTo: Double = 0
    public var seconds: Double = 0
    public var forced: Bool = false
    /// True when the first attempt returned nothing and an earlier start brought the words back.
    public var recovered: Bool = false
    /// The decoder's own judgement about the window. Present whenever the decode produced a segment,
    /// including one that produced no words.
    public var quality: DecodeQuality?
    /// Set when ``SpeechGate`` rejected this decode's text, and why. Nil means the text was admitted,
    /// or that there was no text to judge.
    public var gate: SpeechGateVerdict?
    /// The text the gate rejected. Kept because a gate that silently eats real speech is worse than
    /// the hallucination it was built to stop, and there is no way to tell the two apart after the
    /// fact from a word count alone.
    public var droppedText: String?

    public init() {}
}

/// Configuration for the live loop.
public struct LiveConfiguration: Sendable {

    /// Silence long enough to close a turn. Matches the offline harness so the live view and the
    /// measured turn counts mean the same thing.
    public var silenceGap: TimeInterval = 0.8

    /// Audio kept before the first uncommitted word and re-decoded as context. Whisper is trained on
    /// 30-second windows and degrades sharply on very short input, so a slice that began exactly at
    /// the last committed word would have the decoder starting cold mid-conversation and producing
    /// worse text than the same audio would get offline.
    public var contextSeconds: TimeInterval = 4.0

    /// Don't decode until this much uncommitted audio has arrived. Below about a second, Whisper
    /// has too little to work with and its output is closer to a guess.
    public var minPendingSeconds: TimeInterval = 1.5

    /// Decode regardless of silence once this much has piled up, so a long unbroken monologue still
    /// produces text instead of waiting for a pause that never comes.
    public var maxPendingSeconds: TimeInterval = 12.0

    /// Floor on the time between decodes, so a burst of short pauses cannot spin the recognizer.
    public var minDecodeInterval: TimeInterval = 0.5

    /// How much further back to start when a decode returns nothing over audio that had speech in
    /// it. Two seconds is chosen from measurement rather than taste — see ``LiveTranscriber/decode``.
    public var retryBackoffSeconds: TimeInterval = 2.0

    /// Rejects text the decoder does not stand behind, so a window of room tone cannot be committed
    /// as a turn. See ``SpeechGate`` for the measurement the thresholds come from.
    public var speechGate = SpeechGate()

    public init() {}
}

/// Runs the recognizer over live audio and emits turns as they close.
///
/// The shape of the loop: audio accumulates, and every so often the uncommitted tail is decoded
/// together with a few seconds of context. Turns that the decoder has looked past are committed and
/// never revisited; the last one is provisional and gets replaced on the next decode. Nothing here
/// is diarization — turns break where speech stops, which is the visual job the app needs.
public final class LiveTranscriber {

    private let engine: WhisperEngine
    private let configuration: LiveConfiguration
    private let segmenter: TurnSegmenter

    public init(engine: WhisperEngine, configuration: LiveConfiguration = LiveConfiguration()) {
        self.engine = engine
        self.configuration = configuration
        self.segmenter = TurnSegmenter(silenceGap: configuration.silenceGap)
    }

    /// Runs until the source stops or `shouldContinue` returns false.
    ///
    /// Returns every turn the session committed, in order.
    /// - Parameter warmUp: Run after capture has started, before the first chunk is consumed.
    ///   Anything expensive the recognizer needs done once — loading the model, CoreML specializing
    ///   its graphs — belongs here rather than before ``run`` is called. Starting capture first is
    ///   what makes the difference: the stream buffers whatever arrives while this runs, so the
    ///   opening seconds of a session are delayed rather than lost. See Finding 13.
    @discardableResult
    public func run(
        source: LiveAudioSource,
        warmUp: (@Sendable () async -> Void)? = nil,
        shouldContinue: @escaping @Sendable () -> Bool,
        onUpdate: @escaping @Sendable (LiveUpdate) -> Void,
        onDecode: (@Sendable (LiveDecodeDiagnostic) -> Void)? = nil
    ) async throws -> LiveSession {

        // Audio retained from `origin` onward. Trimmed as turns commit so a long session does not
        // grow without bound: 16 kHz mono is 64 KB per second, which is 230 MB over an hour.
        var audio: [Float] = []
        var origin: Double = 0

        var committed: [CaptionTurn] = []
        var committedTo: Double = 0
        var elapsed: Double = 0

        var meter = AudioLevelMeter()
        var decodes = 0
        var fallbacks = 0
        var decodeSeconds: Double = 0
        var lastDecodeAt: Double = -.greatestFiniteMagnitude
        var lastDecodeDuration: Double = 0
        var speechSinceDecode = false
        var recoveries = 0
        var gatedDecodes = 0
        var lastSpeechAt: Double = 0
        let startedAt = DispatchTime.now()

        func emit(_ isFinal: Bool) {
            var update = LiveUpdate()
            update.elapsed = elapsed
            update.committedTo = committedTo
            update.level = meter
            update.decodes = decodes
            update.lastDecodeSeconds = lastDecodeDuration
            update.fallbacks = fallbacks
            update.isFinal = isFinal
            onUpdate(update)
        }

        /// Runs the recognizer over the retained audio from `sliceStart`, counting the attempt.
        func attempt(_ sliceStart: Double) async throws
            -> (output: EngineOutput, start: Double, audio: Double, seconds: Double) {
            let start = max(origin, sliceStart)
            let index = max(0, min(audio.count, Int(((start - origin) * 16_000).rounded())))
            let slice = Array(audio[index...])

            let decodeStart = DispatchTime.now()
            let output = try await engine.transcribe(samples: slice)
            let seconds = Double(
                DispatchTime.now().uptimeNanoseconds - decodeStart.uptimeNanoseconds
            ) / 1e9

            decodes += 1
            fallbacks += output.decodingFallbacks
            decodeSeconds += seconds
            lastDecodeDuration = seconds
            return (output, start, Double(slice.count) / 16_000, seconds)
        }

        /// Decodes the uncommitted tail and folds the result into the running state.
        func decode(force: Bool) async throws {
            var result = try await attempt(committedTo - configuration.contextSeconds)
            // The decoder saw the context too, and re-emits it. Dropping every word that starts at or
            // before the commit point keeps the text from being printed twice — and because the
            // segmenter then sees no word before the boundary, it cannot invent a turn break out of
            // the silence that the dropped context used to sit in.
            var pending = Self.trim(result.output.transcript, after: Float(committedTo - result.start))
            var recovered = false

            // A window that fails WhisperKit's quality checks is retried at rising temperatures, and
            // those retries *sample* rather than decode greedily. When the ladder is spent,
            // `TranscribeTask` returns the last attempt — its worst — and `SegmentSeeker` then judges
            // that attempt silent and drops the window outright. Nothing is raised; the words are
            // simply absent, and `fallbacks` is the only trace.
            //
            // Measured on a 15.1 s slice of `family-dinner` beginning at 25.2 s: 0 words, 5 fallbacks,
            // three runs out of three. The same audio from 24.5 s gave 36 words with no fallback at
            // all, and from 23.2 s gave 43. So the loss is real, silent, and — the part that makes it
            // fixable — a property of *where the slice starts* rather than of the audio in it.
            //
            // Which is why the retry moves the start instead of re-rolling the same slice: an
            // identical decode lands on an identical failure.
            //
            // Emptiness is judged after the trim, not before. A failed window still sometimes returns
            // a word or two of the context it was shown, and those are dropped — so testing the raw
            // output would call the decode a success on text the user has already read. That mistake
            // is why the first version of this guard never fired.
            if pending.words.isEmpty,
               speechSinceDecode,
               result.audio >= configuration.minPendingSeconds {
                let backedOff = max(origin, result.start - configuration.retryBackoffSeconds)
                if backedOff < result.start {
                    let retry = try await attempt(backedOff)
                    let retryPending = Self.trim(
                        retry.output.transcript,
                        after: Float(committedTo - retry.start)
                    )
                    result = retry
                    pending = retryPending
                    recovered = true
                }
                if recovered, !pending.words.isEmpty { recoveries += 1 }
            }

            // Only now ask whether the text is worth showing, and the order matters: an empty tail is
            // the recovery guard's business, and the gate judges empty text an artefact — run first,
            // it would suppress the very retry that exists to bring real words back.
            //
            // A rejected window is dropped rather than retried. The decoder has told us it heard
            // nothing; re-decoding would ask the same question of the same audio and get the same
            // answer, which is what the retry moves the start to avoid.
            var gateVerdict: SpeechGateVerdict?
            var droppedText: String?
            if !pending.words.isEmpty {
                let verdict = configuration.speechGate.verdict(
                    text: pending.text,
                    quality: result.output.transcript.segments.first?.quality
                )
                if verdict != .speech {
                    gateVerdict = verdict
                    droppedText = pending.text
                    gatedDecodes += 1
                    pending = Transcript(text: "", segments: [])
                }
            }

            let sliceStart = result.start
            let output = result.output
            let lastDecodeDuration = result.seconds
            let turns = pending.words.isEmpty
                ? []
                : segmenter.turns(from: pending).map { turn in
                    CaptionTurn(
                        text: turn.text,
                        start: turn.start + Float(sliceStart),
                        end: turn.end + Float(sliceStart),
                        wordCount: turn.wordCount
                    )
                }

            let (closed, provisional) = LiveTurnCommit.split(
                turns: turns,
                horizon: elapsed,
                silenceGap: configuration.silenceGap,
                committedTo: committedTo,
                force: force
            )

            if !closed.isEmpty {
                committed.append(contentsOf: closed)
                if let last = closed.last {
                    committedTo = max(committedTo, Double(last.end))
                }
                // Retention covers the retry's backoff as well as the ordinary context, or the
                // recovery path would have no audio to move the start into.
                trim(
                    &audio,
                    origin: &origin,
                    keepingFrom: committedTo - configuration.contextSeconds
                        - configuration.retryBackoffSeconds
                )
            }

            var update = LiveUpdate()
            update.newTurns = closed
            update.provisional = provisional
            update.elapsed = elapsed
            update.committedTo = committedTo
            update.level = meter
            update.decodes = decodes
            update.lastDecodeSeconds = lastDecodeDuration
            update.fallbacks = fallbacks
            update.isFinal = force
            onUpdate(update)

            var diagnostic = LiveDecodeDiagnostic()
            diagnostic.sliceStart = sliceStart
            diagnostic.sliceSeconds = result.audio
            diagnostic.words = pending.words.count
            diagnostic.rawWords = output.transcript.words.count
            diagnostic.lastWordEnd = Double(pending.words.last?.end ?? 0) + sliceStart
            diagnostic.turns = turns.count
            diagnostic.closed = closed.count
            diagnostic.committedTo = committedTo
            diagnostic.seconds = lastDecodeDuration
            diagnostic.forced = force
            diagnostic.recovered = recovered
            // Read from the raw output rather than the trimmed tail: an empty tail still carries the
            // window's judgement, and that is the case the diagnostic most needs to explain.
            diagnostic.quality = output.transcript.segments.first?.quality
            diagnostic.gate = gateVerdict
            diagnostic.droppedText = droppedText
            onDecode?(diagnostic)

            lastDecodeAt = elapsed
            speechSinceDecode = false
        }

        // Pacing and capture happen in the source's own task; this loop consumes chunks as they
        // arrive. Buffering is unbounded, so a decode that runs long delays the *display* rather
        // than losing audio — falling behind should show up as lag, not as missing words.
        //
        // Which is also why the warm-up belongs here and not before the call. Capture is live from
        // this line; everything the recognizer needs to do before it can decode happens with the
        // stream filling up behind it, so the cost is paid in latency instead of in lost words.
        // Measured before this ordering: the microphone was not capturing until 0.65–2.1 s after
        // playback began, and the sentence spoken in that window was never recorded.
        let stream = try await source.stream()
        if let warmUp {
            await warmUp()
        }

        for try await chunk in stream {
            audio.append(contentsOf: chunk)
            elapsed += Double(chunk.count) / 16_000
            meter.append(chunk)
            if meter.isSpeaking {
                speechSinceDecode = true
                // Where the last speech the meter heard ended. Compared against `committedTo` at the
                // end of the session, it says whether anything spoken went unshown.
                lastSpeechAt = elapsed
            }

            // Cheap updates between decodes so the level meter and clock stay live. The display
            // throttles; the loop does not guess at what the display wants.
            emit(false)

            // Decoding inline means chunks queue up behind it rather than being dropped.
            //
            // Both gates are needed. `newAudio` is the one that matters after a decode that found
            // nothing: without it the loop re-decodes the same unchanged tail every time
            // `minDecodeInterval` elapses, which measured at 25 wasted decodes — 47 seconds of
            // recognizer time — on a single 46.7-second fixture.
            let pendingSeconds = elapsed - committedTo
            let newAudio = elapsed - lastDecodeAt
            if newAudio >= configuration.minPendingSeconds,
               pendingSeconds >= configuration.minPendingSeconds,
               elapsed - lastDecodeAt >= configuration.minDecodeInterval,
               (meter.trailingSilence >= configuration.silenceGap && speechSinceDecode)
                   || pendingSeconds >= configuration.maxPendingSeconds {
                try? await decode(force: false)
                emit(false)
            }

            if !shouldContinue() { break }
        }

        await source.stop()
        try await decode(force: true)

        return LiveSession(
            turns: committed,
            decodes: decodes,
            decodeSeconds: decodeSeconds,
            wallSeconds: Double(
                DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
            ) / 1e9,
            audioSeconds: elapsed,
            fallbacks: fallbacks,
            recoveries: recoveries,
            trailingAudio: max(0, elapsed - committedTo),
            uncoveredSpeech: max(0, lastSpeechAt - committedTo),
            gatedDecodes: gatedDecodes
        )
    }

    // MARK: - Internals

    /// The part of a decoded transcript that has not been committed yet.
    ///
    /// A word belongs to the tail only if it *begins* after the point already shown, not if it merely
    /// ends after it. Each decode re-aligns the audio from scratch, so the word sitting on the
    /// commit boundary comes back with timings shifted by a few hundredths of a second — usually
    /// later. Filtering on `end` therefore lets that word through a second time and prints it twice:
    /// measured as "…I'm the project manager." followed by a one-word turn reading "manager.".
    /// Filtering on `start` is also the more defensible rule, since a word that begins inside text
    /// the user has already read cannot be a word they have not read yet.
    private static func trim(_ transcript: Transcript, after committedTo: Float) -> Transcript {
        let words = transcript.words.filter { $0.start >= committedTo }
        guard let first = words.first, let last = words.last else {
            return Transcript(text: "", segments: [])
        }
        return Transcript(
            text: words.map(\.text).joined(separator: " "),
            segments: [CaptionSegment(
                text: words.map(\.text).joined(separator: " "),
                start: first.start,
                end: last.end,
                words: words,
                // The window's judgement, not the tail's: it describes the audio the decoder was
                // shown, which is what any decision about showing the text has to be based on.
                quality: transcript.segments.first?.quality
            )]
        )
    }

    private func trim(_ audio: inout [Float], origin: inout Double, keepingFrom: Double) {
        let keepFrom = max(origin, keepingFrom)
        let drop = Int(((keepFrom - origin) * 16_000).rounded())
        guard drop > 0 else { return }
        audio.removeFirst(min(drop, audio.count))
        origin = keepFrom
    }
}
