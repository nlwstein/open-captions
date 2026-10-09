import XCTest

@testable import CaptionKit

final class CriticalInfoScorerTests: XCTestCase {

    private func score(
        _ reference: String,
        _ hypothesis: String,
        names: [String] = []
    ) -> CriticalInfoReport {
        CriticalInfoScorer(knownNames: Set(names)).score(reference: reference, hypothesis: hypothesis)
    }

    // MARK: - Clean runs

    func testPerfectTranscriptScoresOneWithNoFailures() {
        let report = score("Take two pills with water.", "Take two pills with water.")
        XCTAssertEqual(report.score, 1.0, accuracy: 1e-9)
        XCTAssertTrue(report.misses.isEmpty)
        XCTAssertEqual(report.severeMissCount, 0)
    }

    func testUnrelatedWordsDoNotAffectCriticalScore() {
        // Messy filler, but every critical token survived.
        let report = score(
            "Um, so, take the second pill at 2:30.",
            "So take the 2nd pill at 2:30."
        )
        XCTAssertEqual(report.score, 1.0, accuracy: 1e-9, "misses: \(report.misses)")
    }

    // MARK: - Negations

    func testDroppedNegationIsSevere() {
        let report = score("Do not take the second pill.", "Do take the second pill.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        let miss = report.severeMisses.first
        XCTAssertEqual(miss?.category, .negation)
        XCTAssertEqual(miss?.outcome, .dropped)
        XCTAssertEqual(miss?.spoken, "not")
    }

    func testContractedNegationLostIsSevere() {
        let report = score("I can't walk that far.", "I can walk that far.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        XCTAssertEqual(report.severeMisses.first?.spoken, "can't")
    }

    /// The inverse failure: the recognizer inserts a negation that was never spoken, which
    /// reverses the meaning of a sentence that was perfectly clear.
    func testInventedNegationIsSevere() {
        let report = score("The doctor said to take it.", "The doctor said not to take it.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        let miss = report.severeMisses.first
        XCTAssertEqual(miss?.category, .negation)
        XCTAssertEqual(miss?.outcome, .added)
        XCTAssertEqual(miss?.heardAs, "not")
        XCTAssertNil(miss?.spoken)
    }

    /// The same inversion arriving as a substitution rather than an extra word. "can" becoming
    /// "can't" is one edit, not an insertion, and must not slip past the check.
    func testNegationSubstitutedForAPositiveWordIsSevere() {
        let report = score("I can walk that far.", "I can't walk that far.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        let miss = report.severeMisses.first
        XCTAssertEqual(miss?.category, .negation)
        XCTAssertEqual(miss?.outcome, .added)
        XCTAssertEqual(miss?.heardAs, "can't")
        XCTAssertEqual(miss?.spoken, "can")
    }

    func testPositiveSubstitutedForANegationIsSevere() {
        // The mirror image: a spoken negation replaced by a positive word.
        let report = score("She won't come tomorrow.", "She will come tomorrow.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        XCTAssertEqual(report.severeMisses.first?.outcome, .changed)
    }

    func testNegationSwapBetweenFormsIsNotReportedAsInvention() {
        // Both sides negate, so polarity is unchanged and nothing should be flagged.
        let report = score("I cannot walk.", "I can't walk.")
        XCTAssertEqual(report.severeMissCount, 0, "misses: \(report.misses)")
    }

    func testDifferentNegationFormStillCountsAsPreserved() {
        // "do not" and "don't" carry the same polarity, so this is not a failure.
        let report = score("Do not move.", "Don't move.")
        XCTAssertEqual(report.severeMissCount, 0, "misses: \(report.misses)")
        XCTAssertEqual(report.categories.negation.recall, 1.0, accuracy: 1e-9)
    }

    // MARK: - Numbers

    func testWrongNumberIsSevere() {
        let report = score("Take 15 milligrams.", "Take 50 milligrams.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        XCTAssertEqual(report.severeMisses.first?.category, .number)
        XCTAssertEqual(report.severeMisses.first?.spoken, "15")
        XCTAssertEqual(report.severeMisses.first?.heardAs, "50")
    }

    /// Digits and words for the same quantity must not be reported as a discrepancy.
    func testSpokenAndWrittenNumbersAgree() {
        let report = score("Take fifteen milligrams.", "Take 15 milligrams.")
        XCTAssertEqual(report.score, 1.0, accuracy: 1e-9, "misses: \(report.misses)")
    }

    func testDroppedNumberIsSevere() {
        let report = score("Call me at 2:30.", "Call me at.")
        XCTAssertEqual(report.severeMissCount, 1, "misses: \(report.misses)")
        XCTAssertEqual(report.severeMisses.first?.outcome, .dropped)
    }

    func testYearIsScoredAsOneNumber() {
        let report = score("That was in 1952.", "That was in 1952.")
        XCTAssertEqual(report.categories.number.total, 1, "a year is a single number")
        XCTAssertEqual(report.score, 1.0, accuracy: 1e-9)
    }

    // MARK: - Names

    func testWrongNameIsReported() {
        let report = score(
            "Dr. Feldman said to rest.",
            "Dr. Bellman said to rest.",
            names: ["Feldman"]
        )
        XCTAssertEqual(report.categories.name.total, 1)
        XCTAssertEqual(report.categories.name.correct, 0)
        let miss = report.misses.first { $0.category == .name }
        XCTAssertEqual(miss?.severity, .moderate)
        XCTAssertEqual(miss?.spoken, "feldman")
        XCTAssertEqual(miss?.heardAs, "bellman")
    }

    func testSingleCharacterNameVarianceIsMinor() {
        let report = score("Ask Feldman.", "Ask Feldmann.", names: ["Feldman"])
        XCTAssertEqual(report.misses.first?.severity, .minor, "misses: \(report.misses)")
    }

    func testDroppedNameIsReported() {
        let report = score("Margaret is coming.", "Is coming.", names: ["Margaret"])
        let miss = report.misses.first { $0.category == .name }
        XCTAssertEqual(miss?.outcome, .dropped)
        XCTAssertEqual(miss?.severity, .moderate)
    }

    /// The doctor-visit fixture transcribed "Doctor Feldman" as "Dr. Feldman" and the scorer
    /// reported a name failure. Both forms name the same person; the difference is formatting.
    func testSpokenAndAbbreviatedTitlesAreNotANameFailure() {
        let report = score("I'm Doctor Feldman.", "I'm Dr. Feldman.")
        XCTAssertTrue(report.misses.isEmpty, "misses: \(report.misses)")
        XCTAssertEqual(report.categories.name.correct, 1, "Feldman should still be scored")
    }

    /// A title must not be counted as a name in its own right, which would let a correct
    /// transcription register as a miss.
    func testTitleIsNotCountedAsASeparateName() {
        let report = score("I'm Doctor Feldman.", "I'm Doctor Feldman.")
        XCTAssertEqual(report.categories.name.total, 1, "only Feldman is a name")
    }

    func testKnownNamesAreScoredEvenWhenNotCapitalised() {
        // The recognizer lowercased the name, so detection alone would miss it.
        let report = score("ask margaret about it", "ask margaret about it", names: ["Margaret"])
        XCTAssertEqual(report.categories.name.total, 1)
        XCTAssertEqual(report.categories.name.correct, 1)
    }

    // MARK: - Category accounting

    func testEmptyCategoryScoresFullRecallRatherThanZero() {
        // No names were spoken, so there are no names to have missed.
        let report = score("Take two pills.", "Take two pills.")
        XCTAssertEqual(report.categories.name.total, 0)
        XCTAssertEqual(report.categories.name.recall, 1.0, accuracy: 1e-9)
    }

    func testPartialRecallIsAveragedAcrossCategories() {
        // Negation and number both survive; the name is lost, so one category of three fails.
        let report = score(
            "Margaret did not take 2 pills.",
            "did not take 2 pills.",
            names: ["Margaret"]
        )
        XCTAssertEqual(report.categories.negation.recall, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.categories.number.recall, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.categories.name.recall, 0.0, accuracy: 1e-9)
        XCTAssertEqual(report.score, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testMissesCarrySurroundingContext() {
        let report = score(
            "The doctor said you should not take the pill today.",
            "The doctor said you should take the pill today."
        )
        let miss = report.severeMisses.first
        XCTAssertNotNil(miss?.context)
        // Context is drawn from the folded tokens the alignment ran on, so a title appears in its
        // abbreviated form. That is the price of scoring "Doctor"/"Dr." as the same word.
        XCTAssertTrue(miss?.context.contains("dr") == true, "got \(miss?.context ?? "nil")")
        XCTAssertTrue(miss?.context.contains("pill") == true, "got \(miss?.context ?? "nil")")
    }

    func testReportRoundTripsThroughJSON() throws {
        let report = score("Do not take 15 pills, Margaret.", "take 50 pills, Margaret.", names: ["Margaret"])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CriticalInfoReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
