import Foundation

/// Brings speech up to the level the recogniser was trained on, without a fixed multiplier.
///
/// Both recognisers here are level-sensitive and neither normalises: FluidAudio's mel front end is
/// `normalize: "NA"` and its `logValue` is a plain `log(value + 2^-24)`, so whatever amplitude
/// arrives is the amplitude the model sees. Measured on DiPCo's far-field channel: **nineteen points
/// of WER** separate Nemotron fed that audio raw (63.2%) from the same audio gained to a normal
/// level (44.3%). WhisperKit — the strongest engine on the fixture set — scores 61.9% WER on the
/// same window raw, having won every synthetic fixture with 17.9% mean. The level is not a detail.
///
/// A fixed multiplier cannot be the answer, because the same +33 dB that rescued DiPCo made
/// `ami-meeting-far` *worse* (23.5% → 26.1%): that clip is already usable, so the boost only lifted
/// its noise floor along with the speech. What both results ask for is a stage that finds the speech
/// and moves *that* to a target, leaving everything else alone.
///
/// ## Aiming the level rather than detecting speech
///
/// The obvious design is a voice-activity gate: detect speech frames, measure their level, gain
/// toward a target. It does not work on this audio, and the reason is worth recording. DiPCo's
/// far-field channel spans only **−67 to −50 dBFS across a full thirty minutes** — speech sits about
/// 13 dB above the room, and everything is 30 dB below a normal recording. A gate keyed to an
/// absolute threshold calls the entire file silence; a gate keyed to a relative one has to pick a
/// margin, and with the loudest 1% of frames only 15 dB above the floor, any margin wide enough to
/// exclude room tone also excludes most of the speech.
///
/// So this does not try to find speech frames at all. It tracks a **percentile of frame levels** and
/// aims that at the target:
///
///     gain = target − p90(frame levels over the last 20 s)
///
/// A percentile is used for the same reason ``AudioLevelMeter`` uses one for its floor: a single
/// anomalously loud or quiet frame cannot move it. On a well-leveled recording the 90th percentile
/// *is* the speech, so the gain comes out near zero and the audio passes through. On DiPCo it is
/// −58.1 dBFS, so the rule asks for +32.1 dB — and the sweep that tuned a fixed gain by hand landed
/// on +33 dB. The constant is not tuned here; it falls out of the audio.
///
/// That self-check is the reason to trust the design, so it is worth stating plainly: run the rule
/// on the raw DiPCo window and it asks for **+32 dB**; run it on the same audio already boosted by
/// 33 dB and it asks for **0.00 dB**. A fixed multiplier cannot produce both answers.
///
/// ## Two guards, because the obvious single one is not enough
///
/// `gain = target − p90` would happily amplify a silent room, because a silent room has a
/// percentile too. The first guard against that is the **spread** between the 90th and 10th
/// percentile of the same window: speech modulates, stationary noise does not. Measured:
///
/// | signal | p90 − p10 |
/// |---|---|
/// | hum plus hiss, synthetic | 0.01 dB |
/// | stationary white noise, synthetic | 0.37 dB |
/// | **real room tone, recorded** | **3.15 dB** |
/// | real conversational speech (quietest 20 s of a 30-minute corpus) | 4.49 dB |
/// | drifting room rumble, synthetic | 8.97 dB |
///
/// Read the third row before trusting this guard, because it was measured last and it changed what
/// this component claims to do. It is a genuine recording of a quiet room rather than a synthetic
/// one, and it **crosses ``minimumSpreadDb``**: a real room with nobody in it varies more than white
/// noise does, because rooms contain chairs and distant traffic and people breathing. The guard
/// therefore does not do what its name suggests. It separates *stationary* noise — a fan, a hum, a
/// hiss — from everything else, and it does **not** separate silence from speech. On real room tone
/// it does not fire at all: 96 seconds of it is tracked as though something were being said, and the
/// rule aims it at the target, asking **21.4 dB**.
///
/// The gate is left where it is because the alternative was measured and is worse. Raising
/// ``minimumSpreadDb`` to 5 dB would exclude that room tone, and the margin it has to work in is
/// **1.34 dB** — 3.15 against the quietest real speech window's 4.49. That is the entire gap
/// available, and 5 dB does not sit cleanly inside it: a twentieth of DiPCo's own ninety
/// twenty-second windows already fall below 5 dB, so a gate wide enough to exclude an empty room
/// starts closing on real speech, and its cost would land on the audio this component exists to
/// rescue. What makes that trade acceptable is that the
/// thing the gate fails to prevent turns out not to matter: see the measurement at the end of this
/// comment.
///
/// The spread alone is not sufficient, and finding out why is the reason this component has two
/// guards rather than one. When speech *stops*, the window's composition changes from mostly-speech
/// to mostly-room, the 90th percentile sinks toward the room, and the rule reads that as a very
/// quiet speaker and starts climbing — in a twenty-second window it gains about 17 dB before the
/// spread finally collapses and freezes it there. The stage would then hold that wrong value until
/// the next sentence arrived, badly too hot. A second guard catches it by asking the sidechain
/// question a hardware AGC asks: **is the recent level even in the same league as the speech we
/// measured?** If the last few seconds sit more than ``activityDropDb`` below the speech estimate,
/// nothing is being said and the estimate is frozen rather than updated.
///
/// ``activityDropDb`` is 20 dB, and the number is a judgement with a stated basis rather than a
/// tuned one. In DiPCo speech sits only 13 dB above the room, so this gate never fires there — which
/// is intended, because on that corpus the room genuinely is close to speech and tracking it is
/// harmless. A room 34 dB below the speech that was just heard is not ambiguous.
///
/// The cost of freezing is that a speaker who arrives more than 20 dB quieter than the last one is
/// initially treated as silence. ``resetAfterSilenceSeconds`` bounds that: once nothing has been
/// trackable for that long, the window is discarded and the stage re-bootstraps on whatever it hears
/// next, so a quiet room cannot leave it locked onto a stale estimate indefinitely.
///
/// In every case the rule can only ever aim *at* the target and never above it, so the worst outcome
/// any of these limits produces is room tone presented to the recogniser at −25 dBFS.
///
/// That outcome is the one the spread gate fails to prevent, so it was measured rather than assumed.
/// Ninety-six seconds of recorded room tone, taken through the stage at its full **21.4 dB**, was
/// transcribed by all three engines this project ships or compares against — Nemotron 0.6B, Parakeet
/// EOU 120M and Parakeet Unified 0.6B — and produced **zero words from all three**, as it does with
/// the stage bypassed. None of them mistakes an amplified empty room for speech. Amplifying a room
/// nobody is talking in therefore wastes power and invents nothing, which makes the gate's weakness
/// an exposure worth documenting rather than a defect worth trading real speech to fix.
///
/// ## Not a compressor
///
/// This is deliberately not `AVAudioUnitDynamicsProcessor`. That reduces dynamic range above a
/// threshold, which is a different job from lifting a quiet signal into a model's operating range,
/// and it has no notion of a speech level to aim at.
///
/// Gain is only ever added, never subtracted: audio that is already loud enough needs nothing, and
/// attenuating it would throw away headroom for no benefit.
public struct AutomaticGain: Sendable {

    /// Speech level the recogniser should be handed, in dBFS. −25 is ordinary for ASR training
    /// audio; the +33 dB run that measured best on DiPCo landed at −24.5, which is where this
    /// default comes from.
    public var targetSpeechDb: Float = -25

    /// Most gain that will ever be applied.
    ///
    /// 32 dB, and on DiPCo this is not a backstop — it is the operating point. The corpus needs
    /// 33.1 dB to reach ``targetSpeechDb``, so the clamp is what decides the level, landing the
    /// speech at −26 dBFS rather than −25.
    ///
    /// Swept at 26, 28, 30, 32, 34 and 40 dB across *both* DiPCo windows, and the result is a
    /// **plateau rather than an optimum**: the whole range spans 0.7 points of pooled WER — ten errors
    /// in 1 579 — with no trend, and with the two windows preferring opposite ends of it. This corpus
    /// does not constrain the constant, and that is a negative result rather than a finding. 32 is
    /// kept because it sits in a band where nothing matters, not because it measured best.
    ///
    /// The sweep did turn up a mechanism, which is why the clamp is worth having even though this
    /// corpus cannot show it. At 40 dB the clamp stops binding — it sits above the 33.1 dB this corpus
    /// asks for — so the stage begins *tracking* rather than resting against its ceiling, and the
    /// character of the applied gain changes completely: measured over a window, the gain at 32 dB
    /// moves by **0.67 dB** and is pinned at exactly 32.00 for its median, while at 40 dB it moves by
    /// **4.87 dB** and slews at 0.1 dB/s. On audio this quiet, the clamp is what turns a tracking stage
    /// into a constant one.
    ///
    /// It is tempting to conclude from that mechanism that tracking costs accuracy. Window 1 says so —
    /// 46.9% against 46.0%, the worst content recall of the sweep — and it would have been wrong:
    /// window 2 gains back the same amount in the other direction and the pooled figures are a tie.
    /// The clamp is load-bearing in principle and inert in practice here. It would start to matter on
    /// audio quieter than DiPCo's −59.7 dBFS mean.
    public var maxGainDb: Float = 32

    /// Audio the level estimate is taken over. Long enough that a sentence does not move it, short
    /// enough that a change of room or of speaker is followed within seconds.
    public var windowSeconds: Double = 20

    /// Audio the "is anything being said" check looks at. Short enough to notice a pause within a
    /// second or two, long enough not to be decided by one sound.
    public var recentSeconds: Double = 3

    /// Frames required before the stage will act at all. With less than a second of audio the
    /// percentile is too easily set by one sound, and a caption reader is better served by a second
    /// of roughly-right level than by a gain that lurches on the first syllable.
    public var minimumFrames: Int = 10

    /// Least spread between the 90th and 10th percentile that counts as something worth tracking.
    /// Chosen from the table above: stationary noise sits at or below 0.4 dB, the quietest window of
    /// real speech measured at 4.49 dB, and real room tone — which this does *not* catch — at 3.15.
    /// See the discussion above on why that gap is too narrow to move the gate into.
    public var minimumSpreadDb: Float = 2

    /// How far the recent level may fall below the speech estimate before the stage concludes that
    /// nothing is being said and holds what it has. See the discussion above on why this exists.
    public var activityDropDb: Float = 20

    /// How long the audio must stay untrackable before the window is thrown away and the stage
    /// re-bootstraps, so that a quiet stretch cannot freeze a stale estimate forever.
    public var resetAfterSilenceSeconds: Double = 30

    /// Frames over which the applied gain moves. Long enough that a changing gain is not heard as
    /// pumping and does not smear the spectrum the model is reading, short enough that the first
    /// seconds of a session are not transcribed at the wrong level.
    public var adaptationSeconds: Double = 0.5

    /// Analysis frame. Fixed in time rather than taken from the caller's chunk size, so that a
    /// source handing over 20 ms buffers and one handing over 1 s buffers produce the same estimate
    /// over the same wall-clock window.
    public var frameSeconds: Double = 0.1

    private static let sampleRate: Double = 16_000

    /// Frame levels over ``windowSeconds``, the basis of the speech estimate.
    private var window: [Float] = []
    /// Frame levels over ``recentSeconds``, for the "is anything being said" check.
    private var recent: [Float] = []
    /// Samples not yet accumulated into a full analysis frame.
    private var pending: [Float] = []

    private var gainDb: Float = 0
    private var framesSeen = 0
    private var untrackedSeconds: Double = 0

    /// The gain currently being applied, for display. Nothing else needs it.
    public var currentGainDb: Float { gainDb }

    /// The speech level the gain was computed from. Exposed so a smoke test can see *why* the stage
    /// chose the gain it did, which a bare dB number cannot explain.
    public var estimatedSpeechDb: Float { Self.percentile(window, 0.9) }

    /// The level of the last few seconds, which is what the activity guard compares against.
    public var recentLevelDb: Float { Self.percentile(recent, 0.9) }

    /// Whether the stage has heard enough to be applying a meaningful gain.
    public var hasSettled: Bool { framesSeen >= minimumFrames }

    /// Whether something is still being said: the last few seconds have to be in the same league as
    /// the speech already measured. True while the stage is still collecting its opening frames,
    /// when there is nothing yet to compare against.
    ///
    /// This is what decides whether a frame is allowed into the speech estimate. It has to be a
    /// condition that ``recent`` alone can reopen, because the estimate it is compared against stops
    /// moving the moment this goes false — a gate that could only be reopened by the estimate
    /// updating would wait forever.
    public var isActive: Bool {
        guard framesSeen >= minimumFrames, !window.isEmpty else { return true }
        return recentLevelDb >= estimatedSpeechDb - activityDropDb
    }

    /// Whether the audio currently looks like something worth acting on: something is being said,
    /// *and* the window varies enough to be speech rather than a steady tone.
    ///
    /// Deliberately separate from ``isActive`` and deliberately narrower. This one controls only
    /// whether the gain may move; a steady tone should not move it, but it must still be allowed to
    /// collect frames, or the stage could never notice speech arriving after it.
    public var isTracking: Bool {
        guard isActive, window.count >= 2 else { return false }
        return Self.percentile(window, 0.9) - Self.percentile(window, 0.1) >= minimumSpreadDb
    }

    public init() {}

    /// Returns `samples` scaled toward the target speech level. Safe to call with any chunk length
    /// and always returns exactly as many samples as it was given.
    public mutating func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        analyse(samples)
        updateGain(sampleCount: samples.count)

        guard gainDb > 0.01 else { return samples }
        let scale = pow(10, gainDb / 20)
        // Clamped rather than soft-kneed: the gain is capped at 32 dB, so a sample reaching full
        // scale here would mean the input was already clipping.
        return samples.map { max(-1, min(1, $0 * scale)) }
    }

    // MARK: - Internals

    /// Accumulates samples into fixed-length frames and records each frame's level. The caller's
    /// chunking is irrelevant to the estimate — a partial frame is carried between calls.
    private mutating func analyse(_ samples: [Float]) {
        let frameSamples = max(1, Int(frameSeconds * Self.sampleRate))
        let windowFrames = max(1, Int(windowSeconds / frameSeconds))
        let recentFrames = max(1, Int(recentSeconds / frameSeconds))

        pending.append(contentsOf: samples)
        while pending.count >= frameSamples {
            let level = AudioLevelMeter.decibels(of: Array(pending[0..<frameSamples]))
            pending.removeFirst(frameSamples)
            framesSeen += 1

            recent.append(level)
            if recent.count > recentFrames {
                recent.removeFirst(recent.count - recentFrames)
            }

            // Appending to the window is the decision to treat this frame as evidence about the
            // speech level, so it is gated on there being something to measure. Gated on `isActive`
            // rather than `isTracking`: a steady tone must not move the gain, but it must still be
            // allowed to fill the window, or speech arriving afterwards could never be noticed.
            if isActive {
                window.append(level)
                if window.count > windowFrames {
                    window.removeFirst(window.count - windowFrames)
                }
                untrackedSeconds = 0
            } else {
                untrackedSeconds += frameSeconds
                if untrackedSeconds >= resetAfterSilenceSeconds {
                    reset()
                }
            }
        }
    }

    private mutating func updateGain(sampleCount: Int) {
        guard isTracking else { return }

        let desired = min(maxGainDb, max(0, targetSpeechDb - estimatedSpeechDb))
        // The coefficient comes from how much audio this call carried, so the gain converges over
        // the same wall-clock time whatever length of audio the caller hands over.
        let seconds = Double(sampleCount) / Self.sampleRate
        let coefficient = Float(1 - exp(-seconds / max(adaptationSeconds, 0.01)))
        gainDb += (desired - gainDb) * coefficient
    }

    /// Throws away the estimate so the stage locks onto whatever it hears next. The gain is left
    /// alone — it has somewhere sensible to be, and re-converging from it is quicker than from zero.
    private mutating func reset() {
        window.removeAll()
        recent.removeAll()
        pending.removeAll()
        framesSeen = 0
        untrackedSeconds = 0
    }

    /// Linear-interpolated percentile of an unsorted array, `q` in 0…1.
    ///
    /// The window is a few hundred entries and this runs ten times a second, so sorting a copy is
    /// cheaper to read than any incremental structure and costs nothing worth measuring.
    static func percentile(_ values: [Float], _ q: Float) -> Float {
        guard !values.isEmpty else { return -120 }
        let sorted = values.sorted()
        let position = q * Float(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Float(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
