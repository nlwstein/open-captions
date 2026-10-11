import CaptionKit
import CaptionSession
import Foundation
import Observation
import UIKit

/// The app's state: settings, saved transcripts, and the session on screen.
@MainActor
@Observable
final class AppModel {
    let launch: LaunchOptions
    let settingsStore: SettingsStore
    let store: TranscriptStore
    private(set) var live: LiveConversation!

    /// Saved conversations, newest first. Refreshed when a session ends or one is deleted.
    private(set) var history: [SavedSession] = []

    /// Navigation for the main window, so a launch argument can open any screen.
    var path: [Route] = []
    var showingSettings = false
    /// The first-run screens: download the models, ask for the microphone.
    private(set) var showingSetup = false
    private let fakeDownload = FakeDownloadState()

    /// Launch arguments act once, even if a second scene (Assistive Access) asks again.
    private var launched = false

    enum Route: Hashable {
        case history
        case transcript(UUID)
        /// Reached from settings in use; routes too so a launch argument can open them.
        case changelog
        case dedication
    }

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        settingsStore = SettingsStore()
        store = TranscriptStore.standard()

        if launch.reset {
            settingsStore.reset()
            store.deleteAll()
        }
        launch.apply(to: &settingsStore.settings)
        showingSetup = launch.showsSetup(setupDone: settingsStore.settings.setupDone)
        fakeDownload.failuresLeft = launch.fakeDownloadFails ? 1 : 0

        live = LiveConversation(store: store, formatter: .bundled()) { [unowned self] in self.configuration() }
        if settings.keepDays > 0 { store.prune(olderThanDays: settings.keepDays) }
        reloadHistory()
    }

    /// What the next session runs with: a replay if the launch asked for one, otherwise the
    /// engine from settings, listening to the microphone or to a recording.
    private func configuration() -> LiveConversation.Configuration {
        let launch = self.launch
        if let replay = launch.replay {
            let script = (try? ReplayScript.load(replay)) ?? ReplayScript(turns: [])
            let fake = launch.fakeDownload.map { seconds in (seconds, fakeDownload) }
            return .init(engineKey: "replay:\(replay.path)", engineName: "replay",
                         makeEngine: {
                             ReplayEngine(script: script, download: fake.flatMap { seconds, state in
                                 state.next(seconds: seconds)
                             })
                         },
                         makeSource: {
                             ClockAudioSource(speed: launch.speed,
                                              limitSeconds: launch.maxSeconds ?? script.duration + 1)
                         })
        }
        let engine = settings.engine
        let microphone = settings.microphone
        return .init(engineKey: engine.rawValue, engineName: engine.displayName,
                     makeEngine: { engine.makeEngine() },
                     makeSource: {
                         if let file = launch.audioFile {
                             return FileAudioSource(url: file, speed: launch.speed,
                                                    limitSeconds: launch.maxSeconds)
                         }
                         return PhoneMicrophoneSource(processing: microphone)
                     })
    }

    /// Runs once the first window is up.
    func onLaunch() async {
        guard !launched else { return }
        launched = true
        if let landscape = launch.landscape,
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
        }
        switch launch.screen {
        case .history: path = [.history]
        case .latest: if let id = history.first?.id { path = [.history, .transcript(id)] }
        case .settings: showingSettings = true
        case .changelog: path = [.changelog]
        case .dedication: path = [.dedication]
        case .live, nil: break
        }
        if launch.autostart {
            await start()
        } else if !showingSetup {
            // Not during setup: there, the download waits until someone says yes to it.
            await live.warmUp()
        }
    }

    /// Whether the models the settings call for are already on the phone.
    var modelsDownloaded: Bool {
        if launch.replay != nil { return launch.fakeDownload == nil || fakeDownload.done }
        return ModelCache.isDownloaded(settings.engine.variant)
    }

    /// Roughly how much the first download is, for telling people before it starts.
    var downloadSize: String {
        let sizes = ModelCache.downloadMegabytes(for: settings.engine.variant)
        // One decimal place: "1.1 GB" reads as an estimate, "1.06 GB" as a promise.
        let gigabytes = Double(sizes.recogniser + sizes.diarizer) / 1000
        return gigabytes.formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    /// Loads the engine settings now call for, so a change of model downloads while someone is
    /// looking rather than when they next press Start.
    func settingsClosed() {
        guard !live.isRunning else { return }
        Task { await live.warmUp() }
    }

    func finishSetup() {
        settings.setupDone = true
        showingSetup = false
        Task { await live.warmUp() }
    }

    func start() async {
        await live.start()
        reloadHistory()
    }

    func stop() async {
        await live.stop()
    }

    func toggle() {
        Task {
            if live.isRunning { await stop() } else { await start() }
        }
    }

    func reloadHistory() {
        history = store.all()
    }

    func session(_ id: UUID) -> SavedSession? {
        if live.session?.id == id, let session = live.session { return session }
        return history.first { $0.id == id }
    }

    func rename(speaker: Int, to name: String, in id: UUID) {
        if live.session?.id == id {
            live.rename(speaker: speaker, to: name)
        } else if var session = store.load(id) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            session.names[speaker] = trimmed.isEmpty ? nil : trimmed
            try? store.save(session)
        }
        reloadHistory()
    }

    func delete(_ id: UUID) {
        store.delete(id)
        path.removeAll { $0 == .transcript(id) }
        reloadHistory()
    }

    func deleteAll() {
        store.deleteAll()
        reloadHistory()
    }

    /// Keeps the screen on while captioning, if the settings ask for it, and always while the
    /// models are being prepared: a phone that locks part-way leaves the next person waiting again.
    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = (settings.keepScreenAwake && live.isRunning)
            || live.phase == .preparing
    }

    // MARK: - First use

    /// Whether getting ready now means preparing the models for this phone's Neural Engine, which
    /// takes about 20 seconds on an iPhone 15 Pro Max rather than under one. iOS throws away what it
    /// prepared whenever the app is installed again, the system is updated, or a different model
    /// is picked, so all three are in the key. The bundle path changes with every install, even of
    /// the same build.
    var firstUse: Bool { preparedFor != preparationKey }

    private var preparedFor = UserDefaults.standard.string(forKey: AppModel.preparedKey)
    private static let preparedKey = "modelsPreparedFor"

    private var preparationKey: String {
        [Bundle.main.bundleURL.path, ProcessInfo.processInfo.operatingSystemVersionString,
         settings.engine.rawValue].joined(separator: "|")
    }

    /// Called once the engine is loaded, so the next launch knows it will be quick.
    func modelsPrepared() {
        guard live.isWarm, firstUse else { return }
        preparedFor = preparationKey
        UserDefaults.standard.set(preparedFor, forKey: Self.preparedKey)
    }
}


/// A `-fake-download` that fails the first time if asked to, then succeeds, then is not needed
/// again — the way a real one goes when the connection drops once.
private final class FakeDownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failuresLeft = 0
    private var _done = false

    var failuresLeft: Int {
        get { lock.withLock { _failuresLeft } }
        set { lock.withLock { _failuresLeft = newValue } }
    }

    var done: Bool { lock.withLock { _done } }

    /// The download the next engine acts out, or nil once one has finished.
    func next(seconds: Double) -> ReplayEngine.SimulatedDownload? {
        lock.withLock {
            if _done { return nil }
            if _failuresLeft > 0 {
                _failuresLeft -= 1
                return .init(seconds: seconds, fails: true)
            }
            _done = true
            return .init(seconds: seconds)
        }
    }
}
