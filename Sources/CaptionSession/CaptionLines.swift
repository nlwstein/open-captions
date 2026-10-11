import Foundation

/// One paragraph of captions as the screen draws it.
///
/// The rules about what a reader sees live here rather than in the views, so they are tested and
/// are the same on the live screen and in a past conversation.
public struct CaptionLine: Identifiable, Equatable, Sendable {
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
    public static func make(turns: [SavedTurn], names: [Int: String] = [:],
                            openLast: Bool = false) -> [CaptionLine] {
        let session = SavedSession(turns: turns, names: names)
        let order = turns.map(\.speaker)
        var lines: [CaptionLine] = []
        var previous: Int?? = .none
        for (index, turn) in turns.enumerated() where !turn.text.isEmpty {
            let changed = previous.map { $0 != turn.speaker } ?? true
            lines.append(CaptionLine(
                id: index,
                text: turn.text,
                speaker: turn.speaker,
                speakerNumber: turn.speaker.map { SpeakerOrder.number(of: $0, in: order) },
                label: session.label(for: turn.speaker),
                startsNewSpeaker: changed,
                isOpen: openLast && index == turns.count - 1,
                contested: turn.contested,
                start: turn.start))
            previous = .some(turn.speaker)
        }
        return lines
    }
}
