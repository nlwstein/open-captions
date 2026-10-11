import Foundation

/// One paragraph of captions as the screen draws it.
///
/// The rules about what a reader sees live here rather than in the views, so they are tested and
/// are the same on the live screen and in a past conversation.
public struct CaptionLine: Identifiable, Equatable, Sendable {
    /// Where the paragraph starts, which does not change as it grows: ``firstTurn`` and
    /// ``firstWord`` in one number.
    public var id: Int
    /// The turn the paragraph starts in, and the word of that turn it starts at. A paragraph can
    /// start mid-turn, where a sentence ended.
    public var firstTurn: Int
    public var firstWord: Int
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

/// How one person's long run of speech is broken into paragraphs.
///
/// Always at a pause of ``hardPause``. Otherwise only where a sentence ends — as punctuated, so
/// only once the punctuation is ready — and only when the paragraph is already long, the speaker
/// paused, or the next sentence starts with words that move a story on ("So", "Anyway"). Speech
/// has no paragraphs of its own; these are the places a reader's eye can rest.
///
/// A sentence end can fall anywhere in a turn. The engine ends turns where the speaker draws
/// breath, which on far-field speech is more often mid-sentence than not: allowed to break only
/// between turns, four 10-minute AMI meetings got 13 breaks in all, and paragraphs of 160 words.
///
/// Each break is decided once, from words that are no longer changing, so a break never moves
/// once it is on screen: text being read does not jump. (Unless the engine itself re-divides
/// turns between speakers, which moves words regardless.)
public enum ParagraphBreaks {
    /// A pause this long starts a new paragraph whatever was said.
    public static let hardPause: Double = 3
    /// A paragraph this long ends even mid-sentence. Rarely reached with punctuation, since
    /// sentences end sooner; it bounds how much is re-punctuated as a paragraph grows.
    public static let hardWords = 150

    /// At a sentence end, a paragraph ends if it has this many words,
    public static let longWords = 60
    /// or the speaker paused this long and it has ``pauseWords``,
    public static let shortPause: Double = 1.5
    public static let pauseWords = 20
    /// or the next sentence starts with one of ``markers`` and it has ``markerWords``.
    public static let markerWords = 30
    /// Words after a possible break that are read before deciding whether a sentence ended
    /// there; these are the words that move to the new paragraph when it is decided. Without them
    /// the punctuation nearly always thinks a sentence ended: measured on AMI, at 256 of 335
    /// breaks between one speaker's turns where, reading on, it did not; with four words, at 2;
    /// with six, at none. Six also finds more of the ends that are there: the longest paragraph
    /// in two AMI meetings fell from 130 words to 94.
    public static let lookahead = 6

    /// Words that start a new part of what someone is saying. Not "okay" or "well", which start
    /// as many replies as new subjects.
    static let markers: [[String]] = [
        ["so"], ["anyway"], ["anyways"], ["now"], ["alright"], ["also"], ["meanwhile"],
        ["by", "the", "way"], ["the", "other", "thing"], ["another", "thing"], ["speaking", "of"],
    ]

    static func startsWithMarker(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(3)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        return markers.contains { words.starts(with: $0) }
    }

    /// Whether punctuated text ends a sentence.
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.split(whereSeparator: \.isWhitespace).last else { return false }
        return last.reversed().prefix { !$0.isLetter && !$0.isNumber }.contains { ".?!".contains($0) }
    }
}

public enum CaptionLines {

    /// Punctuated text for one speaker's turns, or nil to show them as the engine wrote them. See
    /// ``CaptionFormatter``.
    public typealias Format = (_ turns: [String], _ closed: Bool) -> String?

    /// Turns longer than this many words would share ids with the next turn's paragraphs.
    static let idStride = 4_096

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

        // Runs: one speaker's turns with no long pause between them.
        var runs: [[Word]] = []
        for (index, turn) in turns.enumerated() {
            let texts = turn.text.split(whereSeparator: \.isWhitespace)
            guard !texts.isEmpty else { continue }
            var pause = 0.0
            if let last = runs.last?.last.map({ turns[$0.turn] }), last.speaker == turn.speaker,
               turn.start - last.end < ParagraphBreaks.hardPause {
                pause = turn.start - last.end
            } else {
                runs.append([])
            }
            runs[runs.count - 1] += texts.enumerated().map {
                Word(text: $1, turn: index, offset: $0, pause: $0 == 0 ? pause : 0)
            }
        }

        var lines: [CaptionLine] = []
        var previous: Int?? = .none
        for run in runs {
            let open = openLast && run.last?.turn == turns.count - 1
            let speaker = turns[run[0].turn].speaker
            var afterSentence = false
            for paragraph in paragraphs(of: run, open: open, format: format) {
                let words = run[paragraph.range]
                let first = words[words.startIndex]
                let isOpen = open && paragraph.range.upperBound == run.count
                let shown: String
                switch paragraph.ending {
                case .sentence(let done):
                    shown = done
                case .unfinished:
                    let following = lookahead(run[paragraph.range.upperBound...], open: open)
                    shown = format.flatMap { punctuated(texts(words), readingOn: following, format: $0) }
                        ?? words.map(\.text).joined(separator: " ")
                case .end:
                    shown = text(of: words, open: isOpen, afterSentence: afterSentence, format: format)
                }
                if case .sentence = paragraph.ending { afterSentence = true } else { afterSentence = false }
                lines.append(CaptionLine(
                    id: first.turn * idStride + first.offset,
                    firstTurn: first.turn,
                    firstWord: first.offset,
                    text: shown,
                    speaker: speaker,
                    speakerNumber: speaker.map { numbers[$0] ?? numbers.count + 1 },
                    label: session.label(for: speaker),
                    startsNewSpeaker: previous.map { $0 != speaker } ?? true,
                    isOpen: isOpen,
                    contested: Set(words.map(\.turn)).contains { turns[$0].contested },
                    start: turns[first.turn].start))
                previous = .some(speaker)
            }
        }
        return lines
    }

    private struct Word {
        var text: Substring
        var turn: Int
        /// Position in its turn.
        var offset: Int
        /// Seconds of silence before it, if it starts a turn.
        var pause: Double
    }

    private struct Paragraph {
        /// Words of the run.
        var range: Range<Int>
        var ending: Ending
    }

    private enum Ending {
        /// The run ends here, because the speaker changed or paused: the last word ends a
        /// sentence, with a full stop if punctuation gives it none.
        case end
        /// Broken at a sentence end the punctuation found; this is that punctuated text.
        case sentence(String)
        /// Cut by length, perhaps mid-sentence, so no full stop is added.
        case unfinished
    }

    /// One speaker's run of words, broken where ``ParagraphBreaks`` says.
    private static func paragraphs(of run: [Word], open: Bool, format: Format?) -> [Paragraph] {
        // The last word of a turn still being spoken may yet grow.
        let settled = open ? run.count - 1 : run.count
        var result: [Paragraph] = []
        var start = 0
        // A break waiting on punctuation: none after it in this run until it is decided, so a
        // later break never has to move when it is.
        var waiting = false
        for next in run.indices.dropFirst() {
            let length = next - start
            if length >= ParagraphBreaks.hardWords {
                result.append(Paragraph(range: start..<next, ending: .unfinished))
                start = next
                continue
            }
            guard !waiting, let format else { continue }
            let word = run[next]
            let candidate = length >= ParagraphBreaks.longWords
                || (word.offset == 0 && word.pause >= ParagraphBreaks.shortPause
                    && length >= ParagraphBreaks.pauseWords)
                || (length >= ParagraphBreaks.markerWords && ParagraphBreaks.startsWithMarker(
                    run[next..<min(next + 3, run.count)].map(\.text).joined(separator: " ")))
            guard candidate else { continue }
            // Read on a few words before deciding: see ``ParagraphBreaks/lookahead``.
            let end = min(next + ParagraphBreaks.lookahead, settled)
            guard end - next == ParagraphBreaks.lookahead || !open,
                  let done = format(texts(run[start..<max(end, next)]), false) else {
                waiting = true
                continue
            }
            let before = done.split(whereSeparator: \.isWhitespace).prefix(length)
                .joined(separator: " ")
            if ParagraphBreaks.endsSentence(before) {
                result.append(Paragraph(range: start..<next, ending: .sentence(before)))
                start = next
            }
        }
        result.append(Paragraph(range: start..<run.count, ending: .end))
        return result
    }

    /// Words as the turns they came in, which the punctuation is given: a turn's start is where
    /// the engine heard a pause, and its capital there is only a guess.
    private static func texts(_ words: ArraySlice<Word>) -> [String] {
        var out: [String] = []
        var turn: Int?
        for word in words {
            if word.turn == turn {
                out[out.count - 1] += " " + word.text
            } else {
                out.append(String(word.text))
                turn = word.turn
            }
        }
        return out
    }

    /// The first words after a paragraph, read to punctuate its end. Only whole words.
    private static func lookahead(_ words: ArraySlice<Word>, open: Bool) -> [Substring] {
        let whole = open ? words.dropLast() : words
        return whole.prefix(ParagraphBreaks.lookahead).map(\.text)
    }

    /// `texts` punctuated as read with `following` after them, or nil until that is ready.
    private static func punctuated(_ texts: [String], then following: [Substring],
                                   format: Format) -> String? {
        let count = texts.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        let request = following.isEmpty ? texts : texts + [following.joined(separator: " ")]
        return format(request, false).map {
            $0.split(whereSeparator: \.isWhitespace).prefix(count).joined(separator: " ")
        }
    }

    /// The best punctuation ready now: read with all of `following` if that is done, else with
    /// fewer of its words, which were asked for as they arrived.
    private static func punctuated(_ texts: [String], readingOn following: [Substring],
                                   format: Format) -> String? {
        for count in stride(from: following.count, through: 0, by: -1) {
            if let done = punctuated(texts, then: Array(following.prefix(count)), format: format) {
                return done
            }
        }
        return nil
    }

    /// The last paragraph of a run.
    ///
    /// - Parameter afterSentence: It starts where a sentence ended, mid-turn perhaps, so its
    ///   first word takes a capital.
    private static func text(of words: ArraySlice<Word>, open: Bool, afterSentence: Bool,
                             format: Format?) -> String {
        func raw(_ words: ArraySlice<Word>) -> String {
            let text = words.map(\.text).joined(separator: " ")
            return afterSentence ? text.prefix(1).uppercased() + text.dropFirst() : text
        }
        guard open else {
            return format?(texts(words), true) ?? raw(words)
        }
        // The finished turns punctuated, then what is being said now as it is.
        let newest = words.last?.turn
        let settled = words.prefix { $0.turn != newest }
        let now = words[settled.endIndex...]
        guard !settled.isEmpty else { return raw(now) }
        guard let format,
              let done = punctuated(texts(settled), readingOn: lookahead(now, open: true),
                                    format: format)
        else { return raw(words) }
        let text = now.map(\.text).joined(separator: " ")
        let startsSentence = ParagraphBreaks.endsSentence(done)
        return done + " " + (startsSentence ? text.prefix(1).uppercased() + text.dropFirst() : text)
    }
}
