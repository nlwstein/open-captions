import XCTest

@testable import CaptionKit

final class AudioLevelMeterTests: XCTestCase {

    /// One 100 ms chunk of 16 kHz audio at a fixed amplitude.
    private func chunk(_ amplitude: Float, milliseconds: Double = 100) -> [Float] {
        Array(repeating: amplitude, count: Int(16_000 * milliseconds / 1000))
    }

    func testSilenceIsNotSpeech() {
        var meter = AudioLevelMeter()
        for _ in 0..<20 { meter.append(chunk(0)) }
        XCTAssertFalse(meter.isSpeaking)
        XCTAssertEqual(meter.trailingSilence, 2.0, accuracy: 0.01)
    }

    func testSpeechFollowedBySilenceStartsTheSilenceClock() {
        var meter = AudioLevelMeter()
        // A floor has to exist before anything can be loud against it. Ten identical chunks are not
        // evidence of speech — they are the baseline — so the room is established quietly first.
        for _ in 0..<10 { meter.append(chunk(0.001)) }
        XCTAssertFalse(meter.isSpeaking)

        meter.append(chunk(0.2))
        XCTAssertTrue(meter.isSpeaking, "a loud chunk against a quiet floor is speech")
        XCTAssertEqual(meter.trailingSilence, 0, accuracy: 0.001)

        for _ in 0..<5 { meter.append(chunk(0.001)) }
        XCTAssertFalse(meter.isSpeaking)
        XCTAssertEqual(meter.trailingSilence, 0.5, accuracy: 0.01)
    }

    /// The point of the relative floor: a noisy room raises the bar, so the room's own noise stops
    /// reading as speech. A fixed threshold would call this restaurant "speech" forever.
    func testRoomNoiseDoesNotReadAsSpeech() {
        var meter = AudioLevelMeter()
        for _ in 0..<60 { meter.append(chunk(0.05)) }
        XCTAssertFalse(meter.isSpeaking)
    }

    /// ...and speech still clears the raised bar.
    func testSpeechIsHeardOverRoomNoise() {
        var meter = AudioLevelMeter()
        for _ in 0..<60 { meter.append(chunk(0.05)) }
        XCTAssertFalse(meter.isSpeaking)

        meter.append(chunk(0.3))
        XCTAssertTrue(meter.isSpeaking, "16 dB over the room's floor is speech, whatever the room is")
    }

    /// A very quiet room is where an absolute threshold falls down in the other direction: the
    /// floor sits so low that a breath clears it. `absoluteFloor` is the guard.
    func testNearSilentAudioIsNeverSpeech() {
        var meter = AudioLevelMeter()
        for _ in 0..<60 { meter.append(chunk(0.0001)) }
        XCTAssertFalse(meter.isSpeaking)
    }

    func testNormalizedLevelStaysInRange() {
        var meter = AudioLevelMeter()
        for amplitude in [Float(0), 0.0001, 0.01, 0.5, 1.0] {
            meter.append(chunk(amplitude))
            XCTAssertGreaterThanOrEqual(meter.normalizedLevel, 0)
            XCTAssertLessThanOrEqual(meter.normalizedLevel, 1)
        }
    }

    func testBarIsAlwaysTheRequestedWidth() {
        var meter = AudioLevelMeter()
        for amplitude in [Float(0), 0.05, 0.5] {
            meter.append(chunk(amplitude))
            XCTAssertEqual(meter.bar(width: 12).count, 12)
        }
    }

    /// The floor is the 10th percentile, not the minimum, so one anomalously quiet chunk must not
    /// drag it down and turn the whole window into "speech".
    func testASingleQuietChunkDoesNotRedefineTheFloor() {
        var meter = AudioLevelMeter()
        for _ in 0..<40 { meter.append(chunk(0.05)) }
        meter.append(chunk(0.00001))
        XCTAssertFalse(meter.isSpeaking)
    }
}
