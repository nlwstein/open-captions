import FluidAudio
import XCTest
@testable import CaptionKit

final class ModelPinsTests: XCTestCase {
    /// A key FluidAudio never asks about pins nothing, and the models would follow `main` again.
    func testEveryPinNamesARepositoryFluidAudioDownloads() {
        let paths = Set(Repo.allCases.map(\.remotePath))
        for key in ModelPins.revisions.keys { XCTAssertTrue(paths.contains(key), key) }
    }

    func testPinsAreFullCommits() {
        for revision in ModelPins.revisions.values {
            XCTAssertTrue(revision.count == 40 && revision.allSatisfy(\.isHexDigit), revision)
        }
    }

    /// The recognisers the app offers and the diarizer all come from a pinned commit.
    func testEveryModelTheAppLoadsIsPinned() {
        for variant in [StreamingModelVariant.nemotron1120ms, .parakeetUnified1120ms] {
            XCTAssertNotNil(ModelPins.revisions[variant.repo.remotePath], "\(variant)")
        }
        XCTAssertNotNil(ModelPins.revisions[Repo.sortformer.remotePath])
    }
}
