import Foundation
import WhisperKit

/// Where live audio comes from.
///
/// Two implementations exist because the loop they feed is the part worth testing: the microphone
/// one needs a person and a permission grant, and a live pipeline that can only be exercised by
/// talking into a laptop is a live pipeline nobody can regression-test. The file source drives the
/// identical code path from a fixture, in real time or faster.
public protocol LiveAudioSource: AnyObject {
    /// A stream of 16 kHz mono samples, roughly 100 ms per chunk, ending when capture stops.
    func stream() async throws -> AsyncThrowingStream<[Float], Error>

    /// Stops capture. Safe to call more than once.
    func stop() async

    /// Where this audio is coming from, for the status display.
    ///
    /// Re-read rather than cached: a device can change under a running session, and a Bluetooth
    /// headset swapping its own profile mid-call is exactly the kind of thing that is invisible in
    /// the transcript and obvious on a status line.
    func origin() -> AudioOrigin
}

public enum LiveAudioError: Error, CustomStringConvertible {
    case microphonePermissionDenied
    case sourceAlreadyStarted
    case unreadableAudio(String)

    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return """
            Microphone access was refused. Grant it to the terminal you are running from in \
            System Settings → Privacy & Security → Microphone, then try again.
            """
        case .sourceAlreadyStarted:
            return "This audio source has already been started."
        case .unreadableAudio(let path):
            return "Could not read audio at \(path)."
        }
    }
}

/// The Mac's own microphone, through WhisperKit's capture stack.
///
/// Deliberately WhisperKit's `AudioProcessor` rather than a hand-rolled `AVAudioEngine`: it already
/// performs the input-format conversion to 16 kHz mono that the recognizer requires, and it is the
/// same capture path the app will use on iOS, so a problem found here is a real one.
public final class MicrophoneAudioSource: LiveAudioSource, @unchecked Sendable {

    private let processor = AudioProcessor()

    public init() {}

    public func stream() async throws -> AsyncThrowingStream<[Float], Error> {
        guard await AudioProcessor.requestRecordPermission() else {
            throw LiveAudioError.microphonePermissionDenied
        }
        // WhisperKit's stream ends when the recorder stops; its termination handler tears the engine
        // down, so breaking out of the consuming loop is enough to release the microphone.
        let (stream, _) = processor.startStreamingRecordingLive(inputDeviceID: nil)
        return stream
    }

    public func stop() async {
        processor.stopRecording()
    }

    public func origin() -> AudioOrigin {
        AudioInputDevice.current()
    }
}

/// Plays a file into the live loop at wall-clock pace.
///
/// This is the whole point of the abstraction: `--from-file Fixtures/audio/ami-meeting.wav` runs
/// the identical buffering, segmentation, and rendering path as the microphone, so the parts that
/// can be tested are, and only the microphone itself is left unproven.
public final class FileAudioSource: LiveAudioSource, @unchecked Sendable {

    private let url: URL
    private let speed: Double
    private let chunkSeconds: Double
    private let limitSeconds: Double?
    private var started = false

    /// Duration of the audio that will actually be played, once `--max-seconds` is applied. Known
    /// only after the file is read, which happens on `stream()`, so the status display shows the
    /// full file length until then.
    private let lock = NSLock()
    private var playedSeconds: Double?

    /// - Parameters:
    ///   - speed: Wall-clock multiplier. 1 is real time; 20 finishes a 46-second fixture in about
    ///     two seconds of wall clock while still exercising the same decisions.
    ///   - limitSeconds: Stop after this much *audio*, for a bounded smoke test.
    public init(url: URL, speed: Double = 1, chunkSeconds: Double = 0.1, limitSeconds: Double? = nil) {
        self.url = url
        self.speed = max(0.1, speed)
        self.chunkSeconds = chunkSeconds
        self.limitSeconds = limitSeconds
    }

    public func stream() async throws -> AsyncThrowingStream<[Float], Error> {
        guard !started else { throw LiveAudioError.sourceAlreadyStarted }
        started = true

        var samples: [Float]
        do {
            samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        } catch {
            throw LiveAudioError.unreadableAudio(url.path)
        }
        if let limitSeconds {
            samples = Array(samples.prefix(Int(limitSeconds * 16_000)))
        }
        lock.withLock { playedSeconds = Double(samples.count) / 16_000 }

        let chunkSize = max(1, Int(16_000 * chunkSeconds))
        let chunks = stride(from: 0, to: samples.count, by: chunkSize).map {
            Array(samples[$0..<min($0 + chunkSize, samples.count)])
        }
        let speed = self.speed

        return AsyncThrowingStream { continuation in
            let task = Task {
                let start = DispatchTime.now()
                var sent = 0
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                    sent += chunk.count

                    // Paced against the audio clock rather than a fixed sleep per chunk: a slow
                    // first chunk would otherwise put the run permanently behind real time. `speed`
                    // scales audio time, so the delay between chunks shrinks but the sequence does
                    // not.
                    let due = Double(sent) / 16_000 / speed
                    let elapsed = Double(
                        DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    ) / 1e9
                    if due > elapsed {
                        try? await Task.sleep(nanoseconds: UInt64((due - elapsed) * 1e9))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() async {}

    public func origin() -> AudioOrigin {
        let played = lock.withLock { playedSeconds }

        var details = ["16 kHz"]
        if let played {
            details.insert("\(Self.clock(played)) of audio", at: 0)
        }
        if speed != 1 {
            details.append(String(format: "%.1fx", speed))
        }
        return AudioOrigin(
            kind: .file,
            name: url.lastPathComponent,
            details: details,
            duration: played
        )
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
