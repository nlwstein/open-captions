import Foundation

/// A run of speech that reads as one turn and is shown as one block of text.
///
/// This is deliberately *not* speaker diarization. It cannot tell who spoke; it can only tell that
/// speech stopped and started again. That is enough for the visual job — a new block reads as a
/// new turn — and it costs a fraction of what real diarization would, which matters because this
/// has to run continuously on a phone in someone's pocket.
public struct CaptionTurn: Codable, Equatable, Sendable {
    public let text: String
    /// Seconds from the start of the recording.
    public let start: Float
    public let end: Float
    public let wordCount: Int

    public init(text: String, start: Float, end: Float, wordCount: Int) {
        self.text = text
        self.start = start
        self.end = end
        self.wordCount = wordCount
    }

    public var duration: Float { end - start }
}

/// Splits a transcript into turns at sustained silences.
///
/// Word-level timings are used when present, which lets a turn break in the middle of a recognizer
/// segment — the case that matters, since Whisper packs a whole 30-second window into one segment
/// regardless of how many people spoke during it. Without word timings the split degrades to
/// segment boundaries, which is much coarser and will merge distinct speakers.
public struct TurnSegmenter: Sendable {

    /// Silence long enough to end a turn. The brief calls for 800 ms: long enough not to break on
    /// the ordinary pauses inside a sentence, short enough that a change of speaker is caught.
    public var silenceGap: TimeInterval

    /// Turns shorter than this are merged into the following turn. Without it, a cough or a
    /// half-word between two sentences spawns its own block on screen, which reads as flicker.
    public var minimumTurnDuration: TimeInterval

    public init(silenceGap: TimeInterval = 0.8, minimumTurnDuration: TimeInterval = 0.0) {
        self.silenceGap = silenceGap
        self.minimumTurnDuration = minimumTurnDuration
    }

    public func turns(from transcript: Transcript) -> [CaptionTurn] {
        let words = transcript.words
        if words.isEmpty {
            return turnsFromSegments(transcript.segments)
        }
        return turnsFromWords(words)
    }

    // MARK: - Internals

    /// Whether the silence between two spans is long enough to end a turn.
    ///
    /// Compared in rounded milliseconds rather than raw seconds. Subtracting two `Float`
    /// timestamps is inexact — 1.2s minus 0.4s evaluates to slightly more than 0.8 — so a raw
    /// comparison would break a turn on a gap that is exactly the configured threshold. Rounding
    /// to the millisecond makes "greater than 800 ms" mean what it says, and a sub-millisecond
    /// difference is far below anything a listener could perceive.
    private func isTurnBreak(after end: Float, before start: Float) -> Bool {
        // Recognizers occasionally emit non-monotonic timestamps; a negative gap is not a pause.
        let gapMilliseconds = (Double(max(0, start - end)) * 1000).rounded()
        return gapMilliseconds > (silenceGap * 1000).rounded()
    }

    private func turnsFromWords(_ words: [CaptionWord]) -> [CaptionTurn] {
        var turns: [CaptionTurn] = []
        var current: [CaptionWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                current = []
                return
            }
            turns.append(CaptionTurn(
                text: text,
                start: first.start,
                end: last.end,
                wordCount: current.count
            ))
            current = []
        }

        for word in words {
            if let previous = current.last, isTurnBreak(after: previous.end, before: word.start) {
                flush()
            }
            current.append(word)
        }
        flush()

        return mergeShortTurns(turns)
    }

    private func turnsFromSegments(_ segments: [CaptionSegment]) -> [CaptionTurn] {
        var turns: [CaptionTurn] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            if let previous = turns.last, !isTurnBreak(after: previous.end, before: segment.start) {
                turns[turns.count - 1] = CaptionTurn(
                    text: previous.text + " " + text,
                    start: previous.start,
                    end: segment.end,
                    wordCount: previous.wordCount + wordCount
                )
                continue
            }
            turns.append(CaptionTurn(
                text: text,
                start: segment.start,
                end: segment.end,
                wordCount: wordCount
            ))
        }
        return mergeShortTurns(turns)
    }

    private func mergeShortTurns(_ turns: [CaptionTurn]) -> [CaptionTurn] {
        guard minimumTurnDuration > 0 else { return turns }
        var merged: [CaptionTurn] = []
        for turn in turns {
            guard let previous = merged.last,
                  TimeInterval(previous.duration) < minimumTurnDuration else {
                merged.append(turn)
                continue
            }
            merged[merged.count - 1] = CaptionTurn(
                text: previous.text + " " + turn.text,
                start: previous.start,
                end: turn.end,
                wordCount: previous.wordCount + turn.wordCount
            )
        }
        return merged
    }
}
