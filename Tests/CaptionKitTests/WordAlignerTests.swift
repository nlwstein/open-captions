import XCTest

@testable import CaptionKit

final class WordAlignerTests: XCTestCase {

    private func wer(_ reference: String, _ hypothesis: String) -> Double {
        WordAligner.align(
            reference: TextNormalizer.surfaceTokens(reference),
            hypothesis: TextNormalizer.surfaceTokens(hypothesis)
        ).wordErrorRate
    }

    func testIdenticalTextHasNoErrors() {
        let alignment = WordAligner.align(
            reference: "the cat sat on the mat".split(separator: " ").map(String.init),
            hypothesis: "the cat sat on the mat".split(separator: " ").map(String.init)
        )
        XCTAssertEqual(alignment.wordErrorRate, 0)
        XCTAssertEqual(alignment.correct, 6)
        XCTAssertEqual(alignment.substitutions, 0)
        XCTAssertEqual(alignment.deletions, 0)
        XCTAssertEqual(alignment.insertions, 0)
    }

    func testSingleSubstitution() {
        // 1 substitution over 6 reference words.
        XCTAssertEqual(wer("the cat sat on the mat", "the cat sat on a mat"), 1.0 / 6.0, accuracy: 1e-9)
    }

    func testSingleDeletion() {
        XCTAssertEqual(wer("the cat sat on the mat", "the cat sat on mat"), 1.0 / 6.0, accuracy: 1e-9)
    }

    func testSingleInsertion() {
        XCTAssertEqual(wer("the cat sat on the mat", "the cat sat on the red mat"), 1.0 / 6.0, accuracy: 1e-9)
    }

    func testCompleteMismatch() {
        XCTAssertEqual(wer("alpha beta", "gamma delta"), 1.0, accuracy: 1e-9)
    }

    func testEmptyHypothesisDeletesEverything() {
        XCTAssertEqual(wer("one two three", ""), 1.0, accuracy: 1e-9)
    }

    func testEmptyReferenceScoresZeroAgainstEmptyHypothesis() {
        XCTAssertEqual(wer("", ""), 0)
    }

    /// Nothing was spoken, so there was nothing to miss — but text that appears from silence is
    /// entirely fabricated and should not score as a clean run.
    func testEmptyReferencePenalisesHallucination() {
        XCTAssertEqual(wer("", "hello there"), 1.0, accuracy: 1e-9)
    }

    func testPunctuationAndCaseDoNotCountAsErrors() {
        XCTAssertEqual(wer("Hello, world!", "hello world"), 0)
    }

    /// Word error rate can exceed 1 when the recognizer emits more words than were spoken.
    func testRateCanExceedOne() {
        XCTAssertEqual(wer("hi", "hello there friend"), 3.0, accuracy: 1e-9)
    }

    // MARK: - Alignment mapping

    func testMapsReferenceIndicesToHypothesisIndices() {
        let alignment = WordAligner.align(
            reference: ["a", "b", "c"],
            hypothesis: ["a", "x", "c"]
        )
        XCTAssertEqual(alignment.hypothesisIndex(forReference: 0), 0)
        XCTAssertEqual(alignment.hypothesisIndex(forReference: 1), 1)
        XCTAssertEqual(alignment.hypothesisIndex(forReference: 2), 2)
        XCTAssertEqual(alignment.substitutions, 1)
    }

    func testDroppedWordHasNoHypothesisIndex() {
        let alignment = WordAligner.align(
            reference: ["a", "b", "c"],
            hypothesis: ["a", "c"]
        )
        XCTAssertNil(alignment.hypothesisIndex(forReference: 1))
        XCTAssertEqual(alignment.hypothesisIndex(forReference: 2), 1)
        XCTAssertEqual(alignment.deletions, 1)
    }

    /// Ties must resolve to the diagonal, or one substitution would be reported as a deletion plus
    /// an insertion and both error counts would be inflated.
    func testTiesPreferSubstitutionOverDeleteInsertPairs() {
        let alignment = WordAligner.align(reference: ["a", "b"], hypothesis: ["a", "c"])
        XCTAssertEqual(alignment.substitutions, 1)
        XCTAssertEqual(alignment.deletions, 0)
        XCTAssertEqual(alignment.insertions, 0)
    }

    // MARK: - Character distance

    func testCharacterEditDistance() {
        XCTAssertEqual(WordAligner.characterEditDistance("feldman", "feldman"), 0)
        XCTAssertEqual(WordAligner.characterEditDistance("feldman", "feldmann"), 1)
        XCTAssertEqual(WordAligner.characterEditDistance("kitten", "sitting"), 3)
        XCTAssertEqual(WordAligner.characterEditDistance("", "abc"), 3)
        XCTAssertEqual(WordAligner.characterEditDistance("abc", ""), 3)
    }
}
