import XCTest

@testable import CaptionKit

final class AutomaticGainTests: XCTestCase {

    /// One chunk of 16 kHz audio at a fixed amplitude.
    private func chunk(_ amplitude: Float, milliseconds: Double = 100) -> [Float] {
        Array(repeating: amplitude, count: Int(16_000 * milliseconds / 1000))
    }

    /// Speech and room alternating, because a percentile cannot describe a signal that never
    /// varies: real speech modulates over tens of decibels and the stage reads that modulation.
    /// `speechChunks` of every `cycle` chunks are speech; the rest is the room.
    private func conversation(
        speech: Float, room: Float, seconds: Double = 21, cycle: Int = 5, speechChunks: Int = 3
    ) -> [[Float]] {
        (0..<Int(seconds * 10)).map { index in
            chunk(index % cycle < speechChunks ? speech : room)
        }
    }

    @discardableResult
    private func apply(_ gain: inout AutomaticGain, _ chunks: [[Float]]) -> [Float] {
        var out: [Float] = []
        for c in chunks { out += gain.process(c) }
        return out
    }

    /// Loudness of a signal's top decile, measured the way the stage itself measures it. Taking the
    /// top decile rather than the whole signal matters because every test signal here is part
    /// speech and part room, and the average of the two describes neither.
    private func speechLevel(of samples: [Float]) -> Float {
        let frames = stride(from: 0, to: samples.count - 1599, by: 1600).map {
            Array(samples[$0..<($0 + 1600)])
        }
        return AutomaticGain.percentile(frames.map { AudioLevelMeter.decibels(of: $0) }, 0.9)
    }

    // MARK: - The level the recogniser gets

    /// The point of the component: quiet far-field speech should come out near the target. DiPCo's
    /// channel arrives around −60 dBFS and the measurement says it belongs near −25.
    func testQuietSpeechIsLiftedTowardTheTarget() {
        var gain = AutomaticGain()
        // -60 dBFS speech over a -94 dBFS room, which is the shape of the real corpus.
        let out = apply(&gain, conversation(speech: 0.001, room: 0.00002))
        XCTAssertEqual(speechLevel(of: out), gain.targetSpeechDb, accuracy: 3.5,
                       "speech at −60 dBFS should land near the −25 dBFS target")
        XCTAssertGreaterThan(gain.currentGainDb, 25)
    }

    /// A recording that is already at a usable level must pass through untouched. This is the case
    /// that rules out a fixed multiplier: `ami-meeting-far` got *worse* when it was boosted, and the
    /// measured reason is that the rule asks for 0 dB on audio that is already loud.
    func testLoudAudioIsNotBoosted() {
        var gain = AutomaticGain()
        let input = conversation(speech: 0.1, room: 0.005) // -20 dBFS speech
        let out = apply(&gain, input)
        XCTAssertEqual(gain.currentGainDb, 0, accuracy: 0.01,
                       "audio already above the target should need no gain at all")
        XCTAssertEqual(out.count, input.flatMap { $0 }.count)
        XCTAssertEqual(out, input.flatMap { $0 }, "and it should be handed through unmodified")
    }

    // MARK: - The two guards

    /// The regression this design exists to prevent. The first implementation tracked a noise floor
    /// that rose at 6 dB/s from −120, so after fifty frames of a quiet room it was still below the
    /// signal, every frame read as speech, and the stage applied its full 32 dB to a silent room —
    /// the exact failure docs/RESEARCH.md's Finding 3 warns about.
    func testFlatSilenceIsNotAmplified() {
        var gain = AutomaticGain()
        for _ in 0..<300 { _ = gain.process(chunk(0.0001)) }
        XCTAssertLessThan(gain.currentGainDb, 1.0, "a flat quiet floor is not speech")
        XCTAssertFalse(gain.isTracking)
    }

    /// A quiet room whose level wanders slightly is still a quiet room. The measured spread of
    /// stationary white noise and of hum is under 0.4 dB, so 1.6 dB here is generous.
    func testANearlySteadyRoomIsNotAmplified() {
        var gain = AutomaticGain()
        _ = apply(&gain, conversation(speech: 0.0001, room: 0.00012, cycle: 2, speechChunks: 1))
        XCTAssertFalse(gain.isTracking, "1.6 dB of spread is not speech")
        XCTAssertLessThan(gain.currentGainDb, 1.0, "a quiet room must not be lifted")
    }

    /// The limit of the spread guard, pinned so that it cannot be "fixed" by accident.
    ///
    /// The test above covers a synthetic room that wanders 1.6 dB. A *recorded* quiet room wanders
    /// **3.15 dB** — measured on `roomtone60.wav`, and higher than either synthetic noise fixture,
    /// because real rooms contain chairs and distant traffic and people breathing. That is above
    /// ``minimumSpreadDb``, so the guard does not fire and this stage lifts an empty room all the
    /// way to its target. This test asserts that it does, because that is the measured behaviour and
    /// the alternative was tried and rejected: a gate wide enough to exclude real room tone starts
    /// closing on the quietest of DiPCo's own speech windows.
    ///
    /// What makes it acceptable is measured separately from this component: 96 s of that same room
    /// tone, taken through the stage at 21.4 dB, produced **zero words** from Nemotron and zero from
    /// Parakeet EOU. Amplifying an empty room invents nothing. If a future engine does hallucinate
    /// on it, this test is where the tradeoff to revisit is recorded.
    func testARealisticRoomToneIsLiftedBecauseTheSpreadGuardCannotSeeIt() {
        var gain = AutomaticGain()
        // 2.9 dB of spread: real room tone's 3.15 dB, rounded down so the case sits just clear of
        // the 2.0 dB gate rather than on it.
        _ = apply(&gain, conversation(speech: 0.0001, room: 0.00014, cycle: 2, speechChunks: 1))
        XCTAssertTrue(gain.isTracking,
                      "a real room's 3.15 dB of wander reads as something worth tracking")
        XCTAssertGreaterThan(gain.currentGainDb, 20, "...and so an empty room is lifted to target")
    }

    /// Speech that stops must not drag the estimate down with it.
    ///
    /// This is the case that forced the second guard. Without it the window's composition changes
    /// from mostly-speech to mostly-room, the 90th percentile sinks toward the room, and the rule
    /// reads that as a very quiet speaker and climbs about 17 dB before the spread finally collapses
    /// — leaving the next sentence badly too hot. The gain must simply hold.
    func testGainAndEstimateAreHeldThroughSilence() {
        var gain = AutomaticGain()
        // -40 dBFS speech over a -94 dBFS room, so the answer is +15 dB and nowhere near the clamp.
        _ = apply(&gain, conversation(speech: 0.01, room: 0.00002))
        let settled = gain.currentGainDb
        let estimate = gain.estimatedSpeechDb
        XCTAssertEqual(settled, 15, accuracy: 1)

        // Ten seconds, deliberately short of `resetAfterSilenceSeconds`: past that the stage throws
        // the estimate away on purpose, which is the next test's job, not this one's.
        _ = apply(&gain, (0..<100).map { _ in chunk(0.0002) })

        XCTAssertFalse(gain.isActive, "ten seconds of flat room is not something being said")
        XCTAssertEqual(gain.estimatedSpeechDb, estimate, accuracy: 1,
                       "the estimate must not follow the room down")
        XCTAssertEqual(gain.currentGainDb, settled, accuracy: 0.5,
                       "a flat room carries no evidence either way, so the gain should not move")
    }

    /// Long silence must not freeze a stale estimate forever. After the reset the stage re-locks
    /// onto whatever it hears next, including a speaker much quieter than the last one — the case
    /// the activity guard would otherwise lock out permanently.
    func testLongSilenceResetsTheEstimate() {
        var gain = AutomaticGain()
        _ = apply(&gain, conversation(speech: 0.01, room: 0.00002))
        XCTAssertEqual(gain.currentGainDb, 15, accuracy: 1)

        _ = apply(&gain, (0..<400).map { _ in chunk(0.0002) }) // ten seconds, no reset yet
        XCTAssertEqual(gain.currentGainDb, 15, accuracy: 0.5, "held, not reset")

        _ = apply(&gain, (0..<400).map { _ in chunk(0.0002) }) // past resetAfterSilenceSeconds
        // A speaker 40 dB below the one before, and 6 dB below the room we just sat in.
        _ = apply(&gain, conversation(speech: 0.0001, room: 0.00001))
        XCTAssertGreaterThan(gain.currentGainDb, 25,
                             "after the reset the stage must pick up a much quieter speaker")
    }

    // MARK: - Housekeeping

    /// Gain is capped, so a pathological input cannot run it to absurdity.
    func testGainIsCapped() {
        var gain = AutomaticGain()
        _ = apply(&gain, conversation(speech: 1e-5, room: 1e-6))
        XCTAssertLessThanOrEqual(gain.currentGainDb, gain.maxGainDb)
        XCTAssertGreaterThan(gain.currentGainDb, 25, "the guard should not have blocked this")
    }

    /// Output stays inside full scale even when the input is loud and the stage has gain to apply.
    func testOutputStaysInRange() {
        var gain = AutomaticGain()
        _ = apply(&gain, conversation(speech: 0.001, room: 0.00002))
        XCTAssertGreaterThan(gain.currentGainDb, 25, "the clamp needs gain present to be tested")
        let out = gain.process(chunk(0.9))
        XCTAssertTrue(out.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    /// The stage is a pure pass-through until it has heard enough to have an opinion.
    func testNoGainBeforeItHasSettled() {
        var gain = AutomaticGain()
        XCTAssertFalse(gain.hasSettled)
        let out = gain.process(chunk(0.001))
        XCTAssertEqual(out, chunk(0.001), "the first frame passes through unchanged")
        XCTAssertEqual(gain.currentGainDb, 0)
    }

    /// The estimate is taken over a fixed span of *time*, so how the caller slices the audio must
    /// not change the answer. Without the internal reframing, twenty 200 ms chunks would look like
    /// twenty frames against forty, and the window would silently mean ten seconds instead of
    /// twenty.
    func testChunkSizeDoesNotChangeTheOutcome() {
        var small = AutomaticGain()
        var large = AutomaticGain()
        let chunks = conversation(speech: 0.001, room: 0.00002)
        _ = apply(&small, chunks)
        _ = apply(&large, chunks.enumerated()
            .filter { $0.offset.isMultiple(of: 2) }
            .map { $0.element + $0.element })
        XCTAssertEqual(small.currentGainDb, large.currentGainDb, accuracy: 0.5)
        XCTAssertEqual(small.estimatedSpeechDb, large.estimatedSpeechDb, accuracy: 0.5)
    }

    /// A chunk shorter than one analysis frame must still be carried over rather than dropped.
    func testChunksSmallerThanAFrameAreCarried() {
        var gain = AutomaticGain()
        let tiny = chunk(0.001, milliseconds: 20)
        for _ in 0..<1050 { _ = gain.process(tiny) } // 21 seconds in 20 ms pieces
        XCTAssertEqual(gain.estimatedSpeechDb, -60, accuracy: 1,
                       "frames must be assembled across calls, not per call")
    }

    func testEmptyInputIsHandled() {
        var gain = AutomaticGain()
        XCTAssertEqual(gain.process([]), [])
        XCTAssertEqual(gain.currentGainDb, 0)
    }
}
