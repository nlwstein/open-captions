import AVFoundation
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

/// Reads a file as 16 kHz mono samples.
///
/// Exists so callers that need samples — the harness reading an enrolment clip — do not have to
/// import WhisperKit to get them, and so there is one place that decides what "load some audio"
/// means.
///
/// **WhisperKit's own loader is not used for files that need resampling, and the reason is
/// measured.** `AudioProcessor.loadAudioAsFloatArray` builds an `AVAudioConverter` and calls
/// `convert(to:error:withInputFrom:)` exactly once per read. A sample-rate converter carries filter
/// state across calls and has a latency of its own; used once and thrown away, neither is
/// accounted for. On 16 kHz input nothing is resampled and the result is exact — a re-encode to
/// float32 scores identically. On DiPCo S02's own `U01.CH1` the same 300 seconds scores **71%**
/// when the file is already 16 kHz and **59%** when the identical audio arrives as a 192 kHz copy,
/// which is twelve points for a resample the corpus itself does not contain. Feeding the 192 kHz
/// file through `ffmpeg -ar 16000` first and then through the same harness recovers 71%, which puts
/// the loss in the conversion and not in the model.
public enum AudioFile {

    /// The rate everything downstream assumes.
    public static let sampleRate: Double = 16_000

    public static func load(_ url: URL) throws -> [Float] {
        do {
            // Opened as float32 so `processingFormat` is the format buffers must be built in —
            // reading into a buffer made from `fileFormat` instead hands the converter whatever the
            // file happened to be stored as, which for the usual 16-bit wav is not the float layout
            // the rest of this assumes.
            let file = try AVAudioFile(forReading: url,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            let format = file.processingFormat

            // The common case, and the one the textbook path is exact for: already at the model's
            // rate, so there is nothing to convert and no reason to do the conversion ourselves.
            if format.sampleRate == sampleRate {
                return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            }
            return try resample(file, from: format)
        } catch let error as LiveAudioError {
            throw error
        } catch {
            throw LiveAudioError.unreadableAudio(url.path)
        }
    }

    /// Reads a file of any rate and channel count as 16 kHz mono.
    ///
    /// One converter for the whole file, and the input block is a *source* the converter pulls from
    /// whenever it wants more. That is the shape the API documents, and it is the shape the library
    /// this replaces gets wrong: building a converter per read buffer and calling `convert` once
    /// leaves the filter unprimed and its latency uncompensated, which on a 12:1 decimation costs
    /// real signal rather than rounding error.
    private static func resample(_ file: AVAudioFile, from format: AVAudioFormat) throws -> [Float] {
        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate,
                                       channels: 1,
                                       interleaved: false),
            let converter = AVAudioConverter(from: format, to: target)
        else {
            throw LiveAudioError.unreadableAudio(file.url.path)
        }

        // Named rather than left at the default: this is the one setting that decides how much of
        // the speech band survives a 12:1 decimation.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        // Ten seconds of audio per pull. Small enough that a 192 kHz file is never held twice over,
        // large enough that the pull overhead disappears.
        let pullFrames = AVAudioFrameCount(format.sampleRate * 10)
        var exhausted = false

        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if exhausted {
                status.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pullFrames) else {
                exhausted = true
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: pullFrames)
            } catch {
                // A read that fails part-way is the end as far as this loop is concerned; the
                // samples already converted are worth more than an exception here.
                exhausted = true
                status.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                exhausted = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return input
        }

        // Sized for a full pull plus slack for whatever the converter is holding internally.
        let capacity = AVAudioFrameCount(Double(pullFrames) * sampleRate / format.sampleRate) + 8192
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw LiveAudioError.unreadableAudio(file.url.path)
        }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * sampleRate / format.sampleRate) + 1024)

        while true {
            converted.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: converted, error: &error, withInputFrom: inputBlock)

            if converted.frameLength > 0, let channel = converted.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                              count: Int(converted.frameLength)))
            }
            if status == .error { throw error ?? LiveAudioError.unreadableAudio(file.url.path) }
            if status == .endOfStream { break }
        }
        return output
    }
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

    /// The task feeding the stream, held so `stop()` can end the run early. Without it the only way
    /// out of a file replay is to wait it out or kill the process, which is exactly what a smoke
    /// test needs to not do: the run being abandoned is often the interesting one.
    private var producer: Task<Void, Never>?

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

        var samples = try AudioFile.load(url)
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
            lock.withLock { producer = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() async {
        lock.withLock { producer }?.cancel()
    }

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
