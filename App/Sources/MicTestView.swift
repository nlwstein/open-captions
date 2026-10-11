import AVFoundation
import CaptionKit
import CaptionSession
import SwiftUI
import UIKit

/// One recording made by the microphone test.
struct MicTestClip: Codable, Identifiable, Sendable {
    var id: Int { index }
    var index: Int
    var setup: MicrophoneSetup
    var file: String
    /// The input as iOS set it up, which may not be what was asked for.
    var input: String
    var details: [String]
    var seconds: Double
    /// Levels of the 100 ms chunks, in dBFS, before any gain of ours.
    var levelP10: Double
    var levelP50: Double
    var levelP90: Double
    var peak: Double
    var words: Int?
    var transcript: String?
    var error: String?
}

/// Records the same room through each microphone setup in turn, then captions every recording, so
/// setups can be compared by what the recogniser makes of them rather than by ear.
///
/// Each recording is the 16 kHz mono audio the recogniser would have been given, before the app's
/// own gain, saved under Documents/MicTest with a results.json beside it.
@MainActor
@Observable
final class MicTestModel {
    enum Phase: Equatable {
        case idle
        case leadIn(Int)
        case recording(index: Int, remaining: Int)
        case transcribing(index: Int)
        case done
    }

    let setups = MicrophoneSetup.testDefaults
    var chosen: Set<Int> = Set(MicrophoneSetup.testDefaults.indices)
    var seconds = 30
    var leadIn = 10
    private(set) var phase = Phase.idle
    /// The newest chunk's level, for the meter.
    private(set) var level: Double = -120
    private(set) var clips: [MicTestClip] = []
    private(set) var folder: URL?
    private var task: Task<Void, Never>?

    var isBusy: Bool { phase != .idle && phase != .done }

    var files: [URL] {
        guard let folder else { return [] }
        return clips.filter { $0.error == nil }.map { folder.appending(path: $0.file) }
            + [folder.appending(path: "results.json")]
    }

    /// The setups a run will record, in order, without repeats.
    func planned(extra: MicrophoneSetup?) -> [MicrophoneSetup] {
        var list = setups.indices.filter(chosen.contains).map { setups[$0] }
        if let extra, !list.contains(extra) { list.insert(extra, at: 0) }
        return list
    }

    func start(extra: MicrophoneSetup?) {
        let list = planned(extra: extra)
        guard !list.isEmpty else { return }
        task = Task { await record(list) }
    }

    func transcribeAll(with live: LiveConversation) {
        task = Task { await transcribe(live) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Recording

    private func record(_ list: [MicrophoneSetup]) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "MicTest/\(stamp)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        clips = []

        for remaining in stride(from: leadIn, to: 0, by: -1) {
            phase = .leadIn(remaining)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { phase = .idle; return }
        }
        for (index, setup) in list.enumerated() {
            if Task.isCancelled { break }
            phase = .recording(index: index, remaining: seconds)
            let clip: MicTestClip
            do {
                clip = try await capture(setup, index: index, into: folder)
            } catch {
                clip = MicTestClip(index: index, setup: setup, file: "", input: "", details: [],
                                   seconds: 0, levelP10: 0, levelP50: 0, levelP90: 0, peak: 0,
                                   error: String(describing: error))
            }
            clips.append(clip)
            save()
            // A moment for the audio session to wind down before the next one is set up.
            try? await Task.sleep(for: .milliseconds(500))
        }
        level = -120
        phase = Task.isCancelled ? .idle : .done
    }

    private func capture(_ setup: MicrophoneSetup, index: Int, into folder: URL) async throws -> MicTestClip {
        let source = PhoneMicrophoneSource(setup: setup)
        let stream = try await source.stream()
        let name = String(format: "%02d-%@.wav", index + 1, setup.slug)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                   interleaved: false)!
        let file = try AVAudioFile(forWriting: folder.appending(path: name), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        // The first second is thrown away: a newly opened microphone, and iOS's own gain, settle.
        var settling = 16_000
        let wanted = seconds * 16_000
        var written = 0
        var levels: [Double] = []
        do {
            for try await chunk in stream {
                if Task.isCancelled { break }
                let db = Self.levelDb(chunk)
                level = db
                if settling > 0 {
                    settling -= chunk.count
                    continue
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(chunk.count))
                else { continue }
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
                try file.write(from: buffer)
                levels.append(db)
                written += chunk.count
                phase = .recording(index: index, remaining: max(0, (wanted - written + 15_999) / 16_000))
                if written >= wanted { break }
            }
        } catch {
            await source.stop()
            throw error
        }
        let origin = source.origin()
        await source.stop()
        file.close()

        let sorted = levels.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? -120 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        return MicTestClip(index: index, setup: setup, file: name, input: origin.name,
                           details: origin.details, seconds: Double(written) / 16_000,
                           levelP10: percentile(0.1), levelP50: percentile(0.5),
                           levelP90: percentile(0.9), peak: sorted.last ?? -120)
    }

    static func levelDb(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return max(-120, 10 * log10(max(power, 1e-12)))
    }

    // MARK: - Transcribing

    private func transcribe(_ live: LiveConversation) async {
        guard let folder else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        for index in clips.indices where clips[index].error == nil {
            if Task.isCancelled { break }
            phase = .transcribing(index: index)
            do {
                let turns = try await live.transcribe(file: folder.appending(path: clips[index].file))
                let text = turns.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
                clips[index].transcript = text
                clips[index].words = text.split(separator: " ").count
            } catch {
                clips[index].error = String(describing: error)
            }
            save()
        }
        phase = Task.isCancelled ? .idle : .done
    }

    private func save() {
        guard let folder else { return }
        struct Results: Encodable {
            var device: String
            var system: String
            var secondsPerSetup: Int
            var clips: [MicTestClip]
        }
        let results = Results(device: UIDevice.current.name, system: UIDevice.current.systemVersion,
                              secondsPerSetup: seconds, clips: clips)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: folder.appending(path: "results.json"))
    }
}

/// The microphone test, reached from settings.
struct MicTestView: View {
    @Environment(AppModel.self) private var model
    @State private var test = MicTestModel()
    @State private var includeCurrent = true

    var body: some View {
        Form {
            Section {
                Text("Put the phone where it would sit in a real conversation and have people talk from the usual distance — or play the same recording from across the room. Each setup records in turn. Then press Transcribe all and compare: the setup that catches the most words is usually the one to use.")
                    .font(.callout)
            }

            Section {
                Toggle(isOn: $includeCurrent) {
                    VStack(alignment: .leading) {
                        Text("Current settings")
                        Text(model.settings.microphoneSetup.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(test.setups.indices, id: \.self) { index in
                    Toggle(test.setups[index].label, isOn: chosenBinding(index))
                }
            } header: {
                Text("Setups to try")
            }
            .disabled(test.isBusy)

            Section("Timing") {
                Stepper("Each setup: \(test.seconds) s", value: $test.seconds, in: 10...300, step: 5)
                Stepper("Time to walk away: \(test.leadIn) s", value: $test.leadIn, in: 0...60, step: 5)
                LabeledContent("Total", value: formatClock(Double(totalSeconds)))
            }
            .disabled(test.isBusy)

            Section {
                statusRow
                MeterBar(level: test.level)
                if test.isBusy {
                    Button("Stop", role: .destructive) { test.cancel() }
                } else {
                    Button("Record each setup") {
                        test.start(extra: includeCurrent ? model.settings.microphoneSetup : nil)
                    }
                    .disabled(model.live.isRunning || setupCount == 0)
                    Button("Transcribe all") { test.transcribeAll(with: model.live) }
                        .disabled(test.clips.isEmpty || model.live.isRunning)
                }
            } footer: {
                if model.live.isRunning {
                    Text("Stop the conversation first.")
                } else {
                    Text("Transcribing runs \(model.settings.engine.displayName) with the gain settings above, about eight times faster than real time.")
                }
            }

            if !test.clips.isEmpty {
                Section {
                    ForEach(test.clips) { clip in
                        ClipRow(clip: clip, best: clip.words != nil && clip.words == bestWords) {
                            model.settings.microphoneSetup = clip.setup
                        }
                    }
                    ShareLink("Share recordings and results", items: test.files)
                } header: {
                    Text("Results")
                } footer: {
                    if let folder = test.folder {
                        Text("Saved in Documents/MicTest/\(folder.lastPathComponent).")
                    }
                }
            }
        }
        .navigationTitle("Microphone test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { test.cancel() }
    }

    private var planned: [MicrophoneSetup] {
        test.planned(extra: includeCurrent ? model.settings.microphoneSetup : nil)
    }
    private var setupCount: Int { planned.count }
    private var totalSeconds: Int { test.leadIn + setupCount * (test.seconds + 2) }
    private var bestWords: Int? { test.clips.compactMap(\.words).max() }

    @ViewBuilder
    private var statusRow: some View {
        switch test.phase {
        case .idle: Text("Ready").foregroundStyle(.secondary)
        case .leadIn(let n): Text("Starting in \(n) s").font(.headline)
        case .recording(let index, let remaining):
            VStack(alignment: .leading) {
                Text("Recording \(index + 1) of \(setupCount) · \(remaining) s left").font(.headline)
                Text(setupLabel(index)).font(.caption).foregroundStyle(.secondary)
            }
        case .transcribing(let index):
            Text("Transcribing \(index + 1) of \(test.clips.count)…").font(.headline)
        case .done: Text("Done").foregroundStyle(.green)
        }
    }

    private func setupLabel(_ index: Int) -> String {
        let list = planned
        return index < list.count ? list[index].label : ""
    }

    private func chosenBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { test.chosen.contains(index) },
                set: { if $0 { test.chosen.insert(index) } else { test.chosen.remove(index) } })
    }
}

private struct ClipRow: View {
    let clip: MicTestClip
    let best: Bool
    let use: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(clip.index + 1). \(clip.setup.label)").font(.headline)
                Spacer()
                if let words = clip.words {
                    Text("\(words) words")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(best ? .green : .primary)
                }
            }
            if let error = clip.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text(String(format: "speech %.0f dB (quiet %.0f, typical %.0f, peak %.0f)",
                            clip.levelP90, clip.levelP10, clip.levelP50, clip.peak))
                    .font(.caption.monospacedDigit())
                Text(([clip.input] + clip.details).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let transcript = clip.transcript {
                    DisclosureGroup("Transcript") {
                        Text(transcript.isEmpty ? "(nothing heard)" : transcript)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
                Button("Use this setup", action: use)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A level meter for dBFS, from -80 to 0, with the gain stage's usual target marked.
struct MeterBar: View {
    let level: Double
    var target: Double = -25

    var body: some View {
        let fraction = min(max((level + 80) / 80, 0), 1)
        let mark = min(max((target + 80) / 80, 0), 1)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > -6 ? .red : level > -45 ? .green : .orange)
                    .frame(width: geometry.size.width * fraction)
                Rectangle().fill(.primary).frame(width: 2)
                    .offset(x: geometry.size.width * mark - 1)
            }
        }
        .frame(height: 10)
        .overlay(alignment: .trailing) {
            Text(String(format: "%.0f dB", level))
                .font(.caption2.monospacedDigit())
                .offset(y: 14)
        }
        .padding(.bottom, 12)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityLabel(String(format: "Level %.0f decibels", level))
    }
}
