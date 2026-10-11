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
    /// Launch arguments act once, even if a second scene (Assistive Access) asks again.
    private var launched = false

    enum Route: Hashable {
        case history
        case transcript(UUID)
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

        live = LiveConversation(store: store) { [unowned self] in self.configuration() }
        if settings.keepDays > 0 { store.prune(olderThanDays: settings.keepDays) }
        reloadHistory()
    }

    /// What the next session runs with: a replay if the launch asked for one, otherwise the
    /// engine from settings, listening to the microphone or to a recording.
    private func configuration() -> LiveConversation.Configuration {
        let launch = self.launch
        if let replay = launch.replay {
            let script = (try? ReplayScript.load(replay)) ?? ReplayScript(turns: [])
            return .init(engineKey: "replay:\(replay.path)", engineName: "replay",
                         makeEngine: { ReplayEngine(script: script) },
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
        case .live, nil: break
        }
        if launch.autostart {
            await start()
        } else {
            await live.warmUp()
        }
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

    /// Keeps the screen on while captioning, if the settings ask for it.
    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && live.isRunning
    }
}
