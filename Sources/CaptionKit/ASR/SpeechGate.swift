import Foundation

/// Why a piece of decoded text was rejected, or that it was not.
public enum SpeechGateVerdict: String, Equatable, Sendable {
    /// The decoder stands behind this text. Show it.
    case speech
    /// The whole utterance is a bracketed annotation — `[BLANK_AUDIO]`, `[no audio]`, `(wind)`.
    case artefact
    /// The decoder's own probability that the window holds no speech, above any doubt.
    case noSpeech
    /// The decoder is not confident in the tokens it produced.
    case lowConfidence
}

/// Decides whether decoded text is worth showing to a user.
///
/// Given audio with no speech in it, Whisper does not return nothing — it returns filler. `small`
/// answers twelve seconds of room tone with `[no audio]` and `base` with `[BLANK _AUDIO]`, and the
/// live loop committed both to the transcript as finished turns. For a caption aid that is worse than
/// showing nothing, because the reader has no way to tell it from something that was actually said.
///
/// WhisperKit has a silence check of its own and it does not fire here. `SegmentSeeker` skips a window
/// when `noSpeechProb > 0.6`, but `options.logProbThreshold` overrides that whenever the decoder is
/// *confident* (`SegmentSeeker.swift:62-67`) — and on non-speech these models are confidently wrong.
/// This gate reads the same evidence and deliberately does not grant that override.
///
/// The defaults come from measurement, not taste — including a measurement that killed the first
/// version of this rule. Through the live loop, one window per decode:
///
/// | Audio | Model | Text | `noSpeechProb` | `avgLogprob` |
/// |---|---|---|---|---|
/// | room tone | small | `[no audio]` | 0.00 | −0.48 … −0.62 |
/// | room tone | base | `[BLANK _AUDIO]` | 0.00 | −0.37 … −0.50 |
/// | speech, near field | small | the fixture's four lines | 0.00 | −0.18 … −0.21 |
/// | speech, far field | small | `ami-meeting-far` | 0.00 | **−0.41 … −0.70** |
///
/// **Mean log-probability cannot carry this decision, and the first version of this type was wrong
/// to assume it could.** Calibrated on the near-field rows alone, a threshold of −0.40 looked like it
/// sat in a clean gap. It does not: real far-field speech — the scenario Finding 4 identifies as the
/// one that matters — occupies −0.41 … −0.70, which overlaps the filler range almost entirely. At
/// −0.40 the gate threw away a *correct* transcription of `ami-meeting-far`'s opening minutes:
///
/// > Well, this is the kickoff meeting for our project. And this is just what we're going to be
/// > doing over the next 25 minutes.
///
/// A gate that eats real speech is worse than the hallucination it was built to stop, because the
/// reader has no way to know what was lost. So the log-probability rule is demoted to a backstop set
/// *below the worst real speech measured*, where it can only catch gross decoder failure, and the
/// work is done by ``artefact`` — which caught every hallucination actually observed and fired on
/// none of the real far-field speech.
///
/// `noSpeechProb` is not a discriminator here, and the reason is sharper than "the model does not
/// report it". WhisperKit **hardcodes it to zero** — `TextDecoder.swift:821` reads
/// `let noSpeechProb: Float = 0 // TODO: implement no speech prob`. So the value is a stub, not an
/// observation, and WhisperKit's own silence check is not merely unreliable on this input but
/// unreachable: `SegmentSeeker`'s `shouldSkip` can never become true, and the `DecodingFallback`
/// silence branch is dead code. The rule below is therefore inert under WhisperKit and is kept only
/// so the gate stays honest about the evidence it is given.
public struct SpeechGate: Sendable {

    public var isEnabled: Bool

    /// Above this, the decoder's own no-speech probability is taken as final.
    public var noSpeechProbabilityThreshold: Float

    /// Below this mean log-probability, the decoder is taken to have failed outright. Set below the
    /// worst real speech measured (−0.70, far field) rather than between speech and filler, because
    /// those two distributions overlap and no threshold separates them.
    public var minimumAverageLogProbability: Float

    public init(
        isEnabled: Bool = true,
        noSpeechProbabilityThreshold: Float = 0.6,
        minimumAverageLogProbability: Float = -0.80
    ) {
        self.isEnabled = isEnabled
        self.noSpeechProbabilityThreshold = noSpeechProbabilityThreshold
        self.minimumAverageLogProbability = minimumAverageLogProbability
    }

    /// A gate that lets everything through. For measuring what the ungated decoder does.
    public static let open = SpeechGate(isEnabled: false)

    public func verdict(text: String, quality: DecodeQuality?) -> SpeechGateVerdict {
        guard isEnabled else { return .speech }
        if Self.isArtefact(text) { return .artefact }
        guard let quality else { return .speech }
        if quality.noSpeechProbability > noSpeechProbabilityThreshold { return .noSpeech }
        if quality.averageLogProbability < minimumAverageLogProbability { return .lowConfidence }
        return .speech
    }

    public func admits(text: String, quality: DecodeQuality?) -> Bool {
        verdict(text: text, quality: quality) == .speech
    }

    /// True when the entire utterance is one bracketed annotation rather than words.
    ///
    /// This is structural, not a list of known strings — a list is a losing game, since the next model
    /// invents a new one. Empty text counts: there is nothing to show either way.
    ///
    /// A sentence that merely *opens* with a bracketed aside is speech and is not matched, because the
    /// closing bracket is not the final character: `[laughs] I don't think so` is kept.
    public static func isArtefact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else {
            return true
        }
        let closers: [Character: Character] = ["[": "]", "(": ")", "*": "*", "<": ">"]
        guard let closer = closers[first], closer == last else { return false }
        // A second closer inside means the brackets wrap a clause, not the whole utterance.
        return !trimmed.dropFirst().dropLast().contains(closer)
    }
}
