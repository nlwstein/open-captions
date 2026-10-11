import Foundation

/// Launch arguments, for driving the app from a script. See `Scripts/sim.sh`.
///
/// None of these are visible to a person using the app; they exist so that every screen can be
/// reached, and every session run, without anyone tapping or talking:
///
///     -replay <path>        play a saved transcript or harness dump; no models are loaded
///     -audio-file <path>    run the real engine on a recording instead of the microphone
///     -speed <x>            wall-clock multiplier for either of the above
///     -max-seconds <n>      stop the session after this much audio
///     -autostart            start a session as soon as the app is ready
///     -reset                forget settings and delete every transcript first
///     -screen <name>        open on live | history | settings | latest (newest transcript)
///     -simple <0|1>  -text-size <pt>  -theme <name>  -engine <name>   override a setting
///     -orientation <portrait|landscape>   rotate the window
///     -setup <0|1>          show the first-run screens, or skip them. Default: show them until
///                           finished once, except with -autostart
///     -fake-download <s>    with -replay: act out a first-run download taking this long
///     -fake-download-fail   ...and drop the connection partway through
public struct LaunchOptions: Equatable, Sendable {
    public enum Screen: String, Sendable { case live, history, settings, latest }

    public var replay: URL?
    public var audioFile: URL?
    public var speed: Double = 1
    public var maxSeconds: Double?
    public var autostart = false
    public var reset = false
    public var screen: Screen?
    public var simpleMode: Bool?
    public var textSize: Double?
    public var theme: AppSettings.Theme?
    public var engine: EngineChoice?
    /// Rotate the window on launch. The simulator has no command-line way to rotate.
    public var landscape: Bool?
    public var setup: Bool?
    public var fakeDownload: Double?
    public var fakeDownloadFails = false

    public init() {}

    public init(arguments: [String]) {
        var index = arguments.startIndex
        func value() -> String? {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { return nil }
            index = next
            return arguments[next]
        }
        while index < arguments.endIndex {
            switch arguments[index] {
            case "-replay": replay = value().map { URL(fileURLWithPath: $0) }
            case "-audio-file": audioFile = value().map { URL(fileURLWithPath: $0) }
            case "-speed": speed = value().flatMap(Double.init) ?? speed
            case "-max-seconds": maxSeconds = value().flatMap(Double.init)
            case "-autostart": autostart = true
            case "-reset": reset = true
            case "-screen": screen = value().flatMap(Screen.init(rawValue:))
            case "-simple": simpleMode = value().map { $0 == "1" || $0 == "true" }
            case "-text-size": textSize = value().flatMap(Double.init)
            case "-theme": theme = value().flatMap(AppSettings.Theme.init(rawValue:))
            case "-engine": engine = value().flatMap(EngineChoice.init(rawValue:))
            case "-orientation": landscape = value().map { $0 == "landscape" }
            case "-setup": setup = value().map { $0 == "1" || $0 == "true" }
            case "-fake-download": fakeDownload = value().flatMap(Double.init)
            case "-fake-download-fail": fakeDownloadFails = true
            default: break
            }
            index = arguments.index(after: index)
        }
    }

    public static var current: LaunchOptions { LaunchOptions(arguments: ProcessInfo.processInfo.arguments) }

    /// Whether to open on the first-run screens, given whether they have been finished before.
    /// A scripted session skips them unless asked, so `-autostart` still starts.
    public func showsSetup(setupDone: Bool) -> Bool {
        setup ?? (!setupDone && !autostart)
    }

    /// Applies the setting overrides; the rest are read by whoever needs them.
    public func apply(to settings: inout AppSettings) {
        if let simpleMode { settings.simpleMode = simpleMode }
        if let textSize { settings.textSize = textSize }
        if let theme { settings.theme = theme }
        if let engine { settings.engine = engine }
    }
}
