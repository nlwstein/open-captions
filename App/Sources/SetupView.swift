import AVFAudio
import CaptionKit
import CaptionSession
import Network
import SwiftUI

/// The first thing anyone sees: what the app does, the one-time download, the microphone.
///
/// Most likely gone through by whoever is setting the phone up rather than the person who will
/// read the captions, but written so either can follow it. One thing per screen, one button to
/// press, nothing that happens without being asked — the download in particular, which is a
/// gigabyte and should not start on someone's mobile data because the app was opened.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.captionStyle) private var style
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var step: Step = .welcome
    @State private var network = NetworkWatch()
    @State private var microphone = AVAudioApplication.shared.recordPermission

    enum Step { case welcome, downloading, microphone, ready }

    private var live: LiveConversation { model.live }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    content
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .foregroundStyle(style.text)
            // Centred when it fits; from the top when it does not, so the first words are seen.
            .defaultScrollAnchor(.center, for: .alignment)
            .defaultScrollAnchor(.top, for: .initialOffset)
            buttons
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: 640)
        }
        .fontDesign(style.design)
        // Past this, each screen holds a handful of words and the steps stop reading as steps.
        // The caption text itself has its own limit, in CaptionStyle.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .background(style.background.ignoresSafeArea())
        .onAppear(perform: skipWhatIsDone)
        .onDisappear { model.updateIdleTimer() }
        // Back from Settings with the microphone switched on: carry on without another tap.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, step == .microphone else { return }
            microphone = AVAudioApplication.shared.recordPermission
            if microphone == .granted { step = .ready }
        }
        .onChange(of: step) { _, new in
            // A download left alone long enough for the screen to lock is a download that stops.
            UIApplication.shared.isIdleTimerDisabled = new == .downloading
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .downloading: downloading
        case .microphone: microphoneStep
        case .ready: ready
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            symbol("captions.bubble.fill", color: .accentColor)
            title("Captions")
            paragraph("Shows what people say as large text, so you can read along.")
            card {
                paragraph("First, Captions needs to download its speech models: about \(model.downloadSize), once.",
                     emphasised: true)
                paragraph("After that it works without the internet. Nothing anyone says ever leaves this phone.")
            }
            if network.offline {
                warning("This phone is not connected to the internet. Connect to Wi-Fi to download.")
            } else if network.expensive {
                warning("This phone is using mobile data. Use Wi-Fi if you can.")
            }
            if let free = freeSpace, free < neededSpace {
                warning("This phone needs about \(format(neededSpace)) free, and has \(format(free)). Free up some space first.")
            }
        }
    }

    private var downloading: some View {
        VStack(spacing: 24) {
            if case .failed(let message) = live.phase {
                symbol("wifi.exclamationmark", color: .orange)
                title("The download stopped")
                // The title already says it stopped.
                paragraph(message.replacingOccurrences(of: "The download stopped. ", with: ""))
                paragraph("Whatever was downloaded is kept; trying again carries on from there.")
            } else {
                let progress = live.progress
                let loading = progress?.step == .loading || progress?.step == .ready
                title(loading ? "Getting the speech models ready" : "Downloading speech models")
                ProgressView(value: progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 3, anchor: .center)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("setupProgress")
                Text("\(progress?.percent ?? 0)%")
                    .font(.system(size: 56, weight: .bold, design: style.design).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("setupPercent")
                paragraph(loading
                     ? "Almost done. This can take a minute the first time."
                     : "Keep Captions open until this finishes. It can take several minutes.")
                textSizeChooser
            }
        }
    }

    /// Something to do while waiting, and the setting that matters most.
    private var textSizeChooser: some View {
        @Bindable var store = model.settingsStore
        let range = AppSettings.textSizeRange
        return card {
            paragraph("While you wait, choose how big the captions should be.", emphasised: true)
            Text("This is how captions will look.")
                .font(style.captionFont())
                .lineSpacing(style.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("setupTextSample")
            HStack(spacing: 16) {
                sizeButton("Smaller", systemImage: "textformat.size.smaller") {
                    store.settings.textSize = max(store.settings.textSize - 6, range.lowerBound)
                }
                .disabled(store.settings.textSize <= range.lowerBound)
                sizeButton("Bigger", systemImage: "textformat.size.larger") {
                    store.settings.textSize = min(store.settings.textSize + 6, range.upperBound)
                }
                .disabled(store.settings.textSize >= range.upperBound)
            }
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 24) {
            symbol(microphone == .denied ? "mic.slash.circle.fill" : "mic.circle.fill",
                   color: microphone == .denied ? .orange : .accentColor)
            title(microphone == .denied ? "The microphone is off" : "Captions needs the microphone")
            if microphone == .denied {
                paragraph("To turn it on: open Settings, tap Apps, then Captions, and switch on Microphone.")
            } else {
                paragraph("Captions listens through the microphone and turns speech into text, here on this phone.")
                paragraph("The sound itself is never recorded or sent anywhere. Only the words are kept, so you can read them again later.")
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 24) {
            symbol("checkmark.circle.fill", color: .green)
            title("Ready")
            paragraph("Press Start when people begin talking, and their words will appear on the screen.")
            card {
                paragraph("For whoever looks after this phone: to change settings later, hold a finger on the top of the screen for two seconds.")
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 12) {
            switch step {
            case .welcome:
                primary("Download") { startDownload() }
                    .disabled(network.offline)
            case .downloading:
                if case .failed = live.phase {
                    primary("Try again") { startDownload() }
                }
            case .microphone:
                if microphone == .denied {
                    primary("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    secondary("Continue") { step = .ready }
                } else {
                    primary("Allow the microphone") { askForMicrophone() }
                }
            case .ready:
                primary("Start using Captions") { model.finishSetup() }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: min(style.captionSize * 0.8, 34), weight: .bold, design: style.design))
                .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 24))
        .accessibilityIdentifier("setupPrimary")
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .accessibilityIdentifier("setupSecondary")
    }

    private func sizeButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    // MARK: - Flow

    /// Skips a step that has nothing to ask: models already here, microphone already allowed.
    private func skipWhatIsDone() {
        if step == .welcome, model.modelsDownloaded { step = .microphone }
        if step == .microphone, microphone == .granted { step = .ready }
    }

    private func startDownload() {
        step = .downloading
        Task {
            await live.warmUp()
            guard live.isWarm else { return }
            step = .microphone
            skipWhatIsDone()
        }
    }

    private func askForMicrophone() {
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            microphone = AVAudioApplication.shared.recordPermission
            if microphone == .granted { step = .ready }
        }
    }

    // MARK: - Space

    private var neededSpace: Int64 {
        let sizes = ModelCache.downloadMegabytes(for: model.settings.engine.variant)
        // Room to unpack, and to spare: a phone filled to the brim misbehaves in other ways.
        return Int64(sizes.recogniser + sizes.diarizer) * 1_500_000
    }

    private var freeSpace: Int64? {
        try? URL.homeDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Pieces

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 72))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.largeTitle.weight(.bold))
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("setupTitle")
    }

    private func paragraph(_ text: String, emphasised: Bool = false) -> some View {
        Text(text)
            .font(emphasised ? .title3.weight(.semibold) : .title3)
            .lineSpacing(4)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 16) { content() }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(style.secondaryText.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("setupWarning")
    }
}

/// Whether the phone is online, and whether the connection costs money.
@MainActor
@Observable
final class NetworkWatch {
    private(set) var offline = false
    private(set) var expensive = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.offline = path.status != .satisfied
                self?.expensive = path.isExpensive
            }
        }
        monitor.start(queue: .main)
    }

    deinit {
        monitor.cancel()
    }
}
