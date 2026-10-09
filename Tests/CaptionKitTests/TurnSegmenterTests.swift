import XCTest

@testable import CaptionKit

final class TurnSegmenterTests: XCTestCase {

    private let segmenter = TurnSegmenter(silenceGap: 0.8)

    private func word(_ text: String, _ start: Float, _ end: Float) -> CaptionWord {
        CaptionWord(text: text, start: start, end: end, probability: 1.0)
    }

    private func transcript(_ words: [CaptionWord]) -> Transcript {
        Transcript(
            text: words.map(\.text).joined(separator: " "),
            segments: [CaptionSegment(
                text: words.map(\.text).joined(separator: " "),
                start: words.first?.start ?? 0,
                end: words.last?.end ?? 0,
                words: words
            )]
        )
    }

    func testContinuousSpeechIsOneTurn() {
        let turns = segmenter.turns(from: transcript([
            word("hello", 0.0, 0.4),
            word("there", 0.5, 0.8),
            word("friend", 0.9, 1.2),
        ]))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.text, "hello there friend")
    }

    func testShortPauseDoesNotBreakTheTurn() {
        // 0.5s of silence is below the 800ms threshold.
        let turns = segmenter.turns(from: transcript([
            word("hello", 0.0, 0.4),
            word("again", 0.9, 1.2),
        ]))
        XCTAssertEqual(turns.count, 1)
    }

    func testLongPauseStartsANewTurn() {
        // 1.0s of silence exceeds the threshold.
        let turns = segmenter.turns(from: transcript([
            word("hello", 0.0, 0.4),
            word("goodbye", 1.4, 1.8),
        ]))
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].text, "hello")
        XCTAssertEqual(turns[1].text, "goodbye")
    }

    func testGapExactlyAtThresholdDoesNotBreak() {
        // The rule is silence *greater than* 800ms.
        let turns = segmenter.turns(from: transcript([
            word("hello", 0.0, 0.4),
            word("again", 1.2, 1.6),
        ]))
        XCTAssertEqual(turns.count, 1)
    }

    func testTurnSpansAreReported() {
        let turns = segmenter.turns(from: transcript([
            word("one", 1.0, 1.4),
            word("two", 1.5, 2.0),
        ]))
        XCTAssertEqual(turns.first?.start, 1.0)
        XCTAssertEqual(turns.first?.end, 2.0)
        XCTAssertEqual(turns.first?.wordCount, 2)
    }

    /// Word timings let a turn break inside a single recognizer segment, which is the case that
    /// matters: Whisper packs up to 30 seconds into one segment regardless of who was speaking.
    func testBreaksInsideASingleSegment() {
        let words = [
            word("first", 0.0, 0.4),
            word("speaker", 0.5, 0.9),
            word("second", 2.5, 2.9),
            word("speaker", 3.0, 3.4),
        ]
        let oneSegment = Transcript(
            text: "first speaker second speaker",
            segments: [CaptionSegment(text: "first speaker second speaker", start: 0, end: 3.4, words: words)]
        )
        XCTAssertEqual(segmenter.turns(from: oneSegment).count, 2)
    }

    /// Non-monotonic timestamps would otherwise produce a negative gap. Treating that as a break
    /// would shatter a single sentence into fragments.
    func testNonMonotonicTimestampsDoNotShatterTheTurn() {
        let turns = segmenter.turns(from: transcript([
            word("hello", 0.0, 1.0),
            word("there", 0.5, 1.5),
        ]))
        XCTAssertEqual(turns.count, 1)
    }

    func testFallsBackToSegmentsWhenWordsAreAbsent() {
        let transcript = Transcript(
            text: "one two three",
            segments: [
                CaptionSegment(text: "one", start: 0, end: 1),
                CaptionSegment(text: "two", start: 1.2, end: 2),
                CaptionSegment(text: "three", start: 5, end: 6),
            ]
        )
        let turns = segmenter.turns(from: transcript)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].text, "one two")
        XCTAssertEqual(turns[1].text, "three")
    }

    func testEmptyTranscriptYieldsNoTurns() {
        XCTAssertTrue(segmenter.turns(from: Transcript(text: "", segments: [])).isEmpty)
    }

    func testMinimumDurationMergesFlickerTurns() {
        let merging = TurnSegmenter(silenceGap: 0.8, minimumTurnDuration: 1.0)
        let turns = merging.turns(from: transcript([
            word("hmm", 0.0, 0.2),
            word("actually", 1.5, 2.5),
        ]))
        XCTAssertEqual(turns.count, 1, "a 0.2s interjection should not stand alone")
    }
}
