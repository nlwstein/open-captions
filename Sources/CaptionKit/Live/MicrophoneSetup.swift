import Foundation

/// The phone's own processing chain, which is iOS's audio session mode.
///
/// The raw values of the first three are what settings files already hold.
public enum MicrophoneProcessing: String, CaseIterable, Codable, Sendable {
    /// `.measurement`: no automatic gain, no noise suppression. The closest thing on a phone to
    /// what the MacBook's microphone delivered when the engine was judged to work well, and
    /// `AutomaticGain` already does the one thing the system's chain would have done for us.
    case none
    /// `.default`: whatever the system applies to a recording app.
    case standard
    /// `.videoRecording`: what the Camera app records with. Tuned for the scene in front of the
    /// phone rather than for one voice next to it, which is the far-field case.
    case videoRecording
    /// `.voiceChat`: echo cancellation and voice isolation, as on a phone call. Built for one
    /// talker close to the phone, so it may suppress the other people at the table — which is
    /// the case this app exists for. Offered so that can be measured rather than assumed.
    case voiceIsolation
    /// `.videoChat`: the same voice processing, tuned for a phone held at arm's length. Like
    /// `voiceIsolation`, it follows the Mic Mode chosen in Control Center (Standard, Voice
    /// Isolation or Wide Spectrum).
    case videoChat

    public var displayName: String {
        switch self {
        case .none: return "None (measurement)"
        case .standard: return "Standard"
        case .videoRecording: return "Video recording"
        case .voiceIsolation: return "Voice chat"
        case .videoChat: return "Video chat"
        }
    }

    /// Whether iOS's voice processing is on, which is what makes Control Center's Mic Mode apply.
    public var usesVoiceProcessing: Bool { self == .voiceIsolation || self == .videoChat }
}

/// Everything about how the phone's microphone is opened.
///
/// Each part maps to one thing iOS lets an app choose. Which ones help far-off voices is not known
/// yet, and is what the microphone test in settings is for.
public struct MicrophoneSetup: Codable, Equatable, Hashable, Sendable {

    /// Which of the phone's built-in microphones. iPhones have one on the bottom edge, one at the
    /// front by the earpiece and one on the back by the cameras.
    public enum Microphone: String, CaseIterable, Codable, Sendable {
        case automatic, bottom, front, back

        public var displayName: String {
            switch self {
            case .automatic: return "Automatic"
            case .bottom: return "Bottom"
            case .front: return "Front (top edge)"
            case .back: return "Back"
            }
        }
    }

    /// The microphone's pickup shape. Not every microphone offers every shape; one it does not
    /// offer is left as iOS chose, and the session's diagnostics say so.
    public enum Pattern: String, CaseIterable, Codable, Sendable {
        case automatic, omnidirectional, cardioid, subcardioid, stereo

        public var displayName: String {
            switch self {
            case .automatic: return "Automatic"
            case .omnidirectional: return "All around"
            case .cardioid: return "Directional"
            case .subcardioid: return "Slightly directional"
            case .stereo: return "Stereo (mixed to mono)"
            }
        }
    }

    public var processing: MicrophoneProcessing
    public var microphone: Microphone
    public var pattern: Pattern
    /// The phone's own input gain, 0 to 1, where the route allows it to be set. Nil leaves it as
    /// it is.
    public var hardwareGain: Double?

    public init(processing: MicrophoneProcessing = .none, microphone: Microphone = .automatic,
                pattern: Pattern = .automatic, hardwareGain: Double? = nil) {
        self.processing = processing
        self.microphone = microphone
        self.pattern = pattern
        self.hardwareGain = hardwareGain
    }

    /// Short enough for one line of a status display.
    public var label: String {
        var parts = [processing.displayName, microphone.displayName]
        if pattern != .automatic { parts.append(pattern.displayName) }
        if let hardwareGain { parts.append("input \(Int((hardwareGain * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    /// A file name for a recording made with this setup.
    public var slug: String {
        var parts = [processing.rawValue, microphone.rawValue, pattern.rawValue]
        if let hardwareGain { parts.append("gain\(Int((hardwareGain * 100).rounded()))") }
        return parts.joined(separator: "-")
    }

    /// The setups the microphone test tries by default: the one the app shipped with, each of the
    /// system's processing chains, and each microphone on its own with an all-around pattern.
    public static let testDefaults: [MicrophoneSetup] = [
        .init(),
        .init(processing: .standard),
        .init(processing: .videoRecording),
        .init(processing: .videoRecording, microphone: .back),
        .init(processing: .voiceIsolation),
        .init(processing: .videoChat),
        .init(microphone: .bottom, pattern: .omnidirectional),
        .init(microphone: .front, pattern: .omnidirectional),
        .init(microphone: .back, pattern: .omnidirectional),
        .init(microphone: .front, pattern: .cardioid),
        .init(microphone: .bottom, pattern: .stereo),
    ]
}
