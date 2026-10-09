import Foundation

/// Everything measured about one transcription.
///
/// The three measurement families answer different questions and are reported side by side on
/// purpose. Word error rate says how much text differs; critical information says whether the
/// differences that matter occurred; latency says whether the result arrives in time to be useful.
/// A model can win on one and lose on another, and only the combination supports a decision.
public struct TranscriptEvaluation: Codable, Sendable {

    public struct AlignmentCounts: Codable, Sendable {
        public let correct: Int
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        public let referenceWords: Int
    }

    public let fixture: String
    public let hypothesis: String
    public let reference: String?

    /// Word error rate on punctuation-stripped text, the conventional measure.
    public let wordErrorRate: Double?
    /// The same, with spelled-out numbers folded to digits, so "fifteen" and "15" agree.
    /// The gap between this and ``wordErrorRate`` is the recognizer's number-formatting noise.
    public let semanticWordErrorRate: Double?
    public let alignment: AlignmentCounts?

    public let criticalInfo: CriticalInfoReport?
    public let latency: LatencyReport
    public let decodingFallbacks: Int
    public let turns: [CaptionTurn]

    public init(
        fixture: String,
        hypothesis: String,
        reference: String?,
        wordErrorRate: Double?,
        semanticWordErrorRate: Double?,
        alignment: AlignmentCounts?,
        criticalInfo: CriticalInfoReport?,
        latency: LatencyReport,
        decodingFallbacks: Int,
        turns: [CaptionTurn]
    ) {
        self.fixture = fixture
        self.hypothesis = hypothesis
        self.reference = reference
        self.wordErrorRate = wordErrorRate
        self.semanticWordErrorRate = semanticWordErrorRate
        self.alignment = alignment
        self.criticalInfo = criticalInfo
        self.latency = latency
        self.decodingFallbacks = decodingFallbacks
        self.turns = turns
    }
}

/// Scores one transcription against its reference.
public struct TranscriptEvaluator: Sendable {

    /// Names to score strictly, on top of heuristically detected proper nouns.
    public var knownNames: Set<String>
    public var turnSegmenter: TurnSegmenter

    public init(knownNames: Set<String> = [], turnSegmenter: TurnSegmenter = TurnSegmenter()) {
        self.knownNames = knownNames
        self.turnSegmenter = turnSegmenter
    }

    public func evaluate(
        fixtureName: String,
        reference: String?,
        output: EngineOutput
    ) -> TranscriptEvaluation {
        let transcript = output.transcript
        let turns = turnSegmenter.turns(from: transcript)

        guard let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TranscriptEvaluation(
                fixture: fixtureName,
                hypothesis: transcript.text,
                reference: nil,
                wordErrorRate: nil,
                semanticWordErrorRate: nil,
                alignment: nil,
                criticalInfo: nil,
                latency: output.latency,
                decodingFallbacks: output.decodingFallbacks,
                turns: turns
            )
        }

        let surface = WordAligner.align(
            reference: TextNormalizer.surfaceTokens(reference),
            hypothesis: TextNormalizer.surfaceTokens(transcript.text)
        )
        let semantic = WordAligner.align(
            reference: TextNormalizer.semanticTokens(reference),
            hypothesis: TextNormalizer.semanticTokens(transcript.text)
        )
        let scorer = CriticalInfoScorer(knownNames: knownNames)

        return TranscriptEvaluation(
            fixture: fixtureName,
            hypothesis: transcript.text,
            reference: reference,
            wordErrorRate: surface.wordErrorRate,
            semanticWordErrorRate: semantic.wordErrorRate,
            alignment: TranscriptEvaluation.AlignmentCounts(
                correct: surface.correct,
                substitutions: surface.substitutions,
                deletions: surface.deletions,
                insertions: surface.insertions,
                referenceWords: surface.referenceCount
            ),
            criticalInfo: scorer.score(reference: reference, hypothesis: transcript.text),
            latency: output.latency,
            decodingFallbacks: output.decodingFallbacks,
            turns: turns
        )
    }
}

/// Aggregate across a fixture run.
public struct EvaluationSummary: Codable, Sendable {
    public let fixtureCount: Int
    /// Mean word error rate over fixtures that had a reference. Corpus-level WER would weight long
    /// recordings more heavily; the mean is reported because each fixture is a distinct scenario
    /// worth equal attention.
    public let meanWordErrorRate: Double?
    public let meanSemanticWordErrorRate: Double?
    public let meanCriticalInfoScore: Double?
    public let totalSevereMisses: Int
    public let meanRealTimeFactor: Double
    public let worstRealTimeFactor: Double
    public let totalDecodingFallbacks: Int

    public init(evaluations: [TranscriptEvaluation]) {
        fixtureCount = evaluations.count

        let wordErrorRates = evaluations.compactMap(\.wordErrorRate)
        meanWordErrorRate = wordErrorRates.isEmpty
            ? nil
            : wordErrorRates.reduce(0, +) / Double(wordErrorRates.count)

        let semanticErrorRates = evaluations.compactMap(\.semanticWordErrorRate)
        meanSemanticWordErrorRate = semanticErrorRates.isEmpty
            ? nil
            : semanticErrorRates.reduce(0, +) / Double(semanticErrorRates.count)

        let criticalScores = evaluations.compactMap { $0.criticalInfo?.score }
        meanCriticalInfoScore = criticalScores.isEmpty
            ? nil
            : criticalScores.reduce(0, +) / Double(criticalScores.count)

        totalSevereMisses = evaluations.reduce(0) { $0 + ($1.criticalInfo?.severeMissCount ?? 0) }

        let realTimeFactors = evaluations.map(\.latency.realTimeFactor)
        meanRealTimeFactor = realTimeFactors.isEmpty
            ? 0
            : realTimeFactors.reduce(0, +) / Double(realTimeFactors.count)
        worstRealTimeFactor = realTimeFactors.max() ?? 0

        totalDecodingFallbacks = evaluations.reduce(0) { $0 + $1.decodingFallbacks }
    }
}
