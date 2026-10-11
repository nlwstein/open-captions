import Foundation

/// Transcripts on disk: one JSON file per conversation, in a directory of their own.
///
/// Files rather than a database, so a transcript can be copied off the phone, read by a person,
/// and replayed into the simulator as it is (see ``ReplayScript``). A few hundred conversations
/// of a few thousand words each is well within what reading a directory handles.
public final class TranscriptStore: @unchecked Sendable {

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Application Support/Transcripts — backed up with the phone, never shown in Files.
    public static func standard() -> TranscriptStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return TranscriptStore(directory: base.appendingPathComponent("Transcripts",
                                                                      isDirectory: true))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Every saved conversation, newest first. Files that fail to decode are skipped, not fatal:
    /// one damaged file must not hide all the others.
    public func all() -> [SavedSession] {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { try? Self.decoder.decode(SavedSession.self, from: Data(contentsOf: $0)) }
                .sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func load(_ id: UUID) -> SavedSession? {
        lock.withLock {
            try? Self.decoder.decode(SavedSession.self, from: Data(contentsOf: url(for: id)))
        }
    }

    /// Writes atomically, so a crash mid-write leaves the previous autosave rather than half a file.
    ///
    /// Protected until first unlock rather than completely: a conversation keeps being captioned
    /// with the screen locked, and complete protection would make every autosave then fail.
    public func save(_ session: SavedSession) throws {
        let data = try Self.encoder.encode(session)
        try lock.withLock {
            #if os(iOS)
            try data.write(to: url(for: session.id),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url(for: session.id), options: .atomic)
            #endif
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock { try? FileManager.default.removeItem(at: url(for: id)) }
    }

    public func deleteAll() {
        for session in all() { delete(session.id) }
    }

    /// Deletes conversations that started more than `days` ago. Returns how many went.
    @discardableResult
    public func prune(olderThanDays days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let old = all().filter { $0.startedAt < cutoff }
        old.forEach { delete($0.id) }
        return old.count
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
