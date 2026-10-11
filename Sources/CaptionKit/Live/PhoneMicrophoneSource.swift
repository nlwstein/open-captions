import Foundation

#if os(iOS)
import AVFoundation

extension MicrophoneProcessing {
    var mode: AVAudioSession.Mode {
        switch self {
        case .none: return .measurement
        case .standard: return .default
        case .videoRecording: return .videoRecording
        case .voiceIsolation: return .voiceChat
        case .videoChat: return .videoChat
        }
    }

    /// Voice processing only runs in a session that can also play, so the two chat modes need
    /// `.playAndRecord`. In `.record` iOS quietly ignores them.
    var category: AVAudioSession.Category {
        usesVoiceProcessing ? .playAndRecord : .record
    }
}

extension MicrophoneSetup.Pattern {
    var polarPattern: AVAudioSession.PolarPattern? {
        switch self {
        case .automatic: return nil
        case .omnidirectional: return .omnidirectional
        case .cardioid: return .cardioid
        case .subcardioid: return .subcardioid
        case .stereo: return .stereo
        }
    }
}

extension MicrophoneSetup.Microphone {
    var orientation: AVAudioSession.Orientation? {
        switch self {
        case .automatic: return nil
        case .bottom: return .bottom
        case .front: return .front
        case .back: return .back
        }
    }
}

/// The phone's microphone, captured directly rather than through WhisperKit.
///
/// Two reasons not to reuse `MicrophoneAudioSource` here. The first is the audio session:
/// WhisperKit sets `.playAndRecord` in the default mode and nothing else, so which of the phone's
/// own processing chains the recogniser hears is decided for us — and the Anker USB mic showed how
/// much a device's processing can cost. This makes it a setting, so it can be measured. The second
/// is the resampler: WhisperKit converts each tap buffer with a converter it hands one buffer and
/// then `.haveData` again if asked, which is correct only because AVAudioConverter happens to ask
/// once per buffer at these rates. Here the converter is told plainly that there is no more input
/// for now, which is the documented contract for a streaming conversion.
public final class PhoneMicrophoneSource: LiveAudioSource, @unchecked Sendable {

    public let setup: MicrophoneSetup

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    /// What iOS agreed to, as opposed to what was asked for. Filled in once capture starts.
    private var applied: [String] = []

    public init(setup: MicrophoneSetup = MicrophoneSetup()) {
        self.setup = setup
    }

    public convenience init(processing: MicrophoneProcessing) {
        self.init(setup: MicrophoneSetup(processing: processing))
    }

    public func stream() async throws -> AsyncThrowingStream<[Float], Error> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw LiveAudioError.microphonePermissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(setup.processing.category, mode: setup.processing.mode, options: [])
        try session.setActive(true)
        let notes = configureInput(session)

        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
            bufferingPolicy: .unbounded)
        lock.withLock { self.continuation = continuation }
        continuation.onTermination = { [weak self] _ in self?.teardown() }

        try startEngine()
        observe()
        lock.withLock { applied = Self.describe(session) + notes }
        return stream
    }

    public func stop() async {
        let continuation = lock.withLock { self.continuation }
        continuation?.finish()
        teardown()
    }

    public func origin() -> AudioOrigin {
        let route = AVAudioSession.sharedInstance().currentRoute
        let details = lock.withLock { applied }
        guard let input = route.inputs.first else {
            // Before capture starts there is no route yet; say what was asked for instead.
            return AudioOrigin(kind: .microphone, name: "phone microphone", details: [setup.label])
        }
        return AudioOrigin(kind: .microphone, name: input.portName,
                           details: details.isEmpty ? [setup.label] : details)
    }

    // MARK: - Choosing the microphone

    /// Picks the built-in microphone, its data source and its pattern, as far as this phone allows.
    /// Returns a note for anything asked for that the phone would not do.
    private func configureInput(_ session: AVAudioSession) -> [String] {
        var notes: [String] = []
        let wantsMicrophone = setup.microphone != .automatic || setup.pattern != .automatic
        if wantsMicrophone,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            do { try session.setPreferredInput(builtIn) } catch { notes.append("input not chosen: \(error.localizedDescription)") }
            let sources = builtIn.dataSources ?? []
            var source = builtIn.selectedDataSource ?? builtIn.preferredDataSource ?? sources.first
            if let orientation = setup.microphone.orientation {
                if let match = sources.first(where: { $0.orientation == orientation }) {
                    source = match
                } else {
                    notes.append("no \(setup.microphone.rawValue) microphone")
                }
            }
            if let source {
                if let pattern = setup.pattern.polarPattern {
                    if source.supportedPolarPatterns?.contains(pattern) == true {
                        do { try source.setPreferredPolarPattern(pattern) } catch {
                            notes.append("pattern not set: \(error.localizedDescription)")
                        }
                    } else {
                        notes.append("\(setup.pattern.rawValue) not offered by \(source.dataSourceName)")
                    }
                }
                do { try builtIn.setPreferredDataSource(source) } catch {
                    notes.append("microphone not chosen: \(error.localizedDescription)")
                }
            }
            if setup.pattern == .stereo {
                try? session.setPreferredInputOrientation(.portrait)
                try? session.setPreferredInputNumberOfChannels(2)
            }
        }
        if let gain = setup.hardwareGain {
            if session.isInputGainSettable {
                do { try session.setInputGain(Float(min(max(gain, 0), 1))) } catch {
                    notes.append("input gain not set: \(error.localizedDescription)")
                }
            } else {
                notes.append("input gain is fixed on this route")
            }
        }
        return notes
    }

    /// The session as it actually ended up, for diagnostics: a request iOS declined is otherwise
    /// indistinguishable from one that made no difference.
    private static func describe(_ session: AVAudioSession) -> [String] {
        var details = ["mode \(session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))"]
        if let input = session.currentRoute.inputs.first {
            if let source = input.selectedDataSource {
                details.append("mic \(source.dataSourceName)")
                if let pattern = source.selectedPolarPattern {
                    details.append("pattern \(pattern.rawValue.replacingOccurrences(of: "AVAudioSessionPolarPattern", with: ""))")
                }
            }
        }
        details.append("\(session.inputNumberOfChannels) ch")
        details.append(String(format: "%.0f Hz", session.sampleRate))
        details.append(session.isInputGainSettable
                       ? String(format: "input gain %.2f", session.inputGain) : "input gain fixed")
        if session.mode == .voiceChat || session.mode == .videoChat {
            details.append("mic mode \(AVCaptureDevice.activeMicrophoneMode.name)")
        }
        return details
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Converted at the input's own channel count and mixed to mono afterwards: a converter
        // asked to go from two channels to one keeps the first and drops the second.
        guard format.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: format.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else {
            throw LiveAudioError.unreadableAudio("microphone (\(format))")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        lock.withLock { self.converter = converter }

        // 100 ms at the hardware rate, which is the chunk size the rest of the pipeline assumes.
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter = lock.withLock({ self.converter }) else { return }
        let target = converter.outputFormat
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        let count = Int(out.frameLength)
        let channels = Int(target.channelCount)
        guard count > 0, let data = out.floatChannelData else { return }
        var samples = Array(UnsafeBufferPointer(start: data[0], count: count))
        if channels > 1 {
            for channel in 1..<channels {
                let other = data[channel]
                for i in 0..<count { samples[i] += other[i] }
            }
            let scale = 1 / Float(channels)
            for i in 0..<count { samples[i] *= scale }
        }
        lock.withLock { self.continuation }?.yield(samples)
    }

    /// A phone call, Siri, or another app taking the microphone stops the engine; plugging in a
    /// microphone changes the input format under it. Both are recovered from by starting again
    /// rather than ending the session, because a transcript that silently stops is the failure the
    /// person reading it cannot see.
    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            self?.restart()
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restart()
        })
    }

    private func restart() {
        guard lock.withLock({ continuation != nil }) else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(true)
        try? startEngine()
    }

    private func teardown() {
        let wasRunning = lock.withLock { () -> Bool in
            defer { continuation = nil; converter = nil }
            return continuation != nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if wasRunning {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

extension AVCaptureDevice.MicrophoneMode {
    public var name: String {
        switch self {
        case .standard: return "standard"
        case .voiceIsolation: return "voice isolation"
        case .wideSpectrum: return "wide spectrum"
        @unknown default: return "unknown"
        }
    }
}
#endif
