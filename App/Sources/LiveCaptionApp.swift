import CaptionSession
import SwiftUI

@main
struct LiveCaptionApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(assistive: false)
                .environment(model)
                .task { await model.onLaunch() }
        }

        // With Assistive Access on, the phone shows this instead: the live screen and past
        // conversations, and no way into settings at all. A supporter changes settings with
        // Assistive Access off.
        AssistiveAccess {
            RootView(assistive: true)
                .environment(model)
                .task { await model.onLaunch() }
        }
    }
}

struct RootView: View {
    let assistive: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            LiveScreen(assistive: assistive)
                .navigationDestination(for: AppModel.Route.self) { route in
                    switch route {
                    case .history:
                        HistoryView(assistive: assistive)
                    case .transcript(let id):
                        TranscriptScreen(id: id, assistive: assistive)
                    }
                }
        }
        .captionTheme(model.settings)
        .sheet(isPresented: assistive ? .constant(false) : $model.showingSettings) {
            SettingsView()
                .environment(model)
                .captionTheme(model.settings)
        }
        .onChange(of: model.live.isRunning) { model.updateIdleTimer() }
        .onChange(of: model.settings.keepScreenAwake) { model.updateIdleTimer() }
    }
}
