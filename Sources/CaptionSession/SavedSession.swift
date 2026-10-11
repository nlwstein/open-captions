import CaptionKit
import Foundation

/// One turn of a conversation as it is kept: who (a slot), what, and when.
public struct SavedTurn: Codable, Equatable, Hashable, Sendable {
    /// Diarizer slot. Means something only within its own session; see ``SavedSession/names``.
    public var speaker: Int?
    public var text: String
    /// Seconds from the start of the session.
    public var start: Double
    public var end: Double
    /// Two voices were heard at once for long enough that the speaker is a guess.
    public var contested: Bool

    public init(speaker: Int?, text: String, start: Double, end: Double, contested: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
        self.contested = contested
    }

    public init(_ turn: StreamedTurn) {
        self.init(speaker: turn.speaker, text: turn.text, start: turn.start, end: turn.end,
                  contested: turn.isContested)
    }
}

/// A whole conversation, as it is written to disk and read back from the history screen.
///
/// Text only. No audio is kept: the people in the room did not agree to be recorded, and a
/// transcript is what the reader asked for.
public struct SavedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    /// Nil while the session is running — and afterwards too if the app was killed mid-session,
    /// in which case the transcript is complete up to the last autosave.
    public var endedAt: Date?
    public var turns: [SavedTurn]

    /// Names given to slots in this session, keyed by slot. Kept per session because a slot is
    /// decided afresh every time: slot 0 today is not slot 0 tomorrow.
    public var names: [Int: String]

    /// Which recogniser and microphone produced this, so a bad transcript can be traced.
    public var engine: String
    public var input: String

    public init(id: UUID = UUID(), startedAt: Date = Date(), endedAt: Date? = nil,
                turns: [SavedTurn] = [], names: [Int: String] = [:], engine: String = "",
                input: String = "") {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.turns = turns
        self.names = names
        self.engine = engine
        self.input = input
    }

    /// Seconds of conversation covered.
    public var duration: Double {
        if let endedAt { return endedAt.timeIntervalSince(startedAt) }
        return turns.last?.end ?? 0
    }

    public var wordCount: Int {
        turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    /// The label a person reads for a slot: the name given, otherwise "Speaker N" counting from 1
    /// in the order voices were first heard, so the first person to speak is always Speaker 1.
    public func label(for speaker: Int?) -> String {
        guard let speaker else { return "Someone" }
        if let name = names[speaker], !name.isEmpty { return name }
        return "Speaker \(SpeakerOrder.number(of: speaker, in: turns.map(\.speaker)))"
    }

    /// Words of the whole transcript that contain `query`, case- and accent-insensitively.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return turns.contains { $0.text.range(of: query, options: [.caseInsensitive,
                                                                    .diacriticInsensitive]) != nil }
            || names.values.contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }
}

/// Slot numbers as people see them.
public enum SpeakerOrder {
    /// 1-based position of `speaker` among the slots in `sequence`, by first appearance. A slot
    /// that has not appeared yet is numbered after all that have.
    public static func number(of speaker: Int, in sequence: [Int?]) -> Int {
        var seen: [Int] = []
        for case let slot? in sequence where !seen.contains(slot) {
            seen.append(slot)
        }
        return (seen.firstIndex(of: speaker) ?? seen.count) + 1
    }
}

// MARK: - Titles and export

public enum SessionTitle {
    /// "Tuesday afternoon" for this week, "Tuesday 3 March, afternoon" before that — the way a
    /// person would describe when a conversation happened, rather than a timestamp.
    public static func make(for date: Date, now: Date = Date(),
                            calendar: Calendar = .current, locale: Locale = .current) -> String {
        let part = partOfDay(calendar.component(.hour, from: date))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(part)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(part)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 0, days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return "\(formatter.string(from: date)) \(part)"
        }
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return "\(formatter.string(from: date)), \(part)"
    }

    static func partOfDay(_ hour: Int) -> String {
        switch hour {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }
}

public enum TranscriptExport {
    /// Plain text with the paragraphs the screen shows, each under its speaker's name, for sharing
    /// with a family member or a doctor.
    ///
    /// - Parameter format: Punctuation, as on screen. Paragraphs not punctuated yet are shared as
    ///   the engine wrote them.
    public static func plainText(_ session: SavedSession, title: String? = nil,
                                 format: CaptionLines.Format? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var out = (title ?? SessionTitle.make(for: session.startedAt)) + "\n"
        out += formatter.string(from: session.startedAt) + "\n\n"
        for line in CaptionLines.make(turns: session.turns, names: session.names, format: format) {
            out += "\(line.label): \(line.text)\n\n"
        }
        out += "Captioned automatically on this phone. Words and speakers may be wrong.\n"
        return out
    }
}
