import CaptionKit
import Foundation
import Observation

/// Everything a supporter can change. Simple mode hides all of it from the reader.
public struct AppSettings: Codable, Equatable, Sendable {

    public enum Theme: String, CaseIterable, Codable, Sendable {
        case system, light, dark
        /// Black on white and white on black, with no tinted backgrounds and heavier text.
        case highContrastLight, highContrastDark
    }

    public enum Typeface: String, CaseIterable, Codable, Sendable {
        case standard, rounded, serif
    }

    /// One screen, one big button, settings behind a long press. On by default: the person this
    /// is for should never land anywhere else by accident.
    public var simpleMode = true

    /// Caption size in points before Dynamic Type scales it. 34 is Large Title; the floor the
    /// reader is unlikely to need to go below.
    public var textSize: Double = 34
    public var typeface: Typeface = .standard
    public var boldText = false
    /// Extra space between lines, as a fraction of the text size.
    public var lineSpacing: Double = 0.3
    public var theme: Theme = .system

    /// A coloured bar and a name above each change of speaker.
    public var showSpeakers = true

    public var engine: EngineChoice = .nemotron
    public var microphone: MicrophoneProcessing = .none
    public var micSource: MicrophoneSetup.Microphone = .automatic
    public var micPattern: MicrophoneSetup.Pattern = .automatic
    /// The phone's own input gain, 0 to 1; nil leaves it as iOS set it.
    public var hardwareGain: Double?
    public var automaticGain = true
    public var maxGainDb: Double = 32
    public var targetSpeechDb: Double = -25
    /// A level meter and the microphone setup on the caption screen, for testing.
    public var showMicrophoneMeter = false

    /// Days to keep transcripts; 0 keeps them until deleted.
    public var keepDays = 0
    public var keepScreenAwake = true

    /// Asked for before settings open, when set. Not a security boundary — it stops an accidental
    /// change, which is the failure that matters here.
    public var supporterPIN = ""

    /// In simple mode, whether the captions can be scrolled back while listening. Off keeps the
    /// newest words in place, for a reader who would scroll by accident and not find the way back;
    /// once listening stops, scrolling works either way.
    public var scrollBackWhileListening = true

    /// The first-run screens have been through: models downloaded, microphone asked for.
    public var setupDone = false

    public init() {}

    // Decoded field by field with defaults, so a settings file written by an older build still
    // loads after a field is added. Synthesised decoding would throw and reset everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        simpleMode = (try? c.decode(Bool.self, forKey: .simpleMode)) ?? d.simpleMode
        textSize = (try? c.decode(Double.self, forKey: .textSize)) ?? d.textSize
        typeface = (try? c.decode(Typeface.self, forKey: .typeface)) ?? d.typeface
        boldText = (try? c.decode(Bool.self, forKey: .boldText)) ?? d.boldText
        lineSpacing = (try? c.decode(Double.self, forKey: .lineSpacing)) ?? d.lineSpacing
        theme = (try? c.decode(Theme.self, forKey: .theme)) ?? d.theme
        showSpeakers = (try? c.decode(Bool.self, forKey: .showSpeakers)) ?? d.showSpeakers
        engine = (try? c.decode(EngineChoice.self, forKey: .engine)) ?? d.engine
        microphone = (try? c.decode(MicrophoneProcessing.self, forKey: .microphone)) ?? d.microphone
        micSource = (try? c.decode(MicrophoneSetup.Microphone.self, forKey: .micSource)) ?? d.micSource
        micPattern = (try? c.decode(MicrophoneSetup.Pattern.self, forKey: .micPattern)) ?? d.micPattern
        hardwareGain = try? c.decodeIfPresent(Double.self, forKey: .hardwareGain)
        automaticGain = (try? c.decode(Bool.self, forKey: .automaticGain)) ?? d.automaticGain
        maxGainDb = (try? c.decode(Double.self, forKey: .maxGainDb)) ?? d.maxGainDb
        targetSpeechDb = (try? c.decode(Double.self, forKey: .targetSpeechDb)) ?? d.targetSpeechDb
        showMicrophoneMeter = (try? c.decode(Bool.self, forKey: .showMicrophoneMeter))
            ?? d.showMicrophoneMeter
        keepDays = (try? c.decode(Int.self, forKey: .keepDays)) ?? d.keepDays
        keepScreenAwake = (try? c.decode(Bool.self, forKey: .keepScreenAwake)) ?? d.keepScreenAwake
        supporterPIN = (try? c.decode(String.self, forKey: .supporterPIN)) ?? d.supporterPIN
        setupDone = (try? c.decode(Bool.self, forKey: .setupDone)) ?? d.setupDone
        scrollBackWhileListening = (try? c.decode(Bool.self, forKey: .scrollBackWhileListening))
            ?? d.scrollBackWhileListening
    }

    /// How the microphone is opened, from the four settings above.
    public var microphoneSetup: MicrophoneSetup {
        get {
            MicrophoneSetup(processing: microphone, microphone: micSource, pattern: micPattern,
                            hardwareGain: hardwareGain)
        }
        set {
            microphone = newValue.processing
            micSource = newValue.microphone
            micPattern = newValue.pattern
            hardwareGain = newValue.hardwareGain
        }
    }

    public var gain: GainTuning {
        get { GainTuning(automatic: automaticGain, maxGainDb: maxGainDb, targetSpeechDb: targetSpeechDb) }
        set {
            automaticGain = newValue.automatic
            maxGainDb = newValue.maxGainDb
            targetSpeechDb = newValue.targetSpeechDb
        }
    }

    /// Text sizes offered by the slider, in points.
    public static let textSizeRange: ClosedRange<Double> = 24...96
}

/// Settings, persisted to UserDefaults as one JSON value on every change.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet { if settings != oldValue { save() } }
    }

    private let defaults: UserDefaults
    private static let key = "settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = AppSettings()
        }
    }

    public func reset() {
        settings = AppSettings()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
