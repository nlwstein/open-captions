import CaptionKit
import CaptionSession
import SwiftUI

/// The screen the app opens on, and in simple mode the only one most people will ever see: the
/// conversation as text, and one big button.
struct LiveScreen: View {
    /// Inside Assistive Access: no way into settings, and the system draws the back button.
    let assistive: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.captionStyle) private var style

    @State private var renaming: CaptionLine?
    @State private var newName = ""
    @State private var askingPIN = false
    @State private var enteredPIN = ""
    @State private var pinchStart: Double?

    private var live: LiveConversation { model.live }
    private var simple: Bool { model.settings.simpleMode || assistive }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// A phone on its side: short and wide. Likely the usual way this is used — propped up on a
    /// table between people — and there the bottom button would take a third of the height the
    /// captions need, so the controls move to a column on the right instead.
    private var sideways: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if sideways {
                HStack(spacing: 0) {
                    captions
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        header
                        // Centred in the space under the header, where a thumb finds it from
                        // either side of the phone.
                        Spacer(minLength: 0)
                        controls
                        Spacer(minLength: 0)
                    }
                    .frame(width: 260)
                }
            } else {
                VStack(spacing: 0) {
                    header
                    captions
                        .frame(maxHeight: .infinity)
                    controls
                }
            }
        }
        .background(style.background.ignoresSafeArea())
        .toolbar(simple ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !simple {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.path = [.history] } label: {
                        Label("Past conversations", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("historyToolbarButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
        }
        .navigationTitle("Captions")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Name this speaker", isPresented: renamingBinding) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Save") {
                if let line = renaming, let speaker = line.speaker, let id = live.session?.id {
                    model.rename(speaker: speaker, to: newName, in: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used for this conversation only.")
        }
        .alert("Supporter PIN", isPresented: $askingPIN) {
            SecureField("PIN", text: $enteredPIN)
                .keyboardType(.numberPad)
            Button("Open settings") {
                if enteredPIN == model.settings.supporterPIN { model.showingSettings = true }
                enteredPIN = ""
            }
            Button("Cancel", role: .cancel) { enteredPIN = "" }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            listeningIndicator
            Spacer()
            if !simple {
                Text(statusLine)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(style.secondaryText)
                    .accessibilityIdentifier("engineStatus")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // Simple mode keeps settings out of reach of an accidental tap: a supporter holds the top
        // of the screen for two seconds.
        .onLongPressGesture(minimumDuration: 2) {
            guard simple, !assistive else { return }
            if model.settings.supporterPIN.isEmpty {
                model.showingSettings = true
            } else {
                askingPIN = true
            }
        }
        .accessibilityAction(named: "Open settings") {
            guard !assistive else { return }
            if model.settings.supporterPIN.isEmpty { model.showingSettings = true } else { askingPIN = true }
        }
    }

    @ViewBuilder
    private var listeningIndicator: some View {
        let font = style.captionFont(scale: 0.55).weight(.semibold)
        switch live.phase {
        case .listening:
            Label {
                Text("Listening")
            } icon: {
                Image(systemName: live.status.isSpeaking ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: live.status.isSpeaking)
            }
            .font(font)
            .foregroundStyle(.red)
            .accessibilityIdentifier("listeningIndicator")
        case .finishing:
            Label("Finishing", systemImage: "hourglass").font(font).foregroundStyle(style.secondaryText)
        case .preparing:
            Label(preparingText, systemImage: "hourglass").font(font).foregroundStyle(style.secondaryText)
        case .idle, .failed:
            Text(simple ? "Captions" : "Not listening")
                .font(font)
                .foregroundStyle(style.secondaryText)
        }
    }

    /// "Getting ready", or how far a download has got when there is one.
    private var preparingText: String {
        guard let progress = live.progress, progress.step == .downloading else { return "Getting ready" }
        return "Downloading \(progress.percent)%"
    }

    private var statusLine: String {
        let status = live.status
        guard live.isRunning else { return model.settings.engine.displayName }
        let load = status.processingLoad * 100
        return String(format: "%@ · load %.0f%% · %.0f dB · +%.0f dB",
                      formatClock(status.audioSeconds), load, status.level, status.gainDb)
    }

    // MARK: - Captions

    @ViewBuilder
    private var captions: some View {
        let lines = live.lines
        if case .failed(let message) = live.phase, lines.isEmpty {
            prompt(message, systemImage: "exclamationmark.triangle")
        } else if lines.isEmpty {
            if live.phase == .preparing, live.progress?.step == .downloading {
                prompt("Downloading the speech models. Keep Captions open until this finishes.",
                       systemImage: "arrow.down.circle")
            } else if live.isRunning {
                prompt("Waiting for someone to speak…", systemImage: "ear")
            } else {
                prompt("Press Start, and what people say will appear here.", systemImage: "captions.bubble")
            }
        } else {
            TranscriptView(lines: lines, live: live.isRunning, anchoredToEnd: true,
                           lockedToEnd: simple && live.isRunning && !model.settings.scrollBackWhileListening,
                           showSpeakers: model.settings.showSpeakers,
                           onTapSpeaker: simple ? nil : { line in
                               newName = live.session?.names[line.speaker ?? -1] ?? ""
                               renaming = line
                           })
                .gesture(zoom)
        }
    }

    private func prompt(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(style.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(style.captionFont(scale: 0.8))
                .foregroundStyle(style.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("captionPrompt")
    }

    /// Pinch the captions to change their size; the new size is kept.
    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? model.settings.textSize
                pinchStart = start
                let range = AppSettings.textSizeRange
                model.settings.textSize = min(max(start * value.magnification, range.lowerBound),
                                              range.upperBound).rounded()
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            mainButton
            if !live.isRunning, !model.history.isEmpty, simple {
                Button { model.path = [.history] } label: {
                    // In the narrow landscape column the words wrap; with the icon above them they
                    // wrap as one centred block instead of hanging beside it.
                    Label("Past conversations", systemImage: "clock.arrow.circlepath")
                        .labelStyle(StackedLabelStyle(stacked: sideways))
                        .font(.system(size: min(style.captionSize * 0.6, sideways ? 24 : 28),
                                      weight: .semibold, design: style.design))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.vertical, sideways ? 8 : 0)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 20))
                .accessibilityIdentifier("historyButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var mainButton: some View {
        let (title, icon, tint, enabled) = mainButtonState
        // Tall on an empty screen, so it cannot be missed; shorter whenever there are captions,
        // so they get the room. Keyed to the captions rather than to listening, so pressing Stop
        // does not grow the button over the last thing that was said.
        // On its side the button has a column of its own; it stays a button-sized button there
        // rather than filling the column, which made Stop the biggest thing on the screen.
        let compact = !live.lines.isEmpty && !sideways
        // Sized with the captions, but capped: past this, a bigger label only crowds the button.
        let size = min(style.captionSize * (compact ? 0.8 : 1), 44)
        return Button { model.toggle() } label: {
            Label(title, systemImage: icon)
                .font(.system(size: size, weight: .bold, design: style.design))
                .frame(maxWidth: .infinity)
                .frame(minHeight: compact ? 88 : (sideways ? 120 : 140))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 28))
        .tint(tint)
        .disabled(!enabled)
        .accessibilityIdentifier("mainButton")
    }

    private var mainButtonState: (String, String, Color, Bool) {
        switch live.phase {
        case .idle, .failed: return ("Start", "mic.fill", .green, true)
        case .preparing: return (preparingText + "…", "hourglass", .gray, false)
        case .listening: return ("Stop", "stop.fill", .red, true)
        case .finishing: return ("Saving…", "hourglass", .gray, false)
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}

/// Icon beside the title, or above it.
struct StackedLabelStyle: LabelStyle {
    var stacked: Bool

    func makeBody(configuration: Configuration) -> some View {
        if stacked {
            VStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        } else {
            Label(configuration)
        }
    }
}

func formatClock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
