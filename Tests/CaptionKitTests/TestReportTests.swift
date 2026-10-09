import XCTest

@testable import CaptionKit

final class TestReportTests: XCTestCase {

    // MARK: - Helpers

    private func evaluation(
        _ fixture: String,
        reference: String = "Take the pill at noon.",
        hypothesis: String = "Take the pill at noon.",
        names: [String] = [],
        realTimeFactor: Double = 0.2,
        timeToFirstWord: Double = 0.5
    ) -> TranscriptEvaluation {
        let output = EngineOutput(
            transcript: Transcript(text: hypothesis, segments: []),
            latency: LatencyReport(
                timeToFirstWord: timeToFirstWord,
                totalTime: realTimeFactor * 10,
                audioDuration: 10,
                realTimeFactor: realTimeFactor
            ),
            decodingFallbacks: 0
        )
        return TranscriptEvaluator(knownNames: Set(names))
            .evaluate(fixtureName: fixture, reference: reference, output: output)
    }

    private func report(
        _ evaluations: [TranscriptEvaluation],
        conditions: MeasurementConditions? = nil
    ) -> TestReport {
        TestReport(evaluations: evaluations, command: "caption-harness report --all", conditions: conditions)
    }

    // MARK: - The brief's format

    func testSummaryUsesTheColumnsTheBriefSpecifies() {
        let markdown = report([evaluation("quiet")]).markdown()
        XCTAssertTrue(
            markdown.contains("| Fixture | WER | Critical Info Score | TTFT (ms) | RTF |"),
            markdown
        )
        XCTAssertTrue(markdown.contains("## Summary"), markdown)
        XCTAssertTrue(markdown.contains("## Failures"), markdown)
        XCTAssertTrue(markdown.contains("## Recommendations"), markdown)
    }

    func testHeaderCarriesTheTimestampAndModel() {
        let markdown = report([evaluation("quiet")]).markdown()
        XCTAssertTrue(markdown.contains("# Test Report — "), markdown)
    }

    func testMissingReferenceIsReportedRatherThanScoredAsZero() {
        let unscored = TranscriptEvaluator().evaluate(
            fixtureName: "unscored",
            reference: nil,
            output: EngineOutput(
                transcript: Transcript(text: "something", segments: []),
                latency: LatencyReport(
                    timeToFirstWord: 0.5, totalTime: 2, audioDuration: 10, realTimeFactor: 0.2
                ),
                decodingFallbacks: 0
            )
        )
        let markdown = report([unscored]).markdown()
        XCTAssertTrue(markdown.contains("| unscored | — | — |"), markdown)
        XCTAssertTrue(markdown.contains("no reference transcript"), markdown)
    }

    // MARK: - Recommendations are derived, not fixed

    func testDroppedNegationDrivesTheFirstRecommendation() {
        let markdown = report([
            evaluation("doctor", reference: "Do not take the pill.", hypothesis: "Do take the pill.")
        ]).markdown()
        XCTAssertTrue(markdown.contains("Fix the negation losses first"), markdown)
    }

    func testCleanRunRecommendsNoChange() {
        let markdown = report([evaluation("quiet")]).markdown()
        XCTAssertFalse(markdown.contains("Fix the negation"), markdown)
        XCTAssertTrue(markdown.contains("No failures."), markdown)
    }

    // MARK: - Contention

    func testContendedRunWarnsAboveTheTable() {
        let markdown = report(
            [evaluation("quiet")],
            conditions: MeasurementConditions(loadAverage: 8.8, processorCount: 10)
        ).markdown()

        XCTAssertTrue(markdown.contains("Timing measured under load"), markdown)

        // Above the table, so a reader cannot take the timings at face value first.
        let warning = try? XCTUnwrap(markdown.range(of: "Timing measured under load"))
        let table = try? XCTUnwrap(markdown.range(of: "| Fixture |"))
        if let warning, let table {
            XCTAssertLessThan(warning.lowerBound, table.lowerBound)
        } else {
            XCTFail("expected both the warning and the table: \(markdown)")
        }
    }

    func testContendedRunSaysAccuracyStillHolds() {
        let markdown = report(
            [evaluation("quiet")],
            conditions: MeasurementConditions(loadAverage: 8.8, processorCount: 10)
        ).markdown()
        XCTAssertTrue(markdown.contains("WER and critical information score are unaffected"), markdown)
    }

    func testContendedRunPutsTheCaveatFirstAmongRecommendations() {
        // A negation loss is normally the lead recommendation; contention outranks it, because it
        // undermines the latency numbers every other timing claim rests on.
        let markdown = report(
            [evaluation("doctor", reference: "Do not take the pill.", hypothesis: "Do take the pill.")],
            conditions: MeasurementConditions(loadAverage: 9, processorCount: 8)
        ).markdown()

        let reMeasure = try? XCTUnwrap(markdown.range(of: "Re-measure before acting on any timing"))
        let negation = try? XCTUnwrap(markdown.range(of: "Fix the negation losses first"))
        if let reMeasure, let negation {
            XCTAssertLessThan(reMeasure.lowerBound, negation.lowerBound)
        } else {
            XCTFail("expected both recommendations: \(markdown)")
        }
    }

    func testIdleRunSaysNothingAboutLoad() {
        let markdown = report(
            [evaluation("quiet")],
            conditions: MeasurementConditions(loadAverage: 0.4, processorCount: 10)
        ).markdown()
        XCTAssertFalse(markdown.contains("under load"), markdown)
        XCTAssertFalse(markdown.contains("Re-measure"), markdown)
    }

    func testUnmeasuredConditionsDoNotWarn() {
        XCTAssertFalse(report([evaluation("quiet")]).markdown().contains("under load"))
    }

    func testContentionThresholdScalesWithCoreCount() {
        // Half the cores busy is the trip point: a false positive costs a re-run, a false negative
        // means acting on a timing that only reflects what else the machine was doing.
        XCTAssertFalse(MeasurementConditions(loadAverage: 4, processorCount: 10).isContended)
        XCTAssertTrue(MeasurementConditions(loadAverage: 6, processorCount: 10).isContended)
        XCTAssertTrue(MeasurementConditions(loadAverage: 2, processorCount: 2).isContended)
    }

    func testMeasuredConditionsArePlausible() {
        let conditions = MeasurementConditions.current()
        XCTAssertGreaterThan(conditions.processorCount, 0)
        XCTAssertGreaterThanOrEqual(conditions.loadAverage, 0)
    }
}
