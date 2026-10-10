import Foundation

/// Optional per-fixture description, read from `Fixtures/metadata/<name>.json`.
///
/// The useful field is ``knownNames``: names the recognizer should be held to. Proper-noun
/// detection can only find names the recognizer capitalized, so the names that matter most —
/// family, doctors, medications — are supplied rather than guessed.
public struct FixtureMetadata: Codable, Sendable {
    public var title: String?
    /// What is being simulated: "family dinner", "doctor visit", "quiet room".
    public var scene: String?
    public var speakerCount: Int?
    /// "babble", "tv", "traffic", "silence".
    public var noise: String?
    /// Names to score strictly in the critical-information report.
    public var knownNames: [String]?
    public var notes: String?

    public init(
        title: String? = nil,
        scene: String? = nil,
        speakerCount: Int? = nil,
        noise: String? = nil,
        knownNames: [String]? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.scene = scene
        self.speakerCount = speakerCount
        self.noise = noise
        self.knownNames = knownNames
        self.notes = notes
    }
}

/// One audio input, its reference transcript, and its metadata.
public struct AudioFixture: Sendable {
    public let name: String
    public let audioURL: URL
    public let referenceURL: URL?
    public let metadataURL: URL?

    /// The intended transcript. Scoring is skipped when this is absent, and audio-only fixtures are
    /// still useful for listening and for measuring latency.
    public var reference: String? {
        referenceURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public var metadata: FixtureMetadata? {
        guard let metadataURL, let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(FixtureMetadata.self, from: data)
    }

    /// Length of the recording in seconds, or 0 when it cannot be determined from the file.
    ///
    /// Read from the header rather than by decoding, because the one thing that needs it —
    /// scoring a transcript some other process produced — has no audio pipeline in hand and does
    /// not want to decode 47 seconds of audio to divide two numbers. Only WAV is understood:
    /// every fixture is one, and an unrecognised container returns 0 rather than a guess, which
    /// shows up as a meaningless real-time factor rather than a plausible wrong one.
    public var duration: Double {
        guard let handle = try? FileHandle(forReadingFrom: audioURL) else { return 0 }
        defer { try? handle.close() }
        // 12-byte RIFF header, then 8-byte chunk headers, skipping unknown chunks. Bounded so a
        // malformed file cannot walk the whole disk looking for a `data` chunk.
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header[0..<4] == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8)
        else { return 0 }

        var byteRate = 0
        var frames = 0
        for _ in 0..<64 {
            guard let chunkHeader = try? handle.read(upToCount: 8), chunkHeader.count == 8 else {
                return 0
            }
            let id = chunkHeader[0..<4]
            let size = chunkHeader[4..<8].withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
            if id == Data("fmt ".utf8) {
                guard let body = try? handle.read(upToCount: size), body.count >= 12 else { return 0 }
                byteRate = body[8..<12].withUnsafeBytes {
                    Int($0.loadUnaligned(as: UInt32.self).littleEndian)
                }
            } else if id == Data("data".utf8) {
                frames = size
                break
            } else {
                // Chunks are word-aligned, so an odd size carries one padding byte.
                try? handle.seek(toOffset: handle.offsetInFile + UInt64(size + size % 2))
            }
        }
        guard byteRate > 0, frames > 0 else { return 0 }
        return Double(frames) / Double(byteRate)
    }
}

/// Discovers fixtures laid out under a `Fixtures/` directory.
///
/// ```
/// Fixtures/
///   audio/<name>.wav       # the recording
///   reference/<name>.txt   # what was actually said
///   metadata/<name>.json   # optional scene description and names to score
/// ```
///
/// Reference and metadata are matched to audio by filename stem, so a new fixture is added by
/// dropping files in — no registry to update.
public struct FixtureLibrary: Sendable {

    public let root: URL

    /// Audio containers AVFoundation can decode, which is what WhisperKit reads through.
    public static let audioExtensions: Set<String> = [
        "wav", "caf", "m4a", "mp3", "aiff", "aif", "flac",
    ]

    public init(root: URL) {
        self.root = root
    }

    /// Reads a fixture from a single audio file path, pairing it with any sibling reference by
    /// filename stem. This is the path used when scoring one ad-hoc recording rather than the
    /// whole library.
    public static func single(audioURL: URL, referenceURL: URL? = nil) -> AudioFixture {
        let name = audioURL.deletingPathExtension().lastPathComponent
        let expectedReference = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension("txt")
        let resolvedReference = referenceURL ?? (FileManager.default.fileExists(atPath: expectedReference.path)
            ? expectedReference
            : nil)
        return AudioFixture(
            name: name,
            audioURL: audioURL,
            referenceURL: resolvedReference,
            metadataURL: nil
        )
    }

    public var audioDirectory: URL { root.appendingPathComponent("audio") }
    public var referenceDirectory: URL { root.appendingPathComponent("reference") }
    public var metadataDirectory: URL { root.appendingPathComponent("metadata") }

    public func fixtures() throws -> [AudioFixture] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioDirectory.path) else {
            return []
        }
        let contents = try fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        )

        return contents
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { audioURL in
                let name = audioURL.deletingPathExtension().lastPathComponent
                let reference = referenceDirectory
                    .appendingPathComponent(name)
                    .appendingPathExtension("txt")
                let metadata = metadataDirectory
                    .appendingPathComponent(name)
                    .appendingPathExtension("json")
                return AudioFixture(
                    name: name,
                    audioURL: audioURL,
                    referenceURL: fileManager.fileExists(atPath: reference.path) ? reference : nil,
                    metadataURL: fileManager.fileExists(atPath: metadata.path) ? metadata : nil
                )
            }
            .sorted { $0.name < $1.name }
    }

    public func fixture(named name: String) throws -> AudioFixture {
        let matches = try fixtures().filter { $0.name == name }
        guard let match = matches.first else {
            throw CaptionError.missingFixture(name)
        }
        return match
    }

    /// Locates the `Fixtures/` directory without being told where it is.
    ///
    /// Checks, in order: an explicit `--fixtures` path, the `CAPTION_FIXTURES` environment
    /// variable, `./Fixtures` relative to the working directory, and finally the ancestors of the
    /// running executable — the last of which makes `swift run` work from any subdirectory.
    public static func locate(explicit: String? = nil) -> URL? {
        let fileManager = FileManager.default

        func isFixtures(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }

        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            return isFixtures(url) ? url : nil
        }
        if let fromEnvironment = ProcessInfo.processInfo.environment["CAPTION_FIXTURES"] {
            let url = URL(fileURLWithPath: (fromEnvironment as NSString).expandingTildeInPath)
            if isFixtures(url) { return url }
        }
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let local = workingDirectory.appendingPathComponent("Fixtures")
        if isFixtures(local) { return local }

        var directory = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<6 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appendingPathComponent("Fixtures")
            if isFixtures(candidate) { return candidate }
        }
        return nil
    }
}
