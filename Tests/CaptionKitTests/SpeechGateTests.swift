import XCTest
@testable import CaptionKit

/// The gate exists because the live loop committed `[no audio]` and `[BLANK _AUDIO]` to the
/// transcript on audio that contained no speech. These tests pin the rule that stops it, including
/// the cases that must still get through — a gate that drops real speech is worse than no gate.
final class SpeechGateTests: XCTestCase {

    private func quality(
        noSpeech: Float = 0.0,
        logProb: Float = -0.18,
        compression: Float = 1.2,
        temperature: Float = 0
    ) -> DecodeQuality {
        DecodeQuality(
            noSpeechProbability: noSpeech,
            averageLogProbability: logProb,
            compressionRatio: compression,
            temperature: temperature
        )
    }

    // MARK: - What was actually observed

    func testRejectsTheHallucinationSmallProducedOnRoomTone() {
        // Measured: 12 s of pink noise at room-tone level -> "[no audio]", lp -0.48.
        XCTAssertEqual(
            SpeechGate().verdict(text: "[no audio]", quality: quality(logProb: -0.48)),
            .artefact
        )
    }

    func testRejectsTheHallucinationBaseProducedOnRoomTone() {
        // Measured: "[BLANK _AUDIO]", lp -0.37. The artefact rule fires before the confidence rule,
        // which matters: -0.37 is above the log-probability threshold, so confidence alone would
        // have let this through. It is the same trap that defeats WhisperKit's own silence check.
        XCTAssertEqual(
            SpeechGate().verdict(text: "[BLANK _AUDIO]", quality: quality(logProb: -0.37)),
            .artefact
        )
    }

    func testAdmitsRealSpeechMeasuredThroughTheSameLoop() {
        // Measured on quiet-single-speaker: lp -0.18 … -0.21, depending on the window.
        let gate = SpeechGate()
        for logProb: Float in [-0.18, -0.21] {
            XCTAssertEqual(
                gate.verdict(
                    text: "I put the kettle on, so we can sit in the kitchen.",
                    quality: quality(logProb: logProb)
                ),
                .speech
            )
        }
    }

    // MARK: - The artefact rule

    func testTreatsAnySingleBracketedSpanAsAnArtefact() {
        // Not a list of known strings — a list is a losing game, because the next model invents a
        // new one. These are all things Whisper has been seen to emit on non-speech.
        for text in ["[BLANK_AUDIO]", "[no audio]", "[INAUDIBLE]", "[ Silence ]", "(wind blowing)",
                     "*laughs*", "[MUSIC PLAYING]"] {
            XCTAssertTrue(SpeechGate.isArtefact(text), "\(text) should read as an artefact")
        }
    }

    func testKeepsASentenceThatMerelyOpensWithABracketedAside() {
        // The distinction the rule turns on: the closing bracket is not the last character, so the
        // brackets wrap a clause rather than the whole utterance.
        let gate = SpeechGate()
        XCTAssertFalse(SpeechGate.isArtefact("[laughs] I don't think so"))
        XCTAssertEqual(
            gate.verdict(text: "[laughs] I don't think so", quality: quality()),
            .speech
        )
    }

    func testKeepsSpeechThatEndsWithABracket() {
        XCTAssertFalse(SpeechGate.isArtefact("Take the blue one [points]"))
    }

    func testTreatsEmptyTextAsNothingToShow() {
        XCTAssertTrue(SpeechGate.isArtefact(""))
        XCTAssertTrue(SpeechGate.isArtefact("   "))
    }

    // MARK: - The confidence rules

    func testRejectsAConfidentDecoderThatStillReportsNoSpeech() {
        // WhisperKit's own rule. It is inert in practice — WhisperKit hardcodes `noSpeechProb` to
        // zero, so nothing can ever cross this threshold — but the gate stays honest about the
        // evidence rather than assuming the field is meaningless, in case a future version or a
        // different engine fills it in.
        XCTAssertEqual(
            SpeechGate().verdict(
                text: "Thank you for watching.",
                quality: quality(noSpeech: 0.81, logProb: -0.05)
            ),
            .noSpeech
        )
    }

    func testRejectsTextThatIsFarBelowAnyConfidenceRealSpeechShows() {
        // The rule is a backstop for gross decoder failure, not a speech/filler classifier — the two
        // distributions were measured to overlap, so this has to sit well clear of real audio.
        XCTAssertEqual(
            SpeechGate().verdict(
                text: "Thank you for watching.",
                quality: quality(logProb: -2.10)
            ),
            .lowConfidence
        )
    }

    // MARK: - The regression this gate was nearly shipped with

    func testKeepsFarFieldSpeechThatAnEarlierVersionThrewAway() {
        // The first version put the log-probability threshold at -0.40, which looked like it sat in a
        // clean gap between the near-field speech it was calibrated on (-0.21) and filler (-0.37).
        // It does not: real far-field speech occupies -0.41 … -0.70. This is a verbatim drop from
        // ami-meeting-far — a *correct* transcription — that the gate discarded. Pin it.
        let gate = SpeechGate()
        let text = "Well, this is the kickoff meeting for our project. And this is just what "
            + "we're going to be doing over the next 25 minutes."
        for logProb: Float in [-0.41, -0.45, -0.70] {
            XCTAssertEqual(
                gate.verdict(text: text, quality: quality(logProb: logProb)),
                .speech,
                "far-field speech at lp \(logProb) must be kept"
            )
        }
    }

    func testThresholdSitsBelowTheWorstRealSpeechMeasured() {
        // -0.70 is the least confident real far-field window measured. The backstop must be under it,
        // or the gate starts discarding the scenario the app exists for. It must also be low enough
        // to be a backstop rather than a classifier: this test fails if someone reintroduces a
        // threshold "between speech and noise", which measurement showed does not exist.
        let gate = SpeechGate()
        XCTAssertLessThan(gate.minimumAverageLogProbability, -0.70)
    }

    func testMissingQualityIsNotEvidenceAgainstSpeech() {
        // An engine that reports nothing must not have all of its output suppressed.
        XCTAssertEqual(SpeechGate().verdict(text: "Hello there.", quality: nil), .speech)
    }

    func testOpenGateAdmitsEverything() {
        let open = SpeechGate.open
        XCTAssertEqual(open.verdict(text: "[BLANK_AUDIO]", quality: quality(logProb: -3)), .speech)
        XCTAssertFalse(open.isEnabled)
    }
}
