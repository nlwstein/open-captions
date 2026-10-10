import Foundation

/// A transcribed word with its time span.
public struct CaptionWord: Codable, Equatable, Sendable {
    public let text: String
    /// Seconds from the start of the recording.
    public let start: Float
    public let end: Float
    public let probability: Float

    public init(text: String, start: Float, end: Float, probability: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }

    public var duration: Float { end - start }
}

/// What the decoder thought of the window it produced a segment from.
///
/// WhisperKit computes these once per 30-second window, so every segment decoded from the same window
/// carries the same values. They are kept because the live loop has to decide whether text is worth
/// showing, and the decoder's own opinion is the cheapest evidence available — see
/// ``SpeechGate``. The alternative was a list of known hallucinated strings, which is a losing game.
///
/// Optional throughout: not every engine reports them, and a report written before they existed must
/// still decode.
public struct DecodeQuality: Codable, Equatable, Sendable {
    /// The decoder's probability that this window holds no speech at all. WhisperKit's own threshold
    /// for acting on it is 0.6.
    public let noSpeechProbability: Float

    /// Mean log-probability of the tokens produced. High means confident — *including* when the
    /// decoder is confidently wrong, which is the case that defeats WhisperKit's own silence check.
    public let averageLogProbability: Float

    /// Repeated text inflates this ratio. It is the standard tell for a decoder looping on itself.
    public let compressionRatio: Float

    /// The fallback temperature this attempt ran at. Non-zero means earlier attempts failed their
    /// quality checks and this one is a sampled retry rather than a greedy decode.
    public let temperature: Float

    public init(
        noSpeechProbability: Float,
        averageLogProbability: Float,
        compressionRatio: Float,
        temperature: Float
    ) {
        self.noSpeechProbability = noSpeechProbability
        self.averageLogProbability = averageLogProbability
        self.compressionRatio = compressionRatio
        self.temperature = temperature
    }
}

/// A transcribed span of speech, as emitted by the recognizer.
public struct CaptionSegment: Codable, Equatable, Sendable {
    public let text: String
    public let start: Float
    public let end: Float
    public let words: [CaptionWord]
    /// The decoder's judgement about the window this came from, when the engine reports one.
    public let quality: DecodeQuality?

    public init(
        text: String,
        start: Float,
        end: Float,
        words: [CaptionWord] = [],
        quality: DecodeQuality? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
        self.quality = quality
    }

    public var duration: Float { end - start }
}

/// A complete transcription of one audio input.
///
/// Deliberately independent of WhisperKit's own result types so that the evaluation layer — and
/// the tests for it — never need the model stack loaded, and so a second engine can be compared
/// against the first without rewriting the metrics.
public struct Transcript: Codable, Equatable, Sendable {
    public let text: String
    public let segments: [CaptionSegment]
    /// Language the recognizer decided on, when it reports one.
    public let language: String?

    public init(text: String, segments: [CaptionSegment], language: String? = nil) {
        self.text = text
        self.segments = segments
        self.language = language
    }

    /// All words across every segment, in time order. Empty when the recognizer was not asked for
    /// word-level timings.
    public var words: [CaptionWord] {
        segments.flatMap(\.words)
    }

    public var duration: Float {
        segments.map(\.end).max() ?? 0
    }
}

/// How long the recognizer took, and how that compares to the length of the audio.
///
/// Two latency figures matter for a live caption aid and they answer different questions:
/// time-to-first-word is how long the user waits after speech begins, and the real-time factor
/// says whether the device can keep up with continuous speech at all. A real-time factor below 1
/// means processing is faster than the audio plays.
public struct LatencyReport: Codable, Equatable, Sendable {
    /// Wall-clock seconds from handing audio to the recognizer until the first word existed.
    public let timeToFirstWord: Double
    /// Wall-clock seconds for the whole transcription.
    public let totalTime: Double
    public let audioDuration: Double
    /// Total processing time divided by audio duration. Lower is better; below 1 keeps up live.
    public let realTimeFactor: Double
    /// The recognizer's own end-to-end pipeline time, when it reports one.
    public let recognizerPipelineTime: Double?
    /// Time from the recognizer's pipeline start to its first decoded token, when reported.
    public let recognizerFirstTokenTime: Double?

    public init(
        timeToFirstWord: Double,
        totalTime: Double,
        audioDuration: Double,
        realTimeFactor: Double,
        recognizerPipelineTime: Double? = nil,
        recognizerFirstTokenTime: Double? = nil
    ) {
        self.timeToFirstWord = timeToFirstWord
        self.totalTime = totalTime
        self.audioDuration = audioDuration
        self.realTimeFactor = realTimeFactor
        self.recognizerPipelineTime = recognizerPipelineTime
        self.recognizerFirstTokenTime = recognizerFirstTokenTime
    }
}
