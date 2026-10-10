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

    /// Runs until the source stops. `onUpdate` is called after every audio chunk with the whole
    /// conversation so far, so a renderer can rewrite the open turn rather than only append.
    ///
    /// `isFinal` marks the one update after the stream ends. A renderer that rate-limits its
    /// repaints has to know which frame it is not allowed to drop, or the last words of a
    /// conversation can be decoded and never drawn.
    public func run(
        source: LiveAudioSource,
        onUpdate: @escaping @Sendable ([StreamedTurn], Bool) -> Void
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

        for try await chunk in try await source.stream() {
            guard !chunk.isEmpty else { continue }
            clock += Double(chunk.count) / 16_000

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

            onUpdate(turns(words: words, open: true), false)
        }

        // Flush whatever EOU is still holding, then take the last of it.
        _ = try? await eou.finish()
        _ = await harvest(into: &words, consumed: consumed, clock: clock)
        _ = try? diarizer.finalizeSession()
        onUpdate(turns(words: words, open: false), true)
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
    private func segments() -> [(speaker: Int, start: Double, end: Double)] {
        var out: [(speaker: Int, start: Double, end: Double)] = []
        for (_, speaker) in diarizer.timeline.speakers {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                let frame = Double(segment.frameDurationSeconds)
                out.append((segment.speakerIndex, Double(segment.startFrame) * frame, Double(segment.endFrame) * frame))
            }
        }
        return out.sorted { $0.start < $1.start }
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
