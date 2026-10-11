import Foundation

/// One paragraph of captions as the screen draws it.
///
/// The rules about what a reader sees live here rather than in the views, so they are tested and
/// are the same on the live screen and in a past conversation.
public struct CaptionLine: Identifiable, Equatable, Sendable {
    /// The index of the paragraph's first turn, which does not change as the paragraph grows.
    public var id: Int
    public var text: String
    public var speaker: Int?
    /// 1-based, by order of first speaking. Picks the colour, so the first voice in every
    /// conversation is always the same colour.
    public var speakerNumber: Int?
    public var label: String
    /// Show the speaker's name above this paragraph. Only when the speaker changes: repeating the
    /// name on every paragraph of one person's story is noise to read past.
    public var startsNewSpeaker: Bool
    /// Still being spoken; its words may grow.
    public var isOpen: Bool
    /// Two people were talking at once, so the name above may be wrong.
    public var contested: Bool
    public var start: Double
}

public enum CaptionLines {
    /// A pause this long starts a new paragraph even when the same person goes on.
    public static let paragraphPause: Double = 3
    /// A paragraph this long ends at the next pause. One person talking for ten minutes is many
    /// paragraphs, not one, both to read and because a paragraph is re-measured every time it grows.
    public static let paragraphWords = 80

    /// Punctuated text for one speaker's turns, or nil to show them as the engine wrote them. See
    /// ``CaptionFormatter``.
    public typealias Format = (_ turns: [String], _ closed: Bool) -> String?

    /// - Parameters:
    ///   - openLast: The last turn is still being spoken.
    ///   - format: Punctuates finished turns. The words still being spoken are always shown as
    ///     the engine wrote them, so punctuation never holds them back.
    public static func make(turns: [SavedTurn], names: [Int: String] = [:],
                            openLast: Bool = false, format: Format? = nil) -> [CaptionLine] {
        let session = SavedSession(turns: turns, names: names)
        var numbers: [Int: Int] = [:]
        for case let slot? in turns.map(\.speaker) where numbers[slot] == nil {
            numbers[slot] = numbers.count + 1
        }

        // Paragraphs: runs of one speaker's turns, broken by a long pause or a long run.
        var paragraphs: [[Int]] = []
        var words = 0
        for (index, turn) in turns.enumerated() where !turn.text.isEmpty {
            if let last = paragraphs.last?.last, turns[last].speaker == turn.speaker,
               turn.start - turns[last].end < paragraphPause, words < paragraphWords {
                paragraphs[paragraphs.count - 1].append(index)
            } else {
                paragraphs.append([index])
                words = 0
            }
            words += turn.text.split(whereSeparator: \.isWhitespace).count
        }

        var lines: [CaptionLine] = []
        var previous: Int?? = .none
        for indexes in paragraphs {
            let first = turns[indexes[0]]
            let open = openLast && indexes.last == turns.count - 1
            let changed = previous.map { $0 != first.speaker } ?? true
            lines.append(CaptionLine(
                id: indexes[0],
                text: text(of: indexes.map { turns[$0].text }, open: open, format: format),
                speaker: first.speaker,
                speakerNumber: first.speaker.map { numbers[$0] ?? numbers.count + 1 },
                label: session.label(for: first.speaker),
                startsNewSpeaker: changed,
                isOpen: open,
                contested: indexes.contains { turns[$0].contested },
                start: first.start))
            previous = .some(first.speaker)
        }
        return lines
    }

    private static func text(of texts: [String], open: Bool, format: Format?) -> String {
        guard open else {
            return format?(texts, true) ?? texts.joined(separator: " ")
        }
        // The finished turns punctuated, then what is being said now as it is.
        let settled = Array(texts.dropLast())
        let now = texts.last ?? ""
        guard !settled.isEmpty else { return now }
        guard let done = format?(settled, false) else { return texts.joined(separator: " ") }
        let startsSentence = done.last.map { ".?!".contains($0) } ?? false
        return done + " " + (startsSentence ? now.prefix(1).uppercased() + now.dropFirst() : now)
    }
}
