import Foundation

/// What changed, read from the project's conventional commit messages.
///
/// The build writes `git log` into the app as `changelog.txt` (see `Scripts/make-changelog.sh`);
/// this turns it into something a person can read. Only the subject line of each commit is used,
/// so the changelog is exactly as good as the commit messages — which is the point of writing
/// them conventionally.
public struct Changelog: Equatable, Sendable {

    public struct Entry: Equatable, Sendable, Identifiable {
        public var hash: String
        public var date: Date
        public var kind: Kind
        public var scope: String?
        /// The subject after the `type(scope): ` prefix, first letter capitalised.
        public var summary: String
        /// Marked `!` in the subject: something that used to work differently.
        public var breaking: Bool

        public var id: String { hash }
        public var shortHash: String { String(hash.prefix(7)) }
    }

    /// Commit types, in the order a reader cares about them.
    public enum Kind: String, CaseIterable, Sendable, Comparable {
        case feat, fix, perf, docs, refactor, test, build, ci, chore, revert, style, other

        /// Changes someone using the app would notice. The rest are hidden unless asked for.
        public var isUserFacing: Bool { self == .feat || self == .fix || self == .perf || self == .revert }

        public var heading: String {
            switch self {
            case .feat: return "New"
            case .fix: return "Fixed"
            case .perf: return "Faster"
            case .revert: return "Undone"
            case .docs: return "Documentation"
            case .refactor: return "Reorganised"
            case .test: return "Tests"
            case .build, .ci: return "Build"
            case .chore, .style: return "Housekeeping"
            case .other: return "Other"
            }
        }

        public static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// Newest first.
    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries.sorted { $0.date > $1.date }
    }

    /// The commit this build was made from, or nil for a build without history.
    public var buildCommit: String? { entries.first?.shortHash }

    // MARK: - Reading

    /// Separators the build script uses: between records, and between fields in a record.
    public static let recordSeparator: Character = "\u{1E}"
    public static let fieldSeparator: Character = "\u{1F}"

    /// Reads `git log --format=%H<US>%cI<US>%s<RS>`. Merge commits and anything unparseable are
    /// skipped rather than shown as noise.
    public init(gitLog: String) {
        let iso = ISO8601DateFormatter()
        var entries: [Entry] = []
        for record in gitLog.split(separator: Self.recordSeparator) {
            let fields = record.split(separator: Self.fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty, let date = iso.date(from: String(fields[1])) else { continue }
            let subject = fields[2...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if subject.hasPrefix("Merge ") { continue }
            entries.append(Self.parse(subject: subject, hash: hash, date: date))
        }
        self.init(entries: entries)
    }

    public static func load(_ url: URL) -> Changelog? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Changelog(gitLog: text)
    }

    /// `type(scope)!: summary`, per conventionalcommits.org. A subject that does not follow it
    /// is kept, as `other`, with the subject as written.
    static func parse(subject: String, hash: String, date: Date) -> Entry {
        let pattern = #/^(?<type>[a-zA-Z]+)(\((?<scope>[^)]*)\))?(?<bang>!)?:\s*(?<summary>.+)$/#
        guard let match = subject.firstMatch(of: pattern) else {
            return Entry(hash: hash, date: date, kind: .other, scope: nil, summary: subject, breaking: false)
        }
        let kind = Kind(rawValue: match.type.lowercased()) ?? .other
        let scope = match.scope.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        let raw = String(match.summary)
        // Capitalised, unless the first word is a name with its own capitals: "iOS", "macOS".
        let firstWord = raw.prefix { !$0.isWhitespace }
        let summary = firstWord.contains(where: \.isUppercase)
            ? raw : raw.prefix(1).uppercased() + raw.dropFirst()
        return Entry(hash: hash, date: date, kind: kind, scope: scope, summary: summary,
                     breaking: match.bang != nil)
    }

    // MARK: - Grouping

    /// One day's changes, grouped by kind.
    public struct Day: Equatable, Sendable, Identifiable {
        public var date: Date
        public var groups: [Group]

        public var id: Date { date }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var kind: Kind
        public var entries: [Entry]

        public var id: Kind { kind }
    }

    /// Newest day first; within a day, new things before fixes before the rest.
    public func days(includingAll: Bool, calendar: Calendar = .current) -> [Day] {
        let shown = entries.filter { includingAll || $0.kind.isUserFacing }
        let byDay = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            let byKind = Dictionary(grouping: byDay[day]!, by: \.kind)
            return Day(date: day, groups: byKind.keys.sorted().map { Group(kind: $0, entries: byKind[$0]!) })
        }
    }
}
