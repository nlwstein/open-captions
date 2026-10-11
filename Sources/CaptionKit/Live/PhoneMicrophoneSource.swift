import Foundation

/// Which of the phone's capture chains the samples come through.
public enum MicrophoneProcessing: String, CaseIterable, Codable, Sendable {
    /// `.measurement`: no automatic gain, no noise suppression. The closest thing on a phone to
    /// what the MacBook's microphone delivered when the engine was judged to work well, and
    /// `AutomaticGain` already does the one thing the system's chain would have done for us.
    case none
    /// `.default`: whatever the system applies to a recording app.
    case standard
    /// `.voiceChat`: echo cancellation and voice isolation, as on a phone call. Built for one
    /// talker close to the phone, so it may suppress the other people at the table — which is
    /// the case this app exists for. Offered so that can be measured rather than assumed.
    case voiceIsolation
}

#if os(iOS)
import AVFoundation

extension MicrophoneProcessing {
    var mode: AVAudioSession.Mode {
        switch self {
        case .none: return .measurement
        case .standard: return .default
        case .voiceIsolation: return .voiceChat
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

    public typealias Processing = MicrophoneProcessing

    private let processing: Processing
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []

    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false)!

    public init(processing: Processing = .none) {
        self.processing = processing
    }

    public func stream() async throws -> AsyncThrowingStream<[Float], Error> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw LiveAudioError.microphonePermissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: processing.mode, options: [])
        try session.setActive(true)

        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
            bufferingPolicy: .unbounded)
        lock.withLock { self.continuation = continuation }
        continuation.onTermination = { [weak self] _ in self?.teardown() }

        try startEngine()
        observe()
        return stream
    }

    public func stop() async {
        let continuation = lock.withLock { self.continuation }
        continuation?.finish()
        teardown()
    }

    public func origin() -> AudioOrigin {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let input = route.inputs.first else {
            return AudioOrigin(kind: .microphone, name: "no microphone")
        }
        var details = [processing.rawValue]
        if let source = input.selectedDataSource?.dataSourceName { details.append(source) }
        return AudioOrigin(kind: .microphone, name: input.portName, details: details)
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: Self.target)
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
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else {
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
        guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
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
#endif
