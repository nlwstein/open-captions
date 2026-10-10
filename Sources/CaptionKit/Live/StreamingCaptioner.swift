import AVFoundation
import FluidAudio
import Foundation

/// One word the recogniser has committed, and roughly when it was said.
public struct StreamedWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
}

/// A run of consecutive words attributed to one speaker.
///
/// `speaker` is a Sortformer slot index, not a person. It is stable within a session and means
/// nothing across sessions, which is exactly what a colour needs and exactly what a name must not
/// assume.
public struct StreamedTurn: Sendable, Equatable {
    public var speaker: Int?
    public var text: String
    public var start: Double
    public var end: Double

    /// True for the turn still being spoken, which the renderer is allowed to rewrite.
    public var isOpen: Bool

    /// Seconds of this turn in which more than one slot was active — two people talking at once,
    /// and therefore a colour that is a coin toss.
    ///
    /// Seconds rather than a fraction of the turn, because a fraction makes the same doubt read
    /// differently depending on how long someone talked: half a second of crosstalk is the same
    /// fact inside a one-second turn and inside a ten-second one, and only the second is diluted
    /// below a threshold by the fraction. It was a fraction first, and on real audio it marked
    /// nothing at all.
    ///
    /// This is not an error to fix. A single-stream diarizer's output cannot carry two speakers at
    /// once, so on contested audio *every* answer is wrong for part of the turn; the failure is
    /// claiming otherwise. What can be fixed is the confidence: the app can show that two voices
    /// were in the room rather than pick one and say nothing.
    ///
    /// Small in practice. Sortformer's streaming output marks simultaneous activity in about 2% of
    /// a DiPCo session, against 7% offline with identical thresholds — the same model with a
    /// bounded left context is markedly more decisive about who is speaking, and mostly wrong to
    /// be so. So this fires rarely, and is worth heeding when it does.
    public var overlapSeconds: Double = 0

    /// Whether enough of this turn was crosstalk to be worth telling the reader about.
    public var isContested: Bool { overlapSeconds >= StreamedTurn.contestedThreshold }

    /// Four frames at the diarizer's 80 ms. Below this it is a single frame's disagreement — the
    /// model moving a slot across its 0.5 threshold for an instant — and marking it would put a
    /// caveat on turns where nothing audible happened. Every overlapping frame here is real: the
    /// streaming timeline applies no padding, so two slots are only ever active at once because
    /// the model put both over threshold on the same frame.
    public static let contestedThreshold = 0.3
}

/// One stretch of speech the diarizer currently attributes to one slot.
///
/// The raw material every colour is derived from, exposed because "why was that word that colour?"
/// is the first question any smoke test asks and there is no way to answer it from the transcript.
/// Segments are revised as they finalize, so a dump taken mid-session is a snapshot of belief
/// rather than a settled answer.
public struct DiarizerSegmentInfo: Sendable, Equatable {
    public var speaker: Int
    public var start: Double
    public var end: Double

    /// False while the diarizer is still willing to revise this segment. The newest words in a
    /// transcript sit in tentative segments, which is why they are coloured at all.
    public var isFinal: Bool
}

/// A snapshot of how the engine is doing, alongside the words it has produced.
///
/// Every field here exists because something went wrong without it. `realTimeFactor` is the one
/// that matters most: a live pipeline that has fallen behind still produces correct text, just late,
/// and nothing in the transcript says so. The talk times are the second: a slot that goes quiet ten
/// minutes in, while a new one appears, *is* the colour-drift failure, visible while it happens
/// rather than inferred from a score afterwards.
public struct CaptionerStatus: Sendable {
    /// Seconds of audio consumed. The clock the transcript's timestamps are on.
    public var audioSeconds: Double = 0

    /// Seconds of wall clock since the run started.
    public var wallSeconds: Double = 0

    /// Wall clock per second of audio. Below 1 means keeping up; above 1 means falling behind and
    /// never recovering on a live source. Only meaningful at playback speed 1 — replaying a file
    /// fast makes this a statement about the file source, not about the engine.
    public var realTimeFactor: Double = 0

    /// Time spent inside the engine, per second of audio. This is the number that says whether the
    /// thing can keep up, and unlike `realTimeFactor` it does not care how fast the audio was
    /// played: below 1 the engine needs less than real time, and the gap to 1 is the headroom a
    /// phone's smaller Neural Engine will eat into.
    public var processingLoad: Double = 0

    public var updates: Int = 0
    public var lastUpdateSeconds: Double = 0
    public var slowestUpdateSeconds: Double = 0
    /// Slowest update in the recent past, so a single hiccup at startup stops dominating.
    public var recentSlowestUpdateSeconds: Double = 0

    public var words: Int = 0
    public var turns: Int = 0

    /// dBFS of the most recent chunk, and the same on a 0–1 display scale.
    public var level: Float = -120
    public var normalizedLevel: Float = 0
    public var isSpeaking: Bool = false

    /// Seconds attributed to each Sortformer slot. A slot missing from this is one that has never
    /// been heard.
    public var talkTime: [Int: Double] = [:]

    /// How much of the last second each slot has been active, 0–1, indexed by slot.
    ///
    /// The diarizer's belief *right now*, as opposed to `talkTime`'s running total. The two answer
    /// different questions and only this one explains a surprising colour while it is happening: a
    /// steady total with a slot flickering here says the model is unsure this instant, which is
    /// invisible in a transcript that has not been written yet.
    public var slotActivity: [Double] = []

    /// Turns with more than one voice in them, and turns in total. The ratio is how much of this
    /// conversation no diarizer of this shape can be right about, and it is the number that decides
    /// how much the app should hedge.
    public var contestedTurns: Int = 0

    /// Total length, when the source is a file. Nil for a microphone.
    public var sourceDuration: Double?

    public init() {}

    /// Slots that have been heard, in order.
    public var speakers: [Int] { talkTime.keys.sorted() }
}

/// Everything the engine produces for one chunk of audio: the conversation so far, and where the
/// engine itself stands.
public struct CaptionerUpdate: Sendable {
    public var turns: [StreamedTurn]
    public var status: CaptionerStatus

    /// The samples this update covers, 16 kHz mono. The same audio both models just saw.
    ///
    /// Carried through rather than kept private because two things need it downstream and neither
    /// can reconstruct it: recording a session for replay, and — later — slicing an utterance back
    /// out to embed for speaker enrolment.
    public var audio: [Float]

    /// The one update after the stream ends. A renderer that rate-limits its repaints has to know
    /// which frame it is not allowed to drop, or the last words of a conversation can be decoded and
    /// never drawn.
    public var isFinal: Bool
}

/// Live captioning from a stream of audio: Parakeet EOU for the words, Sortformer for the speakers.
///
/// This is the engine the app is being built around, wired the way the app will wire it — the same
/// two models, the same chunk sizes, the same turn rule — so that using this is a fair preview of
/// using that. Where the phone will differ is the microphone and the screen, not the pipeline.
///
/// **Two upstream traps this deliberately avoids.**
///
/// `StreamingEouAsrManager.process(audioBuffer:)` returns an *empty string* — it buffers audio and
/// decodes internally, and its doc comment says the transcription happens in `finish()`. The
/// obvious-looking `transcript += try await manager.process(...)` accumulates nothing until the
/// stream ends, so a live loop built that way shows a blank screen and then dumps everything at
/// once. The live text is in `getPartialTranscript()` and the token accessors instead, and that is
/// what this reads.
///
/// The token accessors accumulate monotonically (`append(contentsOf:)` upstream), so they are
/// consumed here through a cursor rather than re-read in full. Reading them whole each chunk would
/// re-emit the entire conversation on every update.
///
/// **Nothing here is a person.** This produces slots and colours. Attaching a name to a slot is a
/// separate act with a separate failure mode, and `SortformerDiarizer.enrollSpeaker` is the only
/// thing that makes it truthful.
public final class StreamingCaptioner: @unchecked Sendable {

    public struct Options: Sendable {
        /// 320 ms is the shortest EOU chunk that holds up: 4.88% WER at 19.25x realtime in
        /// FluidAudio's own M-series benchmarks, against 8.23% at 160 ms.
        public var chunkSize: StreamingChunkSize = .ms320

        /// How long EOU must stay silent before an utterance is called finished. Upstream defaults
        /// to 1280 ms, which is longer than the app's own turn rule, so it is lowered to match.
        public var eouDebounceMs: Int = 800

        /// Must match the model the benchmark was run against or the numbers do not transfer.
        /// `.default` is what `fluidaudiocli sortformer` uses with no flags, and it is what every
        /// figure in ENGINES.md was measured with. `balancedV2_1` is also ~1.04 s but is a
        /// different model; swapping it silently would invalidate the comparison.
        public var sortformerConfig: SortformerConfig = .default

        /// A speaker change shorter than this is absorbed into the turn before it. Mirrors
        /// `Scripts/caption-audio.py`, and for the same reason: the diarizer's own resolution is
        /// ~500 ms, so anything shorter is a switch it never claimed.
        public var minTurnSeconds: Double = 0.4

        /// Silence that ends a turn even when the speaker has not changed.
        public var turnGapSeconds: Double = 0.8

        public init() {}
    }

    private let options: Options
    private let eou: StreamingEouAsrManager
    private let diarizer: SortformerDiarizer

    public init(options: Options = Options()) {
        self.options = options
        self.eou = StreamingEouAsrManager(chunkSize: options.chunkSize, eouDebounceMs: options.eouDebounceMs)
        self.diarizer = SortformerDiarizer(config: options.sortformerConfig)
    }

    /// Downloads models if needed and loads them. Cold start is tens of seconds the first time.
    public func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws {
        progress?("loading Parakeet EOU (\(options.chunkSize.durationMs) ms chunks)…")
        try await eou.loadModels()

        progress?("loading Sortformer…")
        let models = try await SortformerModels.loadFromHuggingFace(config: options.sortformerConfig)
        diarizer.initialize(models: models)

        progress?("ready")
    }

    /// A speaker the diarizer has been introduced to, and the slot it settled in.
    public struct Enrolled: Sendable {
        public var name: String
        /// The diarizer slot this voice was placed in, or nil if it found no speech in the clip.
        public var slot: Int?
    }

    /// Introduces the diarizer to a voice before the session starts.
    ///
    /// This is not a label. Feeding a person's audio through the model primes its speaker cache and
    /// FIFO with that voice, which is the only mechanism available against the failure the whole
    /// engine is otherwise exposed to: the slot-to-person mapping held for a whole recording in
    /// about four sessions of five on DiPCo, and a colour that moves to a different person
    /// mid-conversation is the one thing a reader cannot detect. A name given *during* a session is
    /// a claim about a slot and nothing more — `DiarizerSpeaker` carries no embedding, so nothing
    /// checks it later.
    ///
    /// **Must be called before `run`.** Each clip is processed as a complete utterance, which
    /// advances the model's streaming state and resets its timeline; doing that mid-session would
    /// throw away the conversation so far. The upstream API logs a warning and resets the timeline
    /// if it sees segments, which is the honest signal that this is a start-of-session operation.
    ///
    /// Roughly fifteen to thirty seconds of one person talking, without them being talked over, is
    /// the useful amount. Longer clips are mostly the other people in the room.
    @discardableResult
    public func enroll(_ clips: [(name: String, audio: [Float])]) throws -> [Enrolled] {
        try clips.map { clip in
            let speaker = try diarizer.enrollSpeaker(withAudio: clip.audio, named: clip.name)
            return Enrolled(name: clip.name, slot: speaker?.index)
        }
    }

    /// Runs until the source stops. `onUpdate` is called after every audio chunk with the whole
    /// conversation so far, so a renderer can rewrite the open turn rather than only append.
    public func run(
        source: LiveAudioSource,
        onUpdate: @escaping @Sendable (CaptionerUpdate) -> Void
    ) async throws {
        // 16 kHz mono Float32 is what both models want; the audio sources already deliver it, so
        // this format is a promise about the input rather than a conversion.
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            )
        else {
            throw LiveAudioError.unreadableAudio("could not build a 16 kHz mono format")
        }

        var words: [StreamedWord] = []
        var consumed = 0
        var clock = 0.0

        var status = CaptionerStatus()
        status.sourceDuration = source.origin().duration
        var meter = AudioLevelMeter()
        var recentUpdates: [Double] = []
        var busy = 0.0
        let started = Date()

        for try await chunk in try await source.stream() {
            guard !chunk.isEmpty else { continue }
            let updateStarted = Date()
            clock += Double(chunk.count) / 16_000

            meter.append(chunk)

            // Words first: EOU buffers internally, so feeding it a short chunk is correct and it
            // decodes whenever it has accumulated a full one.
            if let buffer = Self.buffer(from: chunk, format: format) {
                _ = try await eou.process(audioBuffer: buffer)
            }
            consumed = await harvest(into: &words, consumed: consumed, clock: clock)

            // The same samples go to the diarizer. Both models see identical audio; neither waits
            // on the other, which is what keeps the transcript from lagging behind the speech.
            diarizer.addAudio(chunk)
            _ = try? diarizer.process()

            let built = turns(words: words, open: true)
            let elapsed = Date().timeIntervalSince(updateStarted)
            busy += elapsed
            Self.record(elapsed, into: &recentUpdates)

            status.audioSeconds = clock
            status.wallSeconds = Date().timeIntervalSince(started)
            status.realTimeFactor = clock > 0 ? status.wallSeconds / clock : 0
            status.processingLoad = clock > 0 ? busy / clock : 0
            status.updates += 1
            status.lastUpdateSeconds = elapsed
            status.slowestUpdateSeconds = max(status.slowestUpdateSeconds, elapsed)
            status.recentSlowestUpdateSeconds = recentUpdates.max() ?? elapsed
            status.words = words.count
            status.turns = built.count
            status.level = meter.level
            status.normalizedLevel = meter.normalizedLevel
            status.isSpeaking = meter.isSpeaking
            status.talkTime = Self.talkTime(of: built)
            status.contestedTurns = built.filter(\.isContested).count
            status.slotActivity = Self.slotActivity(
                segments: segments(), at: clock, slots: diarizer.timeline.speakerCapacity
            )

            onUpdate(CaptionerUpdate(turns: built, status: status, audio: chunk, isFinal: false))
        }

        // Flush whatever EOU is still holding, then take the last of it.
        _ = try? await eou.finish()
        _ = await harvest(into: &words, consumed: consumed, clock: clock)
        _ = try? diarizer.finalizeSession()
        let built = turns(words: words, open: false)
        status.audioSeconds = clock
        status.wallSeconds = Date().timeIntervalSince(started)
        status.realTimeFactor = clock > 0 ? status.wallSeconds / clock : 0
        status.processingLoad = clock > 0 ? busy / clock : 0
        status.words = words.count
        status.turns = built.count
        status.talkTime = Self.talkTime(of: built)
        status.contestedTurns = built.filter(\.isContested).count
        onUpdate(CaptionerUpdate(turns: built, status: status, audio: [], isFinal: true))
    }

    /// Keeps the last second or so of per-chunk timings, for a "how bad is it right now" reading
    /// that a whole-run maximum cannot give once one slow chunk has set it.
    private static func record(_ seconds: Double, into timings: inout [Double]) {
        timings.append(seconds)
        // ~10 chunks a second, so 30 is about three seconds of history.
        if timings.count > 30 { timings.removeFirst(timings.count - 30) }
    }

    /// Seconds of speech attributed to each slot, as the reader sees it.
    ///
    /// Measured from the turns rather than from the diarizer's own segments on purpose: segments get
    /// revised as they finalize, so their totals move for reasons the display would have to explain,
    /// while a turn is what was actually drawn.
    private static func talkTime(of turns: [StreamedTurn]) -> [Int: Double] {
        var totals: [Int: Double] = [:]
        for turn in turns {
            guard let speaker = turn.speaker else { continue }
            totals[speaker, default: 0] += max(0, turn.end - turn.start)
        }
        return totals
    }

    // MARK: - Recogniser output

    /// Takes every token decoded since the last call and folds it into `words`.
    ///
    /// Parakeet emits sub-word tokens, with a leading `▁` marking a word boundary. **The
    /// timestamps are starts only.** A word's end has to be inferred from the next word's start,
    /// and that inference is wrong whenever silence follows: a word before a twelve-second gap
    /// otherwise acquires a twelve-second duration, which is long enough to pass any minimum-turn
    /// test and lands its midpoint deep inside the silence, where the speaker is somebody else.
    /// Capping the inferred duration is what keeps a single trailing word from becoming its own
    /// turn — `--from-file` on a fixture showed exactly that, with "way" alone on a line.
    ///
    /// The final word is closed against the audio clock, capped the same way.
    private func harvest(into words: inout [StreamedWord], consumed: Int, clock: Double) async -> Int {
        let tokens = await eou.getRawTokenStrings()
        let stamps = await eou.getTokenTimestampsMs()
        let available = min(tokens.count, stamps.count)
        guard consumed < available else { return consumed }

        for index in consumed..<available {
            let token = tokens[index]
            let at = Double(stamps[index]) / 1000
            let text = token.replacingOccurrences(of: "\u{2581}", with: " ")
            let startsWord = token.hasPrefix("\u{2581}") || token.hasPrefix(" ")

            if startsWord || words.isEmpty {
                if !words.isEmpty {
                    let previous = words[words.count - 1]
                    words[words.count - 1].end = min(at, previous.start + Self.maxInferredWordSeconds)
                }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                words.append(StreamedWord(text: trimmed, start: at, end: at))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = at
            }
        }
        if !words.isEmpty {
            let last = words[words.count - 1]
            words[words.count - 1].end = min(max(last.end, last.start), last.start + Self.maxInferredWordSeconds)
        }
        return available
    }

    // MARK: - Speakers

    /// Every segment the diarizer currently believes in, in time order.
    ///
    /// Tentative segments are included on purpose. Keeping them out would leave the newest words —
    /// the ones someone is reading right now — permanently uncoloured, which reads as the app
    /// having stopped working. They are allowed to be wrong and to be revised.
    public func diarizerSegments() -> [DiarizerSegmentInfo] {
        var out: [DiarizerSegmentInfo] = []
        for (_, speaker) in diarizer.timeline.speakers {
            for segment in speaker.finalizedSegments {
                out.append(Self.info(segment, isFinal: true))
            }
            for segment in speaker.tentativeSegments {
                out.append(Self.info(segment, isFinal: false))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func info(_ segment: DiarizerSegment, isFinal: Bool) -> DiarizerSegmentInfo {
        let frame = Double(segment.frameDurationSeconds)
        return DiarizerSegmentInfo(
            speaker: segment.speakerIndex,
            start: Double(segment.startFrame) * frame,
            end: Double(segment.endFrame) * frame,
            isFinal: isFinal
        )
    }

    private func segments() -> [(speaker: Int, start: Double, end: Double)] {
        diarizerSegments().map { (speaker: $0.speaker, start: $0.start, end: $0.end) }
    }

    /// What fraction of the last `window` seconds each slot was active.
    ///
    /// A plain walk over the segments rather than the grid `overlapSeconds` builds: there are a few
    /// hundred segments and four slots, so this is a few hundred comparisons per update, and it
    /// stays correct while the segment list is being revised underneath it.
    ///
    /// Every slot gets an entry, including ones never heard — the display is a fixed four bars, and
    /// a bar that vanishes reshuffles the others.
    private static func slotActivity(
        segments: [(speaker: Int, start: Double, end: Double)],
        at moment: Double,
        slots: Int,
        window: Double = 1.0
    ) -> [Double] {
        guard moment > 0 else { return Array(repeating: 0, count: slots) }
        let from = moment - window
        var active = [Double](repeating: 0, count: slots)
        for segment in segments {
            let overlap = min(segment.end, moment) - max(segment.start, from)
            guard overlap > 0, segment.speaker >= 0, segment.speaker < slots else { continue }
            active[segment.speaker] += overlap
        }
        return active.map { min(1, $0 / window) }
    }

    /// The speaker covering this moment, or the nearest one when the diarizer has a hole.
    ///
    /// Nearest rather than `nil`: a gap means the diarizer did not detect speech there, and the
    /// word demonstrably exists. Dropping it would silently delete text, which is the one failure a
    /// caption aid cannot have.
    private func speaker(at moment: Double, in segments: [(speaker: Int, start: Double, end: Double)]) -> Int? {
        for segment in segments where segment.start <= moment && moment <= segment.end {
            return segment.speaker
        }
        guard let nearest = segments.min(by: {
            min(abs(moment - $0.start), abs(moment - $0.end)) < min(abs(moment - $1.start), abs(moment - $1.end))
        }) else { return nil }
        return nearest.speaker
    }

    /// Seconds of each turn in which more than one slot was active.
    ///
    /// Computed on a coarse time grid rather than by intersecting every turn with every segment: the
    /// segment list grows all session, and this runs ten times a second, so the grid is built once
    /// per update and every turn is then a range sum over it. A hundred-millisecond step is well
    /// below the diarizer's own ~500 ms resolution, so nothing is lost by it.
    private static func overlapSeconds(
        _ turns: [StreamedTurn],
        segments: [(speaker: Int, start: Double, end: Double)],
        step: Double = 0.1
    ) -> [Double] {
        guard let last = turns.last, !segments.isEmpty, last.end > 0 else {
            return Array(repeating: 0, count: turns.count)
        }

        let count = Int(last.end / step) + 2
        var active = [UInt8](repeating: 0, count: count)
        for segment in segments {
            var index = max(0, Int(segment.start / step))
            let end = min(count - 1, Int(segment.end / step))
            while index <= end {
                // Saturating, because a fifth concurrent voice cannot exist with four slots and a
                // wrap would turn a crowded moment into an empty one.
                active[index] = min(255, active[index] + 1)
                index += 1
            }
        }

        // A running total, so each turn costs two lookups instead of a walk over its own span.
        var cumulative = [Int](repeating: 0, count: count + 1)
        for index in 0..<count {
            cumulative[index + 1] = cumulative[index] + (active[index] > 1 ? 1 : 0)
        }

        return turns.map { turn in
            let start = max(0, Int(turn.start / step))
            let end = min(count, Int(turn.end / step))
            guard end > start else { return 0 }
            return Double(cumulative[end] - cumulative[start]) * step
        }
    }

    // MARK: - Turns

    /// Words into turns: colour by speaker, split on a change or a long silence, then absorb runs
    /// too short to read.
    private func turns(words: [StreamedWord], open: Bool) -> [StreamedTurn] {
        guard !words.isEmpty else { return [] }
        let segments = segments()

        var assigned = words.map { word -> (speaker: Int?, word: StreamedWord) in
            (speaker(at: word.start, in: segments), word)
        }

        // Runs shorter than the diarizer can honestly resolve get the previous speaker's colour.
        // Repeated to a fixed point because absorbing one run can join two runs of the same
        // speaker that the absorbed run was separating.
        if options.minTurnSeconds > 0 {
            var changed = true
            while changed {
                changed = false
                var runs: [(speaker: Int?, range: Range<Int>)] = []
                for (index, entry) in assigned.enumerated() {
                    if let last = runs.last, last.speaker == entry.speaker {
                        runs[runs.count - 1].range = last.range.lowerBound..<(index + 1)
                    } else {
                        runs.append((entry.speaker, index..<(index + 1)))
                    }
                }
                guard runs.count > 1 else { break }
                for index in 1..<runs.count {
                    let run = runs[index]
                    let span = (assigned[run.range].last?.word.start ?? 0) - (assigned[run.range].first?.word.start ?? 0)
                    guard span < options.minTurnSeconds else { continue }
                    let previous = runs[index - 1].speaker
                    for position in run.range { assigned[position].speaker = previous }
                    changed = true
                    break
                }
            }
        }

        var built: [StreamedTurn] = []
        for entry in assigned {
            if var last = built.last,
               last.speaker == entry.speaker,
               entry.word.start - last.end <= options.turnGapSeconds {
                last.text += " " + entry.word.text
                last.end = entry.word.end
                last.isOpen = false
                built[built.count - 1] = last
            } else {
                built.append(
                    StreamedTurn(
                        speaker: entry.speaker,
                        text: entry.word.text,
                        start: entry.word.start,
                        end: entry.word.end,
                        isOpen: false
                    )
                )
            }
        }

        // Overlap last, because it is a property of the finished span rather than of any word, and
        // because the smoothing above has already moved words between turns.
        let overlaps = Self.overlapSeconds(built, segments: segments)
        for index in built.indices {
            built[index].overlapSeconds = overlaps[index]
        }

        if open, var last = built.last {
            last.isOpen = true
            built[built.count - 1] = last
        }
        return built
    }

    // MARK: - Helpers

    /// The longest a word's duration may be inferred to be. Roughly "a word plus the pause after
    /// it"; anything longer is silence being counted as speech. See `harvest`.
    private static let maxInferredWordSeconds = 1.5

    private static func buffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }
}
