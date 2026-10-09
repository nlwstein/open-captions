import Foundation

/// Tracks how loud the incoming audio is, for two jobs: deciding when speech has stopped, and
/// drawing a level meter.
///
/// The threshold is *relative to a recent floor* rather than absolute. A quiet room and a noisy one
/// differ by tens of decibels, and a fixed cut-off that works in a kitchen is either deaf or
/// permanently "speaking" at a restaurant table. Tracking the floor means the meter adapts, which is
/// also what the app's level display needs.
public struct AudioLevelMeter: Sendable {

    /// dBFS below which a chunk is silence no matter what the floor is doing. Guards against the
    /// adaptive part running away in a room that is silent for a long stretch: with nothing but
    /// near-zero chunks in the window, the floor sits at the bottom and a whisper would count as
    /// speech.
    public var absoluteFloor: Float = -55

    /// How far above the recent floor a chunk must sit to count as speech.
    public var speechMargin: Float = 10

    /// Chunks retained for the floor estimate. The floor is the 10th percentile of these, so a
    /// window of 100 is roughly ten seconds of audio at WhisperKit's 100 ms tap.
    public var window: Int = 100

    /// dBFS of the most recent chunk.
    public private(set) var level: Float = -120

    /// Loudness on a 0–1 scale, for display. Squared so the meter moves visibly at conversational
    /// levels instead of sitting in the top tenth of its range.
    public private(set) var normalizedLevel: Float = 0

    /// Seconds since the last chunk that sounded like speech. This is what the live loop uses to
    /// decide that a turn has finished.
    public private(set) var trailingSilence: Double = 0

    /// Whether the most recent chunk sounded like speech.
    public private(set) var isSpeaking: Bool = false

    private var recent: [Float] = []

    public init() {}

    public init(absoluteFloor: Float, speechMargin: Float, window: Int) {
        self.absoluteFloor = absoluteFloor
        self.speechMargin = speechMargin
        self.window = window
    }

    /// Feeds one chunk of 16 kHz mono audio and updates every reading.
    public mutating func append(_ chunk: [Float]) {
        let duration = Double(chunk.count) / 16_000
        level = Self.decibels(of: chunk)

        recent.append(level)
        if recent.count > window {
            recent.removeFirst(recent.count - window)
        }

        isSpeaking = level > max(Self.floor(of: recent), absoluteFloor + speechMargin)
            && level > absoluteFloor

        if isSpeaking {
            trailingSilence = 0
        } else {
            trailingSilence += duration
        }

        // -60 dBFS reads as empty, 0 dBFS as full.
        let clamped = min(max(level, -60), 0)
        let linear = (clamped + 60) / 60
        normalizedLevel = linear * linear
    }

    /// A coarse bar for the terminal, `width` characters wide.
    public func bar(width: Int) -> String {
        let filled = Int((normalizedLevel * Float(width)).rounded())
        return String(repeating: "▁", count: max(0, width - filled))
            + String(repeating: "█", count: min(width, max(0, filled)))
    }

    // MARK: - Internals

    /// The 10th percentile, not the minimum: one anomalously quiet chunk — a dropped sample, a
    /// momentary gap in the tap — would otherwise define the floor for the whole window and make
    /// everything after it read as speech.
    private static func floor(of levels: [Float]) -> Float {
        guard !levels.isEmpty else { return -120 }
        let sorted = levels.sorted()
        let index = min(sorted.count - 1, max(0, sorted.count / 10))
        return sorted[index]
    }

    private static func decibels(of chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return -120 }
        var sum: Double = 0
        for sample in chunk {
            sum += Double(sample) * Double(sample)
        }
        let rms = (sum / Double(chunk.count)).squareRoot()
        // Digital silence has no decibel value; -120 is the floor everything else is measured from.
        guard rms > 0 else { return -120 }
        return Float(20 * log10(rms))
    }
}
