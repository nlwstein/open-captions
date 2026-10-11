import FluidAudio
import Foundation

/// How far along getting the models ready is: downloading them the first time, then loading them.
///
/// One number for the whole job, both models together, so a progress bar moves once from empty to
/// full rather than filling twice.
public struct ModelProgress: Sendable, Equatable, CustomStringConvertible {
    public enum Step: Sendable, Equatable {
        /// Fetching model files. Only on first use, or to finish an interrupted download.
        case downloading
        /// Compiling and loading the models. The first time on a device this can take a minute.
        case loading
        case ready
    }

    public var step: Step
    /// Of the whole job, 0...1.
    public var fraction: Double
    /// The model being worked on, by name.
    public var model: String

    public init(step: Step, fraction: Double, model: String) {
        self.step = step
        self.fraction = min(max(fraction, 0), 1)
        self.model = model
    }

    public static let ready = ModelProgress(step: .ready, fraction: 1, model: "")

    public var percent: Int { Int((fraction * 100).rounded(.down)) }

    public var description: String {
        switch step {
        case .downloading: return "downloading \(model)… \(percent)%"
        case .loading: return "loading \(model)…"
        case .ready: return "ready"
        }
    }

    /// Reads one of FluidAudio's progress reports for a model that is `span` of the whole job,
    /// starting at `offset`.
    init(_ download: DownloadProgress, model: String, offset: Double, span: Double) {
        let step: Step
        switch download.phase {
        case .listing, .downloading: step = .downloading
        case .compiling: step = .loading
        }
        self.init(step: step, fraction: offset + span * download.fractionCompleted, model: model)
    }
}

/// Where the models live, and whether they are there yet.
public enum ModelCache {
    /// FluidAudio's default: `Application Support/FluidAudio/Models`.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// The folders a recogniser and the diarizer download into.
    public static func folders(for variant: StreamingModelVariant) -> [URL] {
        [variant.repo, Repo.sortformer].map { directory.appendingPathComponent($0.folderName) }
    }

    /// Roughly what the first download weighs, in megabytes, as measured in this cache on a Mac.
    /// Used to tell people what they are about to download, and to weight the progress bar.
    ///
    /// Unified's figure is its folder as it stands here, which holds every encoder the repository
    /// has, not just the one the 1120 ms setting loads; an over-estimate is the safer error.
    public static func downloadMegabytes(for variant: StreamingModelVariant) -> (recogniser: Int, diarizer: Int) {
        switch variant.repo {
        case .parakeetUnified: return (2_840, 460)
        default: return (600, 460)
        }
    }

    /// Whether every model `variant` needs has been downloaded.
    ///
    /// A presence check, not a completeness one: a folder holding a compiled model counts. An
    /// interrupted download still passes, which is fine — loading checks every file and fetches
    /// what is missing, showing the same progress it would have the first time.
    public static func isDownloaded(_ variant: StreamingModelVariant) -> Bool {
        folders(for: variant).allSatisfy(containsModel)
    }

    private static func containsModel(_ folder: URL) -> Bool {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return false }
        for case let url as URL in walk where url.pathExtension == "mlmodelc" {
            return true
        }
        return false
    }
}
