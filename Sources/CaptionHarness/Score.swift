import ArgumentParser
import CaptionKit
import Foundation

/// Scores a transcript that some *other* process produced.
///
/// Every number in docs/RESEARCH.md comes from `evaluate`, which runs WhisperKit and scores what it
/// returns. That is the right shape for measuring our own loop and the wrong shape for comparing
/// engines: a second engine would have to be wired into `CaptionEngine`, built, and kept working
/// before it could produce a single WER figure — and if the answer is "this engine is worse", all
/// that work bought nothing.
///
/// So this reads text instead. Whatever produced it — a different Swift package, a Python
/// reference implementation, a model's own CLI — can be scored by this repo's metrics, against
/// this repo's references, with no integration. The comparison is exact because it is the same
/// `TranscriptEvaluator` and the same `CriticalInfoScorer`; the only thing missing is timing,
/// which the caller supplies if it measured any.
///
/// The missing thing that matters: external text has no word timings, so turn segmentation sees
/// one turn no matter how many speakers there were. `--turns` will therefore always print a single
/// block here. Use `evaluate` when the shape of the turns is the question.
struct Score: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "score",
        abstract: "Scores transcripts produced outside this tool: WER and critical information.",
        discussion: """
        Give the hypothesis either per fixture, with --text and one fixture name, or as a directory \
        of <fixture>.txt files, with --text-dir. Everything is measured exactly as `evaluate` \
        measures it, so the numbers are directly comparable.
        """
    )

    @OptionGroup var selection: SelectionOptions
    @OptionGroup var fixtureOptions: FixtureOptions

    @Option(name: .long, help: "Hypothesis text for the one fixture named in the arguments.")
    var text: String?

    @Option(
        name: .long,
        help: "Directory holding <fixture>.txt hypotheses. Fixtures with no file are skipped."
    )
    var textDir: String?

    @Option(
        name: .long,
        help: """
        Wall-clock seconds the external engine took over the whole selection. Reported as a \
        real-time factor against the total audio duration. Omit when it was not measured — a \
        fabricated zero would read as an impossibly fast engine.
        """
    )
    var elapsed: Double?

    @Flag(name: .long, help: "Emit the full evaluation as JSON on stdout.")
    var json: Bool = false

    @Option(name: .long, help: "Write the JSON evaluation to this file.")
    var output: String?

    @Flag(name: .long, help: "Print each turn as a separate block, as the app would display it.")
    var turns: Bool = false

    func run() async throws {
        guard text != nil || textDir != nil else {
            throw ValidationError("Nothing to score. Pass --text or --text-dir.")
        }
        guard !(text != nil && textDir != nil) else {
            throw ValidationError("Pass --text or --text-dir, not both.")
        }

        let cases = try resolveCases(selection, fixtureOptions)
        guard !cases.isEmpty else {
            throw ValidationError("No fixtures selected. Add audio under Fixtures/audio/.")
        }

        // Pairs of the fixture and the hypothesis text read for it.
        var hypotheses: [(TestCase, String)] = []
        for testCase in cases {
            guard let hypothesis = try readHypothesis(for: testCase.fixture) else {
                FileHandle.standardError.write(
                    Data("No transcript for \(testCase.fixture.name) — skipped\n".utf8)
                )
                continue
            }
            hypotheses.append((testCase, hypothesis))
        }
        guard !hypotheses.isEmpty else {
            throw ValidationError("Found no transcripts to score.")
        }

        let audioSeconds = hypotheses.reduce(0.0) { total, pair in
            total + pair.0.fixture.duration
        }
        let latency = LatencyReport(
            timeToFirstWord: 0,
            totalTime: elapsed ?? 0,
            audioDuration: audioSeconds,
            realTimeFactor: elapsed.map { $0 / max(audioSeconds, 0.001) } ?? 0
        )

        var evaluations: [TranscriptEvaluation] = []
        for (testCase, hypothesis) in hypotheses {
            let evaluator = TranscriptEvaluator(
                knownNames: Set(testCase.fixture.metadata?.knownNames ?? []),
                turnSegmenter: TurnSegmenter(silenceGap: 0.8)
            )
            // Text with no timings: a single segment spanning the fixture, which is all the
            // evidence the evaluator has. It scores WER and critical information on the text, and
            // those do not depend on the segmentation.
            let output = EngineOutput(
                transcript: Transcript(
                    text: hypothesis,
                    segments: [
                        CaptionSegment(
                            text: hypothesis,
                            start: 0,
                            end: Float(testCase.fixture.duration)
                        )
                    ]
                ),
                latency: latency,
                decodingFallbacks: 0
            )
            let evaluation = evaluator.evaluate(
                fixtureName: testCase.fixture.name,
                reference: testCase.fixture.reference,
                output: output
            )
            evaluations.append(evaluation)
            if !json { ConsoleReport.evaluation(evaluation, showTurns: turns) }
        }

        if !json, evaluations.count > 1 {
            ConsoleReport.summary(EvaluationSummary(evaluations: evaluations))
            if let elapsed {
                print(String(
                    format: "\nExternal engine: %.1fs over %.1fs of audio — real-time factor %.2f\n",
                    elapsed, audioSeconds, elapsed / max(audioSeconds, 0.001)
                ))
            }
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
            if json, let encoded = String(data: data, encoding: .utf8) { print(encoded) }
        }
    }

    /// The hypothesis for one fixture, or nil when the caller named a directory that has no file
    /// for it — which is how a partial run stays scorable without pretending the rest was empty.
    private func readHypothesis(for fixture: AudioFixture) throws -> String? {
        if let text {
            return text
        }
        let directory = URL(
            fileURLWithPath: (textDir! as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let url = directory.appendingPathComponent("\(fixture.name).txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
