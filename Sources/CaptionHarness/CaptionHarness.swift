import ArgumentParser
import CaptionKit
import Foundation

@main
struct CaptionHarness: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "caption-harness",
        abstract: "Measures the live-caption ASR pipeline against recorded fixtures.",
        discussion: """
        Fixtures live under Fixtures/ as audio/<name>.wav with an optional \
        reference/<name>.txt and metadata/<name>.json.
        """,
        subcommands: [List.self, Transcribe.self, Evaluate.self, Report.self]
    )
}

// MARK: - Shared options

struct FixtureOptions: ParsableArguments {
    @Option(name: .long, help: "Directory containing Fixtures/audio, reference, and metadata.")
    var fixtures: String?

    func resolveRoot() throws -> URL {
        guard let root = FixtureLibrary.locate(explicit: fixtures) else {
            throw ValidationError(
                """
                Could not find a Fixtures/ directory. Create one with an audio/ subdirectory, \
                or pass --fixtures <path>.
                """
            )
        }
        return root
    }
}

struct ModelOptions: ParsableArguments {
    @Option(name: .long, help: "WhisperKit model identifier. Defaults to large-v3-turbo.")
    var model: String = "openai_whisper-large-v3_turbo"

    @Option(name: .long, help: "Directory that downloaded models are cached in.")
    var modelCache: String?

    @Option(name: .long, help: "Use an already-downloaded model directory instead of downloading.")
    var modelFolder: String?

    @Flag(name: .long, help: "Let the model detect the language instead of pinning English.")
    var autoLanguage: Bool = false

    @Flag(name: .long, help: "Skip prewarming the model, so its cost lands in the first result.")
    var noPrewarm: Bool = false

    @Flag(
        name: .long,
        help: """
        Route chunking through voice activity detection. WhisperKit ships an energy-based \
        detector, not the Silero model the design called for, so treat this as a comparison \
        rather than a settled choice.
        """
    )
    var vad: Bool = false

    @Flag(
        name: .long,
        help: """
        Stop forcing the decoder's language and task tokens on every window. Tests whether a window \
        that drifts onto background speech is conditioning the windows after it to continue.
        """
    )
    var noPrefill: Bool = false

    func configuration() -> WhisperEngineConfiguration {
        WhisperEngineConfiguration(
            model: model,
            downloadBase: modelCache.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            modelFolder: modelFolder,
            language: autoLanguage ? nil : "en",
            wordTimestamps: true,
            useVAD: vad,
            prewarm: !noPrewarm,
            usePrefillPrompt: !noPrefill
        )
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists the fixtures that are available to test against."
    )

    @OptionGroup var fixtureOptions: FixtureOptions

    func run() throws {
        let library = FixtureLibrary(root: try fixtureOptions.resolveRoot())
        let fixtures = try library.fixtures()

        guard !fixtures.isEmpty else {
            print("No audio files found in \(library.audioDirectory.path)")
            return
        }

        print("\(fixtures.count) fixture(s) in \(library.root.path)\n")
        for fixture in fixtures {
            let reference = fixture.reference == nil ? "no reference" : "reference"
            let metadata = fixture.metadata
            let scene = metadata?.scene.map { " — \($0)" } ?? ""
            let speakers = metadata?.speakerCount.map { ", \($0) speakers" } ?? ""
            let noise = metadata?.noise.map { ", noise: \($0)" } ?? ""
            print("  \(fixture.name)  [\(reference)\(speakers)\(noise)]\(scene)")
        }
    }
}

// MARK: - transcribe

// AsyncParsableCommand, not ParsableCommand: an `async run()` does not satisfy the synchronous
// `run()` requirement, and the protocol's default implementation silently prints help instead.
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribes one audio file and prints the result with timestamps."
    )

    @Argument(help: "Path to an audio file.")
    var audio: String

    @OptionGroup var modelOptions: ModelOptions

    @Flag(name: .long, help: "Print the transcript as JSON.")
    var json: Bool = false

    func run() async throws {
        let url = URL(fileURLWithPath: (audio as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No file at \(url.path)")
        }

        let engine = WhisperEngine(configuration: modelOptions.configuration())
        FileHandle.standardError.write(Data("Loading model…\n".utf8))
        let output = try await engine.transcribe(audioPath: url.path)
        await engine.unload()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = TranscriptionOutput(
                audio: url.lastPathComponent,
                transcript: output.transcript,
                latency: output.latency,
                decodingFallbacks: output.decodingFallbacks
            )
            print(String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}")
            return
        }

        for segment in output.transcript.segments {
            print("[\(format(segment.start)) → \(format(segment.end))] \(segment.text)")
        }
        print("")
        print(output.transcript.text)
        print("")
        ConsoleReport.latency(output.latency)
    }
}

// MARK: - Shared fixture selection and running

/// Which fixtures to run. Shared by `evaluate` and `report` so the two cannot drift apart.
struct SelectionOptions: ParsableArguments {
    @Argument(help: "Fixture names, or paths to audio files. Omit for every fixture.")
    var names: [String] = []

    @Flag(name: .long, help: "Run every fixture in the library. The default when no name is given.")
    var all: Bool = false
}

struct TestCase {
    let fixture: AudioFixture
}

func resolveCases(_ selection: SelectionOptions, _ fixtureOptions: FixtureOptions) throws -> [TestCase] {
    // Bare `evaluate` means the whole library, which is what `make test` relies on.
    if selection.all || selection.names.isEmpty {
        let library = FixtureLibrary(root: try fixtureOptions.resolveRoot())
        return try library.fixtures().map(TestCase.init)
    }

    let library = FixtureLibrary(root: try fixtureOptions.resolveRoot())
    return try selection.names.map { name in
        // A path to an audio file is scored directly against a sibling .txt of the same name.
        if name.contains("/") || FixtureLibrary.audioExtensions.contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        ) {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("No file at \(url.path)")
            }
            return TestCase(fixture: FixtureLibrary.single(audioURL: url))
        }
        return TestCase(fixture: try library.fixture(named: name))
    }
}

/// Transcribes and scores each case in order. Progress goes to stderr so stdout stays clean for
/// piping.
func runCases(
    _ cases: [TestCase],
    engine: WhisperEngine,
    onEvaluation: (TranscriptEvaluation) -> Void = { _ in }
) async throws -> [TranscriptEvaluation] {
    // Pay the cold-start cost before the first fixture is timed, so no fixture inherits it. The
    // first fixture's own audio is the warm-up signal — a few seconds of real speech, which is the
    // only thing that reliably exercises the decode path. See WhisperEngine.warmUp.
    if let first = cases.first {
        let coldStart = try await engine.warmUp(audioPath: first.fixture.audioURL.path)
        if coldStart > 0.05 {
            FileHandle.standardError.write(
                Data(String(format: "Cold start (model load + warm-up decode): %.1fs\n", coldStart).utf8)
            )
        }
    }

    var evaluations: [TranscriptEvaluation] = []
    for testCase in cases {
        FileHandle.standardError.write(Data("Transcribing \(testCase.fixture.name)…\n".utf8))
        let output = try await engine.transcribe(audioPath: testCase.fixture.audioURL.path)
        let evaluator = TranscriptEvaluator(
            knownNames: Set(testCase.fixture.metadata?.knownNames ?? []),
            turnSegmenter: TurnSegmenter(silenceGap: 0.8)
        )
        let evaluation = evaluator.evaluate(
            fixtureName: testCase.fixture.name,
            reference: testCase.fixture.reference,
            output: output
        )
        evaluations.append(evaluation)
        onEvaluation(evaluation)
    }
    return evaluations
}

// MARK: - evaluate

struct Evaluate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scores transcriptions against reference text: WER, critical information, latency."
    )

    @OptionGroup var selection: SelectionOptions
    @OptionGroup var fixtureOptions: FixtureOptions
    @OptionGroup var modelOptions: ModelOptions

    @Flag(name: .long, help: "Emit the full evaluation as JSON on stdout.")
    var json: Bool = false

    @Option(name: .long, help: "Write the JSON evaluation to this file.")
    var output: String?

    @Flag(name: .long, help: "Print each turn as a separate block, as the app would display it.")
    var turns: Bool = false

    func run() async throws {
        let cases = try resolveCases(selection, fixtureOptions)
        guard !cases.isEmpty else {
            throw ValidationError("No fixtures to evaluate. Add audio under Fixtures/audio/.")
        }

        let engine = WhisperEngine(configuration: modelOptions.configuration())
        let evaluations = try await runCases(cases, engine: engine) { evaluation in
            if !json { ConsoleReport.evaluation(evaluation, showTurns: turns) }
        }
        await engine.unload()

        if !json, evaluations.count > 1 {
            ConsoleReport.summary(EvaluationSummary(evaluations: evaluations))
        }

        if json || output != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = EvaluationPayload(
                summary: EvaluationSummary(evaluations: evaluations),
                evaluations: evaluations
            )
            let data = try encoder.encode(payload)
            if let output {
                let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
                try data.write(to: url)
                FileHandle.standardError.write(Data("Wrote \(url.path)\n".utf8))
            }
            if json, let text = String(data: data, encoding: .utf8) { print(text) }
        }
    }

}

// MARK: - report

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Runs the fixtures and writes the markdown report that drives the next iteration."
    )

    @OptionGroup var selection: SelectionOptions
    @OptionGroup var fixtureOptions: FixtureOptions
    @OptionGroup var modelOptions: ModelOptions

    @Option(name: .long, help: "Write the report to this file. Defaults to stdout.")
    var output: String?

    func run() async throws {
        let cases = try resolveCases(selection, fixtureOptions)
        guard !cases.isEmpty else {
            throw ValidationError("No fixtures to run. Add audio under Fixtures/audio/.")
        }

        // Sampled before any work, so the harness's own CPU use is not counted as contention.
        let conditions = MeasurementConditions.current()

        let engine = WhisperEngine(configuration: modelOptions.configuration())
        let evaluations = try await runCases(cases, engine: engine)
        await engine.unload()

        let names = cases.map(\.fixture.name)
        let invocation = "caption-harness report "
            + (names.count > 6 ? "--all" : names.joined(separator: " "))
            + " --model \(modelOptions.model)"

        let markdown = TestReport(
            evaluations: evaluations,
            command: invocation,
            model: modelOptions.model,
            conditions: conditions
        ).markdown()

        if let output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Wrote \(url.path)\n".utf8))
        } else {
            print(markdown)
        }
    }
}

// MARK: - Output payloads and rendering

private struct TranscriptionOutput: Codable {
    let audio: String
    let transcript: Transcript
    let latency: LatencyReport
    let decodingFallbacks: Int
}

private struct EvaluationPayload: Codable {
    let summary: EvaluationSummary
    let evaluations: [TranscriptEvaluation]
}

func format(_ seconds: Float) -> String {
    String(format: "%6.2fs", seconds)
}

enum ConsoleReport {

    static func latency(_ latency: LatencyReport) {
        print("Latency")
        print("  time to first word   \(milliseconds(latency.timeToFirstWord))")
        print("  total                \(milliseconds(latency.totalTime))")
        print("  audio duration       \(String(format: "%.2fs", latency.audioDuration))")
        print("  real-time factor     \(String(format: "%.3f", latency.realTimeFactor))"
            + (latency.realTimeFactor < 1 ? "  (keeps up with live speech)" : "  (slower than live speech)"))
        if let pipeline = latency.recognizerPipelineTime {
            print("  model pipeline       \(milliseconds(pipeline))")
        }
        if let firstToken = latency.recognizerFirstTokenTime {
            print("  model first token    \(milliseconds(firstToken))")
        }
    }

    static func evaluation(_ evaluation: TranscriptEvaluation, showTurns: Bool) {
        print("")
        print(String(repeating: "─", count: 72))
        print("Fixture: \(evaluation.fixture)")
        print(String(repeating: "─", count: 72))

        if let reference = evaluation.reference {
            print("\nReference\n  \(reference)")
        }
        print("\nTranscript\n  \(evaluation.hypothesis)")

        if let wordErrorRate = evaluation.wordErrorRate,
           let semantic = evaluation.semanticWordErrorRate,
           let alignment = evaluation.alignment {
            print("\nAccuracy")
            print("  word error rate      \(percent(wordErrorRate))"
                + "   (\(alignment.substitutions) substitutions, \(alignment.deletions) deletions,"
                + " \(alignment.insertions) insertions over \(alignment.referenceWords) words)")
            print("  semantic WER         \(percent(semantic))")
        } else {
            print("\nAccuracy\n  no reference transcript — scoring skipped")
        }

        if let critical = evaluation.criticalInfo {
            print("\nCritical information   \(percent(critical.score))")
            print("  names                \(tally(critical.categories.name))")
            print("  numbers              \(tally(critical.categories.number))")
            print("  negations            \(tally(critical.categories.negation))")

            if critical.misses.isEmpty {
                print("  no critical words were lost")
            } else {
                print("\n  Failures:")
                for miss in critical.misses.sorted(by: { $0.severity > $1.severity }) {
                    print("    [\(miss.severity.rawValue.uppercased())] \(describe(miss))")
                    print("        …\(miss.context)…")
                }
            }
        }

        print("")
        ConsoleReport.latency(evaluation.latency)
        if evaluation.decodingFallbacks > 0 {
            print("  decode fallbacks     \(evaluation.decodingFallbacks)"
                + "  (higher temperatures were needed)")
        }

        if showTurns, !evaluation.turns.isEmpty {
            print("\nTurns (\(evaluation.turns.count) blocks, split on silences over 800ms)")
            for turn in evaluation.turns {
                print("  [\(format(turn.start)) → \(format(turn.end))] \(turn.text)")
            }
        }
    }

    static func summary(_ summary: EvaluationSummary) {
        print("")
        print(String(repeating: "═", count: 72))
        print("Summary across \(summary.fixtureCount) fixture(s)")
        print(String(repeating: "═", count: 72))
        if let mean = summary.meanWordErrorRate {
            print("  mean word error rate      \(percent(mean))")
        }
        if let mean = summary.meanSemanticWordErrorRate {
            print("  mean semantic WER         \(percent(mean))")
        }
        if let mean = summary.meanCriticalInfoScore {
            print("  mean critical information \(percent(mean))")
        }
        print("  severe critical misses    \(summary.totalSevereMisses)")
        print("  mean real-time factor     \(String(format: "%.3f", summary.meanRealTimeFactor))")
        print("  worst real-time factor    \(String(format: "%.3f", summary.worstRealTimeFactor))")
        print("  decode fallbacks          \(summary.totalDecodingFallbacks)")
    }

    // MARK: - Formatting helpers

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%7.0f ms", seconds * 1000)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%5.1f%%", value * 100)
    }

    private static func tally(_ score: CriticalInfoReport.CategoryScore) -> String {
        let ratio = "\(score.correct)/\(score.total)"
        return "\(ratio.padding(toLength: max(ratio.count, 7), withPad: " ", startingAt: 0))"
            + "  \(percent(score.recall))"
    }

    private static func describe(_ miss: CriticalInfoReport.Miss) -> String {
        switch miss.outcome {
        case .dropped:
            return "\(miss.category.rawValue) '\(miss.spoken ?? "")' was dropped"
        case .changed:
            return "\(miss.category.rawValue) '\(miss.spoken ?? "")' was heard as '\(miss.heardAs ?? "")'"
        case .added:
            return "\(miss.category.rawValue) '\(miss.heardAs ?? "")' was invented and never spoken"
        }
    }
}
