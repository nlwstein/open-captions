import CaptionKit
import Foundation
import Observation

/// One conversation being captioned, and the engine kept warm for the next.
///
/// Everything the live screen shows comes from here, and everything it does comes back through
/// `start()` and `stop()`. Transcripts are saved as they grow, not only at the end: a phone that
/// runs out of battery mid-appointment should still have the appointment.
@MainActor
@Observable
public final class LiveConversation {

    public enum Phase: Equatable, Sendable {
        case idle
        /// Loading models, or downloading them the first time. See `progress`.
        case preparing
        case listening
        /// Stop was pressed; the engine is flushing its last words.
        case finishing
        case failed(String)
    }

    /// What to run a session with. Built fresh for each session from the current settings, so a
    /// change in settings applies from the next conversation.
    public struct Configuration: Sendable {
        public var engineKey: String
        public var engineName: String
        public var makeEngine: @Sendable () -> CaptionEngine
        public var makeSource: @Sendable () -> LiveAudioSource

        public init(engineKey: String, engineName: String,
                    makeEngine: @escaping @Sendable () -> CaptionEngine,
                    makeSource: @escaping @Sendable () -> LiveAudioSource) {
            self.engineKey = engineKey
            self.engineName = engineName
            self.makeEngine = makeEngine
            self.makeSource = makeSource
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var turns: [StreamedTurn] = []
    public private(set) var status = CaptionerStatus()
    /// The conversation being captioned, or the one that just ended.
    public private(set) var session: SavedSession?
    /// How far the engine being loaded has got. Kept up to date even when loading quietly, so a
    /// download that started in the background shows up as soon as someone looks.
    public private(set) var progress: ModelProgress?
    /// Whether an engine is loaded and waiting, so Start is instant.
    public private(set) var isWarm = false
    /// The microphone as iOS set it up for this session, once capture has started. Asked for
    /// after the first audio rather than at Start, when the session has no route yet.
    public private(set) var input: AudioOrigin?

    public var isRunning: Bool { phase == .listening || phase == .finishing }

    /// Punctuates what the engine wrote, in the background. Shared with past conversations.
    public let formatter: CaptionFormatter

    /// The conversation as the screen draws it.
    public var lines: [CaptionLine] {
        guard let session else { return [] }
        // Read so the screen redraws when a paragraph has been punctuated.
        _ = formatter.revision
        let formatter = self.formatter
        return CaptionLines.make(turns: session.turns, names: session.names,
                                 openLast: isRunning && (turns.last?.isOpen ?? false),
                                 format: { formatter.formatted($0, closed: $1) })
    }

    private let store: TranscriptStore
    private let diagnosticsDirectory: URL
    private let configuration: @MainActor () -> Configuration

    private var warm: (key: String, engine: CaptionEngine)?
    private var warming: Task<Void, Never>?
    private var source: LiveAudioSource?
    private var diagnostics: DiagnosticsLog?
    private var lastSave = Date.distantPast
    private var lastStatusLog = Date.distantPast
    private var inputLogged = false

    /// How often a running transcript is written to disk.
    public var autosaveInterval: TimeInterval = 10

    public init(store: TranscriptStore,
                diagnosticsDirectory: URL = DiagnosticsLog.standardDirectory(),
                formatter: CaptionFormatter? = nil,
                configuration: @escaping @MainActor () -> Configuration) {
        self.store = store
        self.formatter = formatter ?? .none()
        self.diagnosticsDirectory = diagnosticsDirectory
        self.configuration = configuration
    }

    // MARK: - Engine

    /// Loads the engine the current settings call for, if it is not already loaded.
    ///
    /// - Parameter quietly: Load without saying so. Used after a session ends, when nobody is
    ///   waiting and the screen should go back to its resting state, not to "Getting ready".
    public func warmUp(quietly: Bool = false) async {
        let config = configuration()
        if let warm, warm.key == config.engineKey { return }
        if !quietly, !isRunning { phase = .preparing }
        if let warming {
            await warming.value
            if let warm, warm.key == config.engineKey {
                if phase == .preparing { phase = .idle }
                return
            }
        }
        warm = nil
        isWarm = false
        progress = nil
        let engine = config.makeEngine()
        let task = Task { @MainActor in
            // Through a stream, so reports from FluidAudio's queues arrive in the order sent.
            let (reports, sink) = AsyncStream<ModelProgress>.makeStream()
            let listener = Task { @MainActor in
                for await report in reports { self.apply(report) }
            }
            defer { sink.finish() }
            do {
                try await engine.prepare { sink.yield($0) }
                sink.finish()
                await listener.value
                self.progress = .ready
                self.warm = (config.engineKey, engine)
                self.isWarm = true
                if self.phase == .preparing { self.phase = .idle }
            } catch {
                self.progress = nil
                self.phase = .failed(Self.describeLoadFailure(error))
            }
        }
        warming = task
        await task.value
        warming = nil
    }

    /// Takes the step from the newest report, but never moves the bar backwards: FluidAudio's own
    /// fraction starts again from part-way when it moves from downloading a model to compiling it.
    private func apply(_ report: ModelProgress) {
        guard progress?.step != .ready else { return }
        var next = report
        next.fraction = max(report.fraction, progress?.fraction ?? 0)
        progress = next
    }

    /// What to tell someone whose models did not load. Almost always the first download, on a
    /// connection that dropped; FluidAudio passes URLSession's errors through, sometimes wrapped.
    nonisolated static func describeLoadFailure(_ error: Error) -> String {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSURLErrorDomain {
                return "The download stopped. Check the internet connection, then try again."
            }
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
                return "There is not enough space on this phone for the speech models."
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "Could not load the speech model. \(error.localizedDescription)"
    }

    // MARK: - Running

    public func start() async {
        guard !isRunning else { return }
        await warmUp()
        guard let engine = warm?.engine else { return }
        let config = configuration()
        // An engine runs one session. The next one is loaded after this ends.
        warm = nil
        isWarm = false

        let source = config.makeSource()
        self.source = source
        var session = SavedSession(engine: config.engineName, input: source.origin().name)
        session.names = [:]
        self.session = session
        turns = []
        status = CaptionerStatus()
        phase = .listening
        lastSave = .distantPast
        input = nil
        inputLogged = false

        let diagnostics = DiagnosticsLog(directory: diagnosticsDirectory, sessionID: session.id)
        self.diagnostics = diagnostics
        diagnostics.event("start", ["engine": config.engineName, "input": source.origin().name])

        let (updates, continuation) = AsyncStream<CaptionerUpdate>.makeStream()
        let runner = Task.detached {
            do {
                try await engine.run(source: source) { continuation.yield($0) }
                continuation.finish()
                return nil as String?
            } catch {
                continuation.finish()
                return String(describing: error)
            }
        }
        // Consumed in order on the main actor, so the screen never shows an older update after a
        // newer one.
        for await update in updates {
            handle(update)
        }
        if let failure = await runner.value {
            diagnostics.event("failed", ["error": failure])
            finish(failed: failure)
        } else if phase != .idle {
            finish(failed: nil)
        }
    }

    public func stop() async {
        guard phase == .listening else { return }
        phase = .finishing
        diagnostics?.event("stop")
        await source?.stop()
    }

    /// Names a speaker in the conversation on screen.
    public func rename(speaker: Int, to name: String) {
        guard var session else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.names[speaker] = trimmed.isEmpty ? nil : trimmed
        self.session = session
        try? store.save(session)
    }

    private func handle(_ update: CaptionerUpdate) {
        if !inputLogged, let source, update.status.audioSeconds > 0 {
            let origin = source.origin()
            input = origin
            inputLogged = true
            diagnostics?.event("microphone", ["name": origin.name, "details": origin.details])
        }
        turns = update.turns
        status = update.status
        guard var session else { return }
        session.turns = update.turns.filter { !$0.text.isEmpty }.map(SavedTurn.init)
        self.session = session

        let now = Date()
        if now.timeIntervalSince(lastStatusLog) >= 1 {
            diagnostics?.status(update.status)
            lastStatusLog = now
        }
        if update.isFinal {
            diagnostics?.status(update.status)
            finish(failed: nil)
        } else if now.timeIntervalSince(lastSave) >= autosaveInterval {
            save()
        }
    }

    private func finish(failed: String?) {
        if var session {
            session.endedAt = Date()
            self.session = session
        }
        save()
        diagnostics?.event("end", ["words": status.words, "turns": status.turns])
        diagnostics = nil
        source = nil
        phase = failed.map { .failed("Captioning stopped: \($0)") } ?? .idle
        // Load the next engine in the background, so the next Start is instant.
        Task { await self.warmUp(quietly: true) }
    }

    // MARK: - Recordings

    /// Captions a recording with the engine the settings call for, and returns its turns. Used by
    /// the microphone test, which compares setups by what the recogniser makes of each.
    ///
    /// Uses up the warm engine the way a session does, so nothing else is held in memory beside
    /// it; the next is loaded afterwards.
    public func transcribe(file: URL, speed: Double = 8) async throws -> [StreamedTurn] {
        guard !isRunning else { throw CancellationError() }
        await warmUp(quietly: true)
        guard let engine = warm?.engine else {
            throw LiveAudioError.unreadableAudio("no speech model loaded")
        }
        warm = nil
        isWarm = false
        defer { Task { await self.warmUp(quietly: true) } }
        let latest = TurnBox()
        try await Task.detached {
            try await engine.run(source: FileAudioSource(url: file, speed: speed)) { update in
                latest.set(update.turns)
            }
        }.value
        return latest.get()
    }

    private func save() {
        guard let session, !session.turns.isEmpty else { return }
        do {
            try store.save(session)
            lastSave = Date()
        } catch {
            diagnostics?.event("saveFailed", ["error": String(describing: error)])
        }
    }
}

private final class TurnBox: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [StreamedTurn] = []
    func set(_ value: [StreamedTurn]) { lock.withLock { turns = value } }
    func get() -> [StreamedTurn] { lock.withLock { turns } }
}
