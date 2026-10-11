import FluidAudio
import XCTest

@testable import CaptionKit

final class TokenGroupingTests: XCTestCase {

    private func timings(_ pieces: [String]) -> [TokenTiming] {
        pieces.enumerated().map { index, piece in
            TokenTiming(token: piece, tokenId: index, startTime: Double(index) * 0.08,
                        endTime: Double(index + 1) * 0.08, confidence: 1)
        }
    }

    private func grouped(_ calls: [[String]]) -> [String] {
        var words: [StreamedWord] = []
        var pending = false
        for call in calls {
            StreamingCaptioner.group(timings(call), into: &words, pendingBoundary: &pending)
        }
        return words.map(\.text)
    }

    func testSubwordPiecesJoinTheirWord() {
        XCTAssertEqual(grouped([["▁mo", "ther"]]), ["mother"])
    }

    func testStandaloneBoundaryStartsTheNextWord() {
        // Nemotron has no `▁very` piece, so "not very" arrives as `▁not`, `▁`, `very`. Dropping the
        // bare `▁` once produced "notvery" on screen.
        XCTAssertEqual(grouped([["▁not", "▁", "very"]]), ["not", "very"])
    }

    func testStandaloneBoundarySurvivesAcrossCalls() {
        XCTAssertEqual(grouped([["▁your", "▁"], ["v", "el", "ocity"]]), ["your", "velocity"])
    }
}
