import FluidAudio
import Foundation

/// The Hugging Face commits the models are downloaded from.
///
/// FluidAudio downloads most models from each repository's `main` branch, which can change under a
/// released app. Pinning means every phone runs the files this version was tested with. To move to
/// newer models, change a commit here, test, and ship it as an app update.
public enum ModelPins {
    /// Repository path to commit. Subpaths (Nemotron's `1120ms`) follow their repository.
    public static let revisions: [String: String] = [
        "FluidInference/nemotron-speech-streaming-en-0.6b-coreml": "e673531caa6d25ab7baf5a8c14c9b99ba1551838",
        "FluidInference/parakeet-unified-en-0.6b-coreml": "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358",
        "FluidInference/diar-streaming-sortformer-coreml": "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1",
    ]

    /// FluidAudio's record of which commit a model folder holds.
    static let markerName = ".fluidaudio-revision"

    /// Points FluidAudio at the pinned commits. Call before any model loads; repeat calls are harmless.
    ///
    /// A folder downloaded before pinning has no record of its commit, and FluidAudio would check it
    /// against Hugging Face before loading, which fails with no connection. Every such folder was
    /// downloaded from `main` after these commits were made (the app's first version is from
    /// 2026-10-08, and none of these repositories has changed since 2026-09-25), so it is marked as
    /// holding them instead. A folder with a record is left to FluidAudio.
    public static func apply() {
        ModelRegistry.revisionOverrides = revisions
        let fm = FileManager.default
        for repo in Repo.allCases {
            guard let revision = revisions[repo.remotePath] else { continue }
            let folder = ModelCache.directory.appendingPathComponent(repo.folderName, isDirectory: true)
            let marker = folder.appendingPathComponent(markerName)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !fm.fileExists(atPath: marker.path)
            else { continue }
            try? Data(revision.utf8).write(to: marker, options: .atomic)
        }
    }
}
