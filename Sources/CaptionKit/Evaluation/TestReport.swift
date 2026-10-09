import Foundation

/// Renders a run of evaluations as the markdown report that drives the next iteration.
///
/// The report is written for a human deciding what to change next, so it leads with the table,
/// then the specific failures, then what to do about them. The recommendations are derived from
/// the measurements rather than fixed text, so the report stays honest when the numbers move —
/// a recommendation appears only when something in the run justifies it.
///
/// Lives in CaptionKit rather than the CLI so the derivation is unit-testable without loading a
/// model, which is the same reason `Metrics/` has no WhisperKit dependency.
/// How busy the machine was when a run started.
///
/// Accuracy is not affected by contention — decoding the same audio twice gives the same words —
/// but latency is, and a run that shares the machine reports inflated timings that read as a
/// regression in the model rather than as a busy laptop. Measured: with another build running,
/// doctor-visit's real-time factor went 0.371 → 0.524 on identical audio.
public struct MeasurementConditions: Sendable {

    /// The 1-minute load average, sampled *before* the run so the run's own CPU use is not counted
    /// against it.
    public var loadAverage: Double

    public var processorCount: Int

    public init(loadAverage: Double, processorCount: Int) {
        self.loadAverage = loadAverage
        self.processorCount = processorCount
    }

    /// Sampled now. CoreML contention does not only come from CPU work — a busy Metal compiler
    /// shows up here too, and that is the contention that hurts a Neural Engine decode most.
    public static func current() -> MeasurementConditions {
        var loads = [Double](repeating: 0, count: 3)
        let sampled = getloadavg(&loads, 3)
        return MeasurementConditions(
            loadAverage: sampled > 0 ? loads[0] : 0,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    /// Deliberately eager. A false positive costs a re-run; a false negative means acting on a
    /// latency figure that only reflects what else the machine was doing.
    public var isContended: Bool {
        processorCount > 0 && loadAverage > Double(processorCount) * 0.5
    }
}

public struct TestReport: Sendable {

    public var evaluations: [TranscriptEvaluation]
    public var generatedAt: Date
    /// The command that produced the run, echoed into the report so a result can be reproduced.
    public var command: String?
    /// The model identifier, for the same reason.
    public var model: String?
    /// What else the machine was doing. Nil when the caller did not measure it.
    public var conditions: MeasurementConditions?

    public init(
        evaluations: [TranscriptEvaluation],
        generatedAt: Date = Date(),
        command: String? = nil,
        model: String? = nil,
        conditions: MeasurementConditions? = nil
    ) {
        self.evaluations = evaluations
        self.generatedAt = generatedAt
        self.command = command
        self.model = model
        self.conditions = conditions
    }

    public var summary: EvaluationSummary { EvaluationSummary(evaluations: evaluations) }

    // MARK: - Rendering

    public func markdown() -> String {
        var lines: [String] = []

        lines.append("# Test Report — \(Self.timestamp(generatedAt))")
        lines.append("")
        if let model {
            lines.append("Model: `\(model)`")
            lines.append("")
        }
        if let command {
            lines.append("```")
            lines.append(command)
            lines.append("```")
            lines.append("")
        }
        appendConditions(to: &lines)

        appendSummary(to: &lines)
        appendFailures(to: &lines)
        appendRecommendations(to: &lines)

        return lines.joined(separator: "\n")
    }

    /// Sits above the table, not below it: a reader who takes the timings at face value has already
    /// drawn the wrong conclusion by the time they reach a footnote.
    private func appendConditions(to lines: inout [String]) {
        guard let conditions, conditions.isContended else { return }
        lines.append("> **Timing measured under load.** Load average "
            + "\(Self.decimal(conditions.loadAverage)) on \(conditions.processorCount) cores when the "
            + "run started. WER and critical information score are unaffected — the same audio decodes "
            + "to the same words — but TTFT and RTF are inflated. Re-run on an idle machine before "
            + "comparing these timings with another run.")
        lines.append("")
    }

    private func appendSummary(to lines: inout [String]) {
        let summary = summary
        lines.append("## Summary")
        lines.append("")
        lines.append("| Fixture | WER | Critical Info Score | TTFT (ms) | RTF |")
        lines.append("|---|---|---|---|---|")
        for evaluation in evaluations {
            lines.append("| \(evaluation.fixture) "
                + "| \(Self.percent(evaluation.wordErrorRate)) "
                + "| \(Self.percent(evaluation.criticalInfo?.score)) "
                + "| \(Self.milliseconds(evaluation.latency.timeToFirstWord)) "
                + "| \(Self.decimal(evaluation.latency.realTimeFactor)) |")
        }
        if evaluations.count > 1 {
            lines.append("| **mean** "
                + "| **\(Self.percent(summary.meanWordErrorRate))** "
                + "| **\(Self.percent(summary.meanCriticalInfoScore))** "
                + "| | **\(Self.decimal(summary.meanRealTimeFactor))** |")
        }
        lines.append("")

        // The summary table is the brief's format. This is the same run with the columns that
        // explain *why* a row looks the way it does.
        lines.append("### Detail")
        lines.append("")
        lines.append("| Fixture | Semantic WER | Names | Numbers | Negations | Severe | Turns | Decode fallbacks |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for evaluation in evaluations {
            let critical = evaluation.criticalInfo
            lines.append("| \(evaluation.fixture) "
                + "| \(Self.percent(evaluation.semanticWordErrorRate)) "
                + "| \(Self.tally(critical?.categories.name)) "
                + "| \(Self.tally(critical?.categories.number)) "
                + "| \(Self.tally(critical?.categories.negation)) "
                + "| \(critical?.severeMissCount ?? 0) "
                + "| \(evaluation.turns.count) "
                + "| \(evaluation.decodingFallbacks) |")
        }
        lines.append("")
        lines.append("Semantic WER folds away differences that carry no meaning — digits for spelled "
            + "numbers, abbreviated titles — so the gap against WER is formatting, not comprehension.")
        lines.append("")
    }

    private func appendFailures(to lines: inout [String]) {
        lines.append("## Failures")
        lines.append("")

        var wroteAnything = false
        for evaluation in evaluations {
            guard let critical = evaluation.criticalInfo else {
                lines.append("- **\(evaluation.fixture)**: no reference transcript — accuracy was "
                    + "not scored. Latency and turn segmentation still apply.")
                wroteAnything = true
                continue
            }
            guard !critical.misses.isEmpty else { continue }
            wroteAnything = true

            for miss in critical.misses.sorted(by: { $0.severity > $1.severity }) {
                lines.append("- **\(evaluation.fixture)** — \(Self.describe(miss))")
            }
        }

        if !wroteAnything {
            lines.append("No failures. Every scored word, name, number, and negation was preserved.")
        }
        lines.append("")
    }

    private func appendRecommendations(to lines: inout [String]) {
        lines.append("## Recommendations")
        lines.append("")
        let recommendations = recommendations()
        if recommendations.isEmpty {
            lines.append("- Nothing in this run justifies a change. Add a harder fixture, or move "
                + "on to the next phase.")
        } else {
            for recommendation in recommendations {
                lines.append("- \(recommendation)")
            }
        }
        lines.append("")
    }

    // MARK: - Deriving recommendations

    /// Ordered most-consequential first. Each entry pairs a claim with the measurement behind it.
    func recommendations() -> [String] {
        var found: [String] = []
        let scored = evaluations.filter { $0.criticalInfo != nil }

        // 0. A contended run undermines every timing-derived recommendation below it, so it goes
        //    first and the latency advice further down is explicitly conditional on it.
        if let conditions, conditions.isContended {
            found.append(
                "**Re-measure before acting on any timing** — this run started at load average "
                + "\(Self.decimal(conditions.loadAverage)) on \(conditions.processorCount) cores. "
                + "Accuracy findings hold; the TTFT and RTF columns, and the latency advice derived "
                + "from them, do not."
            )
        }

        // 1. Lost negations. This is the failure the whole scorer exists to catch: the caption
        //    reads fluently and means the opposite of what was said.
        let severe = scored.flatMap { evaluation in
            (evaluation.criticalInfo?.misses ?? [])
                .filter { $0.severity == .severe }
                .map { (evaluation.fixture, $0) }
        }
        let negationFailures = severe.filter { $0.1.category == .negation }
        if !negationFailures.isEmpty {
            let fixtures = Set(negationFailures.map(\.0)).sorted().joined(separator: ", ")
            let examples = negationFailures.prefix(2).map { _, miss -> String in
                if let spoken = miss.spoken, let heard = miss.heardAs {
                    return "'\(spoken)' became '\(heard)'"
                }
                return miss.heardAs.map { "an invented '\($0)'" } ?? "a lost '\(miss.spoken ?? "negation")'"
            }
            found.append(
                "**Fix the negation losses first** — \(negationFailures.count) in \(fixtures) "
                + "(\(examples.joined(separator: "; "))). A flipped negation is the one error that "
                + "makes the caption worse than useless. Confirm whether the words were dropped or "
                + "overwritten by competing speech before tuning anything else."
            )
        }

        // 2. Wrong names, which matter because the user cannot ask who was meant.
        let nameFailures = severe.filter { $0.1.category == .name }
        let allNameMisses = scored.flatMap { ($0.criticalInfo?.misses ?? []).filter { $0.category == .name } }
        if !nameFailures.isEmpty {
            found.append(
                "**Constrain the names that matter** — \(nameFailures.count) wrong name(s) across "
                + "\(Set(nameFailures.map(\.0)).count) fixture(s). Supply them via "
                + "`metadata.json`'s `knownNames` and consider an initial prompt listing family and "
                + "medication names; proper-noun detection can only score names the recognizer "
                + "already capitalized."
            )
        } else if allNameMisses.isEmpty, scored.contains(where: { ($0.criticalInfo?.categories.name.total ?? 0) > 0 }) {
            found.append(
                "Names held on every fixture that contained one. Add a fixture with an unfamiliar "
                + "name — a new doctor, a new medication — since these fixtures largely test names "
                + "already in `knownNames`."
            )
        }

        // 3. Numbers.
        let numberFailures = severe.filter { $0.1.category == .number }
        if !numberFailures.isEmpty {
            found.append(
                "**Check number handling** — \(numberFailures.count) number error(s). Dosages and "
                + "phone numbers are the highest-stakes tokens in the transcript."
            )
        }

        // 4. The noise gap: accuracy is a story about conditions, not about the model.
        let rates = scored.compactMap { evaluation -> (String, Double)? in
            evaluation.wordErrorRate.map { (evaluation.fixture, $0) }
        }
        if let best = rates.min(by: { $0.1 < $1.1 }), let worst = rates.max(by: { $0.1 < $1.1 }),
           worst.1 > max(0.10, best.1 * 4), rates.count > 1 {
            found.append(
                "**Treat the gap as a noise problem, not a model problem** — \(best.0) scores "
                + "\(Self.percent(best.1)) while \(worst.0) scores \(Self.percent(worst.1)) on the "
                + "same model. Preprocessing and voice-activity gating change this; a bigger model "
                + "mostly does not."
            )
        }

        // 5. Latency.
        let worstRTF = evaluations.map(\.latency.realTimeFactor).max() ?? 0
        if worstRTF > 1 {
            found.append(
                "**Decoding is not keeping up** — worst real-time factor \(Self.decimal(worstRTF)). "
                + "The transcript falls further behind the longer someone talks. Try a smaller "
                + "quantized model or shorter chunks before optimizing anything else."
            )
        } else if worstRTF > 0.7 {
            found.append(
                "**Latency headroom is thin** — worst real-time factor \(Self.decimal(worstRTF)) on "
                + "an M-series Mac. An A17 Pro has a smaller Neural Engine and will be slower, so "
                + "measure on device before assuming this holds."
            )
        } else if worstRTF > 0 {
            found.append(
                "Latency has headroom (worst real-time factor \(Self.decimal(worstRTF))), so decode "
                + "speed is not the constraint. Spend the budget on accuracy."
            )
        }

        // 6. Time to first word, and the streaming question the whole app depends on.
        let worstFirstWord = evaluations.map(\.latency.timeToFirstWord).max() ?? 0
        if worstFirstWord > 1.0 {
            found.append(
                "**Measure streaming before trusting the latency figures** — time to first word is "
                + "\(Self.milliseconds(worstFirstWord)) ms, but these runs decode whole files. The "
                + "wait for the first caption under live capture is what the user actually feels, "
                + "and it is not measured here."
            )
        }

        // 7. Falling back to higher temperatures means the decoder is struggling with the audio.
        let fallbacks = evaluations.reduce(0) { $0 + $1.decodingFallbacks }
        if fallbacks > 0 {
            let affected = evaluations.filter { $0.decodingFallbacks > 0 }.map(\.fixture)
            found.append(
                "**Investigate why the decoder is falling back** — \(fallbacks) fallback(s) on "
                + "\(affected.joined(separator: ", ")). Rising temperature means repeated attempts "
                + "failed to produce a confident decode, which usually points at the audio."
            )
        }

        // 8. Turn segmentation, which is the app's only visual structure.
        let expected = evaluations.compactMap { evaluation -> (String, Int)? in
            guard let reference = evaluation.reference else { return nil }
            let lines = reference.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count > 1 else { return nil }
            return (evaluation.fixture, lines.count)
        }
        let mismatched = expected.filter { fixture, count in
            let actual = evaluations.first { $0.fixture == fixture }?.turns.count ?? 0
            return actual != count
        }
        if !mismatched.isEmpty {
            let described = mismatched.map { fixture, count in
                let actual = evaluations.first { $0.fixture == fixture }?.turns.count ?? 0
                return "\(fixture) produced \(actual), expected \(count)"
            }
            found.append(
                "**Review turn segmentation** — \(described.joined(separator: "; ")). Blocks are "
                + "split on silence over 800 ms, so a short count usually means speech filled the "
                + "gaps rather than that the rule failed."
            )
        }

        return found
    }

    // MARK: - Formatting helpers

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.0f", seconds * 1000)
    }

    static func tally(_ score: CriticalInfoReport.CategoryScore?) -> String {
        guard let score else { return "—" }
        return "\(score.correct)/\(score.total)"
    }

    static func describe(_ miss: CriticalInfoReport.Miss) -> String {
        let severity = miss.severity.rawValue.uppercased()
        let category = miss.category.rawValue
        let what: String
        switch (miss.spoken, miss.heardAs) {
        case let (spoken?, heard?):
            what = "\(category) '\(spoken)' was heard as '\(heard)'"
        case let (spoken?, nil):
            what = "\(category) '\(spoken)' was dropped"
        case let (nil, heard?):
            what = "\(category) '\(heard)' was invented — nothing was said there"
        case (nil, nil):
            what = "\(category) failure"
        }
        return "[\(severity)] \(what)"
    }
}
