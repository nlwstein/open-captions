import CaptionKit
import CaptionSession
import SwiftUI

/// Everything a supporter can change. Reached from the gear in advanced mode, or by holding the
/// top of the screen for two seconds in simple mode.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.captionStyle) private var style
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var store = model.settingsStore
        NavigationStack {
            Form {
                Section {
                    Toggle("Simple mode", isOn: $store.settings.simpleMode)
                        .accessibilityIdentifier("simpleModeToggle")
                    TextField("Supporter PIN (optional)", text: $store.settings.supporterPIN)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Simple mode shows only the captions and one big button. Hold the top of the screen for two seconds to come back here. With a PIN, it is asked for first.")
                }

                Section("Reading") {
                    preview
                    VStack(alignment: .leading) {
                        Text("Text size: \(Int(store.settings.textSize)) pt")
                        Slider(value: $store.settings.textSize, in: AppSettings.textSizeRange, step: 2)
                            .accessibilityIdentifier("textSizeSlider")
                    }
                    Picker("Letters", selection: $store.settings.typeface) {
                        Text("Standard").tag(AppSettings.Typeface.standard)
                        Text("Rounded").tag(AppSettings.Typeface.rounded)
                        Text("Serif").tag(AppSettings.Typeface.serif)
                    }
                    Toggle("Bold text", isOn: $store.settings.boldText)
                    VStack(alignment: .leading) {
                        Text("Space between lines")
                        Slider(value: $store.settings.lineSpacing, in: 0...1, step: 0.1)
                    }
                    Picker("Colours", selection: $store.settings.theme) {
                        Text("Match the phone").tag(AppSettings.Theme.system)
                        Text("Light").tag(AppSettings.Theme.light)
                        Text("Dark").tag(AppSettings.Theme.dark)
                        Text("High contrast, light").tag(AppSettings.Theme.highContrastLight)
                        Text("High contrast, dark").tag(AppSettings.Theme.highContrastDark)
                    }
                    Toggle("Show who is speaking", isOn: $store.settings.showSpeakers)
                }

                Section {
                    Picker("Speech model", selection: $store.settings.engine) {
                        ForEach(EngineChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Microphone processing", selection: $store.settings.microphone) {
                        Text("None (recommended)").tag(MicrophoneProcessing.none)
                        Text("Standard").tag(MicrophoneProcessing.standard)
                        Text("Voice isolation").tag(MicrophoneProcessing.voiceIsolation)
                    }
                    Toggle("Keep the screen on while listening", isOn: $store.settings.keepScreenAwake)
                } header: {
                    Text("Listening")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.modelsDownloaded {
                            Text("\(store.settings.engine.displayName) is not on this phone yet: it downloads, about \(model.downloadSize), when you close settings. Use Wi-Fi.")
                                .foregroundStyle(.orange)
                        }
                        Text("Changes apply from the next conversation. Voice isolation is tuned for one person close to the phone, and may drop other people at the table.")
                    }
                }

                Section("Conversations") {
                    Picker("Keep conversations", selection: $store.settings.keepDays) {
                        Text("Until deleted").tag(0)
                        Text("1 week").tag(7)
                        Text("1 month").tag(30)
                        Text("3 months").tag(90)
                        Text("1 year").tag(365)
                    }
                    Button("Delete all conversations", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .disabled(model.history.isEmpty)
                }

                Section("Last conversation") {
                    diagnostics
                }

                Section {
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                } footer: {
                    Text("Everything is transcribed on this phone. Nothing is sent anywhere, and no audio is kept.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsDone")
                }
            }
            .confirmationDialog("Delete every conversation?", isPresented: $confirmingDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { model.deleteAll() }
            } message: {
                Text("This cannot be undone.")
            }
            .onChange(of: store.settings.keepDays) { _, days in
                if days > 0 {
                    model.store.prune(olderThanDays: days)
                    model.reloadHistory()
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(style.speakerColor(1)).frame(width: 14, height: 14)
                Text("Speaker 1")
                    .font(style.captionFont(scale: 0.6).weight(.bold))
                    .foregroundStyle(style.speakerColor(1))
            }
            Text("Your appointment is on Tuesday at ten.")
                .font(style.captionFont())
                .lineSpacing(style.lineSpacing)
                .foregroundStyle(style.text)
        }
        .padding(.vertical, 8)
        .listRowBackground(style.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of caption text")
    }

    @ViewBuilder
    private var diagnostics: some View {
        let status = model.live.status
        LabeledContent("Engine", value: model.live.session?.engine ?? model.settings.engine.displayName)
        LabeledContent("Microphone", value: model.live.session?.input ?? "—")
        LabeledContent("Audio", value: formatClock(status.audioSeconds))
        LabeledContent("Load", value: String(format: "%.0f%%", status.processingLoad * 100))
        LabeledContent("Slowest update", value: String(format: "%.2f s", status.slowestUpdateSeconds))
        LabeledContent("Memory", value: String(format: "%.0f MB", DiagnosticsLog.memoryFootprintMB()))
        LabeledContent("Temperature", value: DiagnosticsLog.thermalState())
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            Text(Self.text)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .navigationTitle("Acknowledgements")
    }

    static let text: String = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "Notices are missing from this build." }
        return text
    }()
}
