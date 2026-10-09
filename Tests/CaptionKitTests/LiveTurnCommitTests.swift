import XCTest

@testable import CaptionKit

final class LiveTurnCommitTests: XCTestCase {

    private func turn(_ text: String, _ start: Float, _ end: Float) -> CaptionTurn {
        CaptionTurn(text: text, start: start, end: end, wordCount: text.split(separator: " ").count)
    }

    func testNothingIsCommittedWithoutAudioToLookPast() {
        // The last turn ends 0.2s before the horizon — not enough silence to call it finished.
        let (closed, provisional) = LiveTurnCommit.split(
            turns: [turn("hello there", 0.0, 9.8)],
            horizon: 10.0,
            silenceGap: 0.8,
            committedTo: 0
        )
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(provisional?.text, "hello there")
    }

    func testATurnIsCommittedOnceEnoughSilenceFollowsIt() {
        // Ends 0.9s before the horizon, which clears the 800 ms threshold.
        let (closed, provisional) = LiveTurnCommit.split(
            turns: [turn("hello there", 0.0, 9.1)],
            horizon: 10.0,
            silenceGap: 0.8,
            committedTo: 0
        )
        XCTAssertEqual(closed.map(\.text), ["hello there"])
        XCTAssertNil(provisional)
    }

    func testOnlyTheLastTurnStaysProvisional() {
        let (closed, provisional) = LiveTurnCommit.split(
            turns: [turn("first", 0.0, 2.0), turn("second", 4.0, 9.9)],
            horizon: 10.0,
            silenceGap: 0.8,
            committedTo: 0
        )
        XCTAssertEqual(closed.map(\.text), ["first"])
        XCTAssertEqual(provisional?.text, "second")
    }

    func testAlreadyCommittedTurnsAreNotReturnedTwice() {
        let (closed, provisional) = LiveTurnCommit.split(
            turns: [turn("first", 0.0, 2.0), turn("second", 4.0, 5.0)],
            horizon: 10.0,
            silenceGap: 0.8,
            committedTo: 5.0
        )
        XCTAssertTrue(closed.isEmpty)
        XCTAssertNil(provisional)
    }

    /// The end of a session: everything left is shown, silence or not, because there is no later
    /// decode coming to confirm it.
    func testForcingCommitsTheOpenTurn() {
        let (closed, provisional) = LiveTurnCommit.split(
            turns: [turn("hello there", 0.0, 9.9)],
            horizon: 10.0,
            silenceGap: 0.8,
            committedTo: 0,
            force: true
        )
        XCTAssertEqual(closed.map(\.text), ["hello there"])
        XCTAssertNil(provisional)
    }

    func testNoTurnsMeansNothingToCommit() {
        let (closed, provisional) = LiveTurnCommit.split(
            turns: [],
            horizon: 10.0,
            silenceGap: 0.8,
            committedTo: 0
        )
        XCTAssertTrue(closed.isEmpty)
        XCTAssertNil(provisional)
    }
}
