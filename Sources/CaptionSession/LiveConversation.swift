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
        /// Loading models. The string is what the engine says it is doing.
        case preparing(String)
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
    /// Whether an engine is loaded and waiting, so Start is instant.
    public private(set) var isWarm = false

    public var isRunning: Bool { phase == .listening || phase == .finishing }

    /// The conversation as the screen draws it.
    public var lines: [CaptionLine] {
        guard let session else { return [] }
        return CaptionLines.make(turns: session.turns, names: session.names,
                                 openLast: isRunning && (turns.last?.isOpen ?? false))
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

    /// How often a running transcript is written to disk.
    public var autosaveInterval: TimeInterval = 10

    public init(store: TranscriptStore,
                diagnosticsDirectory: URL = DiagnosticsLog.standardDirectory(),
                configuration: @escaping @MainActor () -> Configuration) {
        self.store = store
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
        if !quietly, !isRunning { phase = .preparing("Getting ready…") }
        if let warming {
            await warming.value
            if let warm, warm.key == config.engineKey {
                if case .preparing = phase { phase = .idle }
                return
            }
        }
        warm = nil
        isWarm = false
        let engine = config.makeEngine()
        let task = Task { @MainActor in
            do {
                try await engine.prepare { message in
                    Task { @MainActor in
                        if case .preparing = self.phase { self.phase = .preparing(message) }
                    }
                }
                self.warm = (config.engineKey, engine)
                self.isWarm = true
                if case .preparing = self.phase { self.phase = .idle }
            } catch {
                self.phase = .failed("Could not load the speech model. \(error.localizedDescription)")
            }
        }
        warming = task
        await task.value
        warming = nil
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
