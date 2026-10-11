import CaptionKit
import FluidAudio
import Foundation

/// What a live session runs: something that turns audio into turns.
///
/// A protocol so the app can be driven by ``ReplayEngine`` — a transcript played back at speaking
/// pace with no models at all — which is how the screens are built and checked in the simulator,
/// where the real models run on the CPU and may not keep up.
public protocol CaptionEngine: AnyObject, Sendable {
    func prepare(progress: (@Sendable (ModelProgress) -> Void)?) async throws
    func run(source: LiveAudioSource,
             onUpdate: @escaping @Sendable (CaptionerUpdate) -> Void) async throws
}

extension StreamingCaptioner: CaptionEngine {}

/// The recognisers the app offers. A short list on purpose: each of these was measured in
/// ENGINES.md, and an option nobody has measured is a way for a setting to make things worse.
public enum EngineChoice: String, CaseIterable, Codable, Sendable {
    /// Nemotron 0.6B, 1120 ms. What the harness ships and what was judged to work well.
    case nemotron
    /// Parakeet Unified 0.6B, 1120 ms. Same size and latency; CC-BY-4.0 rather than NVIDIA's own
    /// licence. Fewer errors overall on the five-window comparison, worse on negations and numbers.
    case unified

    public var displayName: String {
        switch self {
        case .nemotron: return "Nemotron 0.6B"
        case .unified: return "Parakeet Unified 0.6B"
        }
    }

    public var variant: StreamingModelVariant {
        switch self {
        case .nemotron: return .nemotron1120ms
        case .unified: return .parakeetUnified1120ms
        }
    }

    public func makeEngine() -> CaptionEngine {
        var options = StreamingCaptioner.Options()
        options.asrVariant = variant
        return StreamingCaptioner(options: options)
    }
}

// MARK: - Replay

/// A conversation to play back: turns with times, and nothing else.
public struct ReplayScript: Sendable, Equatable {
    public var turns: [SavedTurn]

    public init(turns: [SavedTurn]) {
        self.turns = turns.sorted { $0.start < $1.start }
    }

    public var duration: Double { turns.map(\.end).max() ?? 0 }

    /// Reads either a saved transcript or a harness `--dump`, whichever the file is.
    public static func load(_ url: URL) throws -> ReplayScript {
        let data = try Data(contentsOf: url)
        if let session = try? TranscriptStore.decoder.decode(SavedSession.self, from: data) {
            return ReplayScript(turns: session.turns)
        }
        struct Dump: Decodable {
            struct Turn: Decodable {
                var speaker: Int?
                var start: Double
                var end: Double
                var overlapSeconds: Double?
                var text: String
            }
            var turns: [Turn]
        }
        let dump = try JSONDecoder().decode(Dump.self, from: data)
        return ReplayScript(turns: dump.turns.map {
            SavedTurn(speaker: $0.speaker, text: $0.text, start: $0.start, end: $0.end,
                      contested: ($0.overlapSeconds ?? 0) >= StreamedTurn.contestedThreshold)
        })
    }

    /// The conversation as it would have looked `time` seconds in: finished turns whole, the turn
    /// being spoken with its words so far, and nothing after.
    ///
    /// Words are spread evenly across their turn. Real word times are not in a transcript, and
    /// even spacing is close enough to judge how text arriving at speaking pace reads.
    public func turns(at time: Double) -> [StreamedTurn] {
        var out: [StreamedTurn] = []
        for turn in turns where turn.start <= time {
            let overlap = turn.contested ? StreamedTurn.contestedThreshold : 0
            if time >= turn.end {
                out.append(StreamedTurn(speaker: turn.speaker, text: turn.text, start: turn.start,
                                        end: turn.end, isOpen: false, overlapSeconds: overlap))
                continue
            }
            let words = turn.text.split(separator: " ")
            let span = max(turn.end - turn.start, 0.01)
            let shown = min(words.count, Int(Double(words.count) * (time - turn.start) / span) + 1)
            out.append(StreamedTurn(speaker: turn.speaker,
                                    text: words.prefix(shown).joined(separator: " "),
                                    start: turn.start, end: time, isOpen: true,
                                    overlapSeconds: overlap))
        }
        // Only the newest turn may still be open, as with the real engine.
        for index in out.indices.dropLast() { out[index].isOpen = false }
        return out
    }
}

/// Plays a ``ReplayScript`` as if it were being heard, clocked by the audio source it is given.
///
/// Clocked by the source rather than by its own timer, so it starts, stops and finishes exactly
/// the way the real engine does: the session ends when the source ends, and a final update follows.
public final class ReplayEngine: CaptionEngine, @unchecked Sendable {
    private let script: ReplayScript
    private let download: SimulatedDownload?

    /// A first-run download acted out, so the setup screens can be seen without fetching a
    /// gigabyte: progress over `seconds`, then a moment of loading.
    public struct SimulatedDownload: Sendable {
        public var seconds: Double
        /// Drop the connection partway through, as a train going into a tunnel would.
        public var fails: Bool

        public init(seconds: Double, fails: Bool = false) {
            self.seconds = seconds
            self.fails = fails
        }
    }

    public init(script: ReplayScript, download: SimulatedDownload? = nil) {
        self.script = script
        self.download = download
    }

    public func prepare(progress: (@Sendable (ModelProgress) -> Void)?) async throws {
        if let download {
            let steps = max(Int(download.seconds * 10), 1)
            for step in 0...steps {
                let fraction = 0.9 * Double(step) / Double(steps)
                if download.fails, fraction >= 0.4 { throw URLError(.networkConnectionLost) }
                progress?(ModelProgress(step: .downloading, fraction: fraction, model: "replay"))
                try await Task.sleep(for: .milliseconds(100))
            }
            progress?(ModelProgress(step: .loading, fraction: 0.95, model: "replay"))
            try await Task.sleep(for: .seconds(1.5))
        }
        progress?(.ready)
    }

    public func run(source: LiveAudioSource,
                    onUpdate: @escaping @Sendable (CaptionerUpdate) -> Void) async throws {
        var clock = 0.0
        var status = CaptionerStatus()
        var meter = AudioLevelMeter()
        let started = Date()
        for try await chunk in try await source.stream() {
            clock += Double(chunk.count) / 16_000
            meter.append(chunk)
            let turns = script.turns(at: clock)
            status.audioSeconds = clock
            status.wallSeconds = Date().timeIntervalSince(started)
            status.updates += 1
            status.words = turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
            status.turns = turns.count
            status.level = meter.level
            status.normalizedLevel = meter.normalizedLevel
            status.isSpeaking = turns.last?.isOpen ?? false
            status.talkTime = turns.reduce(into: [:]) { time, turn in
                if let speaker = turn.speaker { time[speaker, default: 0] += turn.end - turn.start }
            }
            onUpdate(CaptionerUpdate(turns: turns, status: status, audio: chunk, isFinal: false))
        }
        var turns = script.turns(at: clock)
        for index in turns.indices { turns[index].isOpen = false }
        onUpdate(CaptionerUpdate(turns: turns, status: status, audio: [], isFinal: true))
    }
}

/// Silence at a steady pace, for driving ``ReplayEngine``: 100 ms chunks, `speed` times faster than
/// real time, until stopped or `limitSeconds` of audio have gone by.
public final class ClockAudioSource: LiveAudioSource, @unchecked Sendable {
    private let speed: Double
    private let limitSeconds: Double?
    private let lock = NSLock()
    private var producer: Task<Void, Never>?

    public init(speed: Double = 1, limitSeconds: Double? = nil) {
        self.speed = max(0.1, speed)
        self.limitSeconds = limitSeconds
    }

    public func stream() async throws -> AsyncThrowingStream<[Float], Error> {
        let speed = self.speed
        let limit = limitSeconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                var sent = 0.0
                while !Task.isCancelled {
                    if let limit, sent >= limit { break }
                    continuation.yield([Float](repeating: 0, count: 1_600))
                    sent += 0.1
                    try? await Task.sleep(nanoseconds: UInt64(0.1 / speed * 1e9))
                }
                continuation.finish()
            }
            lock.withLock { producer = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() async {
        lock.withLock { producer }?.cancel()
    }

    public func origin() -> AudioOrigin {
        AudioOrigin(kind: .file, name: "replay")
    }
}
