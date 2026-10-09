import CoreML
import Foundation
import WhisperKit

/// Configuration for the WhisperKit-backed recognizer.
public struct WhisperEngineConfiguration: Sendable {

    /// WhisperKit model identifier. Note the spelling: WhisperKit uses an underscore before the
    /// variant suffix, so it is `openai_whisper-large-v3_turbo`, not `openai_whisper-large-v3-turbo`.
    /// The `_954MB` suffix selects the quantized build of the same model.
    public var model: String

    /// Where downloaded models are cached. Kept inside the project so the cache is easy to find
    /// and delete; a Hugging Face download of roughly 1.5 GB happens on first use.
    public var downloadBase: URL?

    /// An already-downloaded model directory. When set, nothing is downloaded.
    public var modelFolder: String?

    public var modelRepo: String?

    /// Fixes the language instead of letting the model detect it. Pinning avoids a misdetection on
    /// short or noisy clips silently translating the output.
    public var language: String?

    /// Word-level timings. Required for turn segmentation by speech gap.
    public var wordTimestamps: Bool

    /// Route chunking through voice activity detection, which skips silent stretches rather than
    /// decoding them.
    public var useVAD: Bool

    public var prewarm: Bool

    /// Force the decoder's language and task tokens on every window. Leaving this on pins English,
    /// which is wanted; the question is whether it also lets one bad window condition the next.
    public var usePrefillPrompt: Bool

    /// How many times a decode may be retried at a higher temperature when it fails WhisperKit's
    /// quality checks. WhisperKit's default is 5, and this keeps it.
    ///
    /// Tempting to set to 0 for live capture, since each retry is a whole extra decode — measured at
    /// 16.5 s per decode against 2.6 s with no retries. **Do not.** With no retry, a window that
    /// fails the check goes to `SegmentSeeker`, which judges it silent and advances the seek by a
    /// full 30 seconds, discarding the audio rather than transcribing it. Measured on a 46.7 s
    /// fixture: retries off, 22 of 26 decodes returned zero words and the last 21 seconds of the
    /// conversation vanished from the transcript.
    ///
    /// Retries are necessary but not sufficient, and the second half is easy to miss.
    /// `TranscribeTask` tries temperatures `0...temperatureFallbackCount` and then returns whatever
    /// the *last* attempt produced, failed or not — nothing is raised. So a window the decoder
    /// cannot handle at any temperature still comes back as a result, and it is the worst one. The
    /// live loop therefore treats "no new words over audio that had speech in it" as a failure it
    /// must recover from rather than a fact to accept; see ``LiveTranscriber``.
    public var temperatureFallbackCount: Int

    public init(
        model: String = "openai_whisper-large-v3_turbo",
        downloadBase: URL? = nil,
        modelFolder: String? = nil,
        modelRepo: String? = nil,
        language: String? = "en",
        wordTimestamps: Bool = true,
        useVAD: Bool = false,
        prewarm: Bool = true,
        usePrefillPrompt: Bool = true,
        temperatureFallbackCount: Int = 5
    ) {
        self.model = model
        self.downloadBase = downloadBase
        self.modelFolder = modelFolder
        self.modelRepo = modelRepo
        self.language = language
        self.wordTimestamps = wordTimestamps
        self.useVAD = useVAD
        self.prewarm = prewarm
        self.usePrefillPrompt = usePrefillPrompt
        self.temperatureFallbackCount = temperatureFallbackCount
    }
}

/// A transcription plus the measurements taken while producing it.
public struct EngineOutput: Sendable {
    public let transcript: Transcript
    public let latency: LatencyReport
    /// How many times decoding fell back to a higher temperature. A rising count is an early
    /// warning that audio conditions are defeating the model.
    public let decodingFallbacks: Int

    public init(transcript: Transcript, latency: LatencyReport, decodingFallbacks: Int) {
        self.transcript = transcript
        self.latency = latency
        self.decodingFallbacks = decodingFallbacks
    }
}

/// Runs WhisperKit on the Neural Engine.
///
/// An actor so the loaded model — which is large and not safe to drive from two places at once —
/// is serialized behind a single owner.
public actor WhisperEngine {

    private let configuration: WhisperEngineConfiguration
    private var whisperKit: WhisperKit?

    public init(configuration: WhisperEngineConfiguration = WhisperEngineConfiguration()) {
        self.configuration = configuration
    }

    /// Loads (downloading if necessary) and prewarms the model. Separated from ``init`` so the
    /// caller controls when the expensive one-time cost is paid, and can report progress.
    public func load() async throws {
        guard whisperKit == nil else { return }

        // `let`, not `var`: WhisperKitConfig is a class, so assigning to its properties mutates the
        // referenced object rather than the binding.
        let config = WhisperKitConfig(
            model: configuration.model,
            downloadBase: configuration.downloadBase,
            modelRepo: configuration.modelRepo,
            modelFolder: configuration.modelFolder,
            verbose: false,
            prewarm: configuration.prewarm,
            load: true,
            download: true
        )
        if configuration.useVAD {
            config.voiceActivityDetector = EnergyVAD()
        }

        whisperKit = try await WhisperKit(config)
    }

    public func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    /// Pays the one-time costs — model load, Neural Engine specialization, first decode — before
    /// anything is measured, and returns how long they took.
    ///
    /// WhisperKit compiles decode paths lazily, so the first transcription after a load is several
    /// times slower than every one after it. Left alone that cost lands entirely inside whichever
    /// fixture runs first and is reported as *that fixture's* time-to-first-word, which reads as a
    /// property of the fixture rather than of the process. First measured run showed exactly this:
    /// 7071 ms for doctor-visit against ~1900 ms for the four fixtures behind it.
    ///
    /// Both cheap substitutes were measured and both are wrong. A *silent* buffer is short-circuited
    /// before the decoder runs, so it leaves the expensive path cold — the first fixture still cost
    /// 5.7 s against 2.0 s for the rest. *Noise* does force a real decode, and it fixes the outlier,
    /// but it costs 25.6 s: with nothing speech-like to lock onto the decoder hallucinates a full
    /// window of tokens, then pays word-level alignment over every one of them.
    ///
    /// So the caller passes real audio. Only the opening ``seconds`` of it: the cost being paid here
    /// is CoreML specializing its graphs, which happens once per process and does not depend on how
    /// much audio follows. Decoding the whole file would repeat work the run is about to do anyway —
    /// measured at 26.7 s on a 46 s fixture, against a few seconds for a short slice.
    ///
    /// The returned interval is dominated by the model load, which is the part the app pays on
    /// launch, so it is reported rather than discarded.
    @discardableResult
    public func warmUp(audioPath: String, seconds duration: Double = 3) async throws -> Double {
        let start = DispatchTime.now()
        try await load()

        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        let count = min(samples.count, Int(Double(WhisperKit.sampleRate) * duration))
        _ = try? await transcribe(samples: Array(samples[0..<count]))

        return seconds(from: start, to: DispatchTime.now())
    }

    /// Transcribes an audio file. WhisperKit decodes and resamples it to 16 kHz mono.
    public func transcribe(audioPath: String) async throws -> EngineOutput {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        return try await transcribe(samples: samples)
    }

    /// Transcribes raw 16 kHz mono samples.
    public func transcribe(samples: [Float]) async throws -> EngineOutput {
        try await load()
        guard let whisperKit else {
            throw CaptionError.engineUnavailable
        }

        let duration = Double(samples.count) / Double(WhisperKit.sampleRate)
        let start = DispatchTime.now()
        // The progress callback is @Sendable and WhisperKit may invoke it from a decode worker, so
        // the timestamp is recorded through a lock rather than a captured var.
        let firstWord = FirstWordRecorder(start: start)

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions(),
            callback: { progress in
                if !progress.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    firstWord.recordIfAbsent()
                }
                return true
            },
            segmentCallback: nil
        )

        let end = DispatchTime.now()
        let total = seconds(from: start, to: end)
        let timeToFirstWord = firstWord.secondsFromStart ?? total

        let transcript = Self.map(results)
        let timings = results.last?.timings

        return EngineOutput(
            transcript: transcript,
            latency: LatencyReport(
                timeToFirstWord: timeToFirstWord,
                totalTime: total,
                audioDuration: duration,
                realTimeFactor: duration > 0 ? total / duration : 0,
                recognizerPipelineTime: timings.map(\.fullPipeline),
                recognizerFirstTokenTime: Self.firstTokenTime(from: timings)
            ),
            decodingFallbacks: Int(timings?.totalDecodingFallbacks ?? 0)
        )
    }

    // MARK: - Internals

    private func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: configuration.language,
            temperatureFallbackCount: configuration.temperatureFallbackCount,
            usePrefillPrompt: configuration.usePrefillPrompt,
            detectLanguage: configuration.language == nil,
            skipSpecialTokens: true,
            wordTimestamps: configuration.wordTimestamps,
            // WhisperKit defaults to 16 concurrent decode workers on macOS. That is right for bulk
            // throughput and wrong for measuring latency, because the reported time then reflects
            // many windows decoded in parallel rather than the wait a live user would experience.
            concurrentWorkerCount: 1,
            chunkingStrategy: configuration.useVAD ? .vad : nil
        )
    }

    private static func map(_ results: [TranscriptionResult]) -> Transcript {
        let segments = results.flatMap(\.segments).map { segment in
            CaptionSegment(
                text: segment.text.trimmingCharacters(in: .whitespaces),
                start: segment.start,
                end: segment.end,
                words: (segment.words ?? []).map {
                    CaptionWord(
                        text: $0.word,
                        start: $0.start,
                        end: $0.end,
                        probability: $0.probability
                    )
                }
            )
        }
        return Transcript(
            text: results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            language: results.first?.language
        )
    }

    private func seconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// WhisperKit seeds both timestamps to `greatestFiniteMagnitude` when a pipeline has not run,
    /// so an unguarded subtraction yields a nonsensical number rather than zero.
    private static func firstTokenTime(from timings: TranscriptionTimings?) -> Double? {
        guard let timings else { return nil }
        let start = timings.pipelineStart
        let first = timings.firstTokenTime
        guard start.isFinite, first.isFinite, first >= start else { return nil }
        return first - start
    }
}

/// Records the first moment non-empty text appeared, from a callback that may run on any thread.
final class FirstWordRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let start: DispatchTime
    private var first: DispatchTime?

    init(start: DispatchTime) {
        self.start = start
    }

    func recordIfAbsent() {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = DispatchTime.now() }
    }

    var secondsFromStart: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let first else { return nil }
        return Double(first.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}

public enum CaptionError: Error, CustomStringConvertible {
    case engineUnavailable
    case missingFixture(String)
    case missingReference(String)

    public var description: String {
        switch self {
        case .engineUnavailable:
            return "The speech recognizer is not loaded."
        case .missingFixture(let name):
            return "No fixture named '\(name)'."
        case .missingReference(let name):
            return "No reference transcript found for '\(name)'."
        }
    }
}
