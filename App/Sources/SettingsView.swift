import AVFoundation
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
                    Toggle("Scroll back while listening", isOn: $store.settings.scrollBackWhileListening)
                        .disabled(!store.settings.simpleMode)
                        .accessibilityIdentifier("scrollBackToggle")
                    TextField("Supporter PIN (optional)", text: $store.settings.supporterPIN)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Simple mode shows only the captions and one big button. Hold the top of the screen for two seconds to come back here. With a PIN, it is asked for first.\n\nWith scrolling back off, the newest words stay in view while listening, even if the screen is touched. Earlier words can still be read once listening stops, and in Past conversations.")
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
                    Toggle("Keep the screen on while listening", isOn: $store.settings.keepScreenAwake)
                } header: {
                    Text("Listening")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.modelsDownloaded {
                            Text("\(store.settings.engine.displayName) is not on this phone yet: it downloads, about \(model.downloadSize), when you close settings. Use Wi-Fi.")
                                .foregroundStyle(.orange)
                        }
                        Text("Changes apply from the next conversation.")
                    }
                }

                microphoneSection(store: store)

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
                    if let dedication = About.dedication {
                        NavigationLink {
                            DedicationView(text: dedication)
                        } label: {
                            Label("Dedication", systemImage: "heart")
                        }
                        .accessibilityIdentifier("dedicationLink")
                    }
                    NavigationLink {
                        ChangelogView(changelog: About.changelog)
                    } label: {
                        Label("What's new", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("changelogLink")
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                    LabeledContent("Version", value: About.version)
                } header: {
                    Text("About")
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

    @ViewBuilder
    private func microphoneSection(store: SettingsStore) -> some View {
        @Bindable var store = store
        Section {
            Picker("Processing", selection: $store.settings.microphone) {
                ForEach(MicrophoneProcessing.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Microphone", selection: $store.settings.micSource) {
                ForEach(MicrophoneSetup.Microphone.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Pickup pattern", selection: $store.settings.micPattern) {
                ForEach(MicrophoneSetup.Pattern.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if store.settings.microphone.usesVoiceProcessing {
                Button("Choose Mic Mode…") { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
                LabeledContent("Mic Mode", value: AVCaptureDevice.activeMicrophoneMode.name)
            }
            Toggle("Set the phone's input gain", isOn: Binding(
                get: { store.settings.hardwareGain != nil },
                set: { store.settings.hardwareGain = $0 ? 1 : nil }))
            if let gain = store.settings.hardwareGain {
                VStack(alignment: .leading) {
                    Text("Phone input gain: \(Int((gain * 100).rounded()))%")
                    Slider(value: Binding(get: { gain }, set: { store.settings.hardwareGain = $0 }),
                           in: 0...1, step: 0.05)
                }
            }
            Toggle("Boost quiet speech", isOn: $store.settings.automaticGain)
            if store.settings.automaticGain {
                VStack(alignment: .leading) {
                    Text("Most boost: \(Int(store.settings.maxGainDb)) dB")
                    Slider(value: $store.settings.maxGainDb, in: 0...60, step: 2)
                }
                VStack(alignment: .leading) {
                    Text("Aim speech at: \(Int(store.settings.targetSpeechDb)) dB")
                    Slider(value: $store.settings.targetSpeechDb, in: -40...(-10), step: 1)
                }
            }
            Toggle("Show a level meter while listening", isOn: $store.settings.showMicrophoneMeter)
            NavigationLink {
                MicTestView()
            } label: {
                Label("Microphone test", systemImage: "waveform.badge.mic")
            }
            .accessibilityIdentifier("micTestLink")
            Button("Back to the usual microphone settings") {
                store.settings.microphoneSetup = MicrophoneSetup()
                store.settings.gain = GainTuning()
            }
            .disabled(store.settings.microphoneSetup == MicrophoneSetup() && store.settings.gain == GainTuning())
        } header: {
            Text("Microphone")
        } footer: {
            Text("For trying out what hears people best from across a table; the microphone test compares them for you. Processing: None is the phone's raw microphone. Video recording is what the Camera app uses. Voice chat and Video chat are the phone-call processing, which follow the Mic Mode chosen here or in Control Center (Standard, Voice Isolation, Wide Spectrum), and may drop people other than the nearest. Boost quiet speech is this app's own gain, after the phone's.")
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
        LabeledContent("Microphone", value: model.live.input?.name ?? model.live.session?.input ?? "—")
        if let details = model.live.input?.details, !details.isEmpty {
            Text(details.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        LabeledContent("Level", value: String(format: "%.0f dB, boosted %.0f dB", status.level, status.gainDb))
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
