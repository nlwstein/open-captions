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

/// A transcribed span of speech, as emitted by the recognizer.
public struct CaptionSegment: Codable, Equatable, Sendable {
    public let text: String
    public let start: Float
    public let end: Float
    public let words: [CaptionWord]

    public init(text: String, start: Float, end: Float, words: [CaptionWord] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
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
