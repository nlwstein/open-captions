import CaptionKit
import Foundation
import os

/// A line-per-second record of how a session ran, written next to the app's documents.
///
/// This is the app's half of the feedback loop: `Scripts/sim.sh` pulls these files out of the
/// simulator, and on the phone they are what tells a slow caption from a missed one. Each line is
/// one JSON object, so a run can be read with `jq` or loaded straight into a notebook.
///
/// No words are written here — only counts and timings — so a diagnostics file can be shared
/// without sharing the conversation.
public final class DiagnosticsLog: @unchecked Sendable {

    public static let logger = Logger(subsystem: "io.nlws.livecaption", category: "session")

    public let url: URL
    private let handle: FileHandle?
    private let started = Date()
    private let lock = NSLock()

    public init(directory: URL, sessionID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    /// Documents/Diagnostics. Documents rather than Application Support so the simulator script
    /// and Finder's device view can both reach it.
    public static func standardDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    deinit { try? handle?.close() }

    public func event(_ name: String, _ fields: [String: Any] = [:]) {
        var record = fields
        record["event"] = name
        record["t"] = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
        Self.logger.info("\(name, privacy: .public) \(Self.describe(fields), privacy: .public)")
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        lock.withLock {
            handle?.write(data)
            handle?.write(Data("\n".utf8))
        }
    }

    /// The numbers worth tracking once a second: is it keeping up, is it hearing anything, and is
    /// the phone getting hot or full.
    public func status(_ status: CaptionerStatus) {
        event("status", [
            "audio": round3(status.audioSeconds),
            "wall": round3(status.wallSeconds),
            "rtf": round3(status.realTimeFactor),
            "load": round3(status.processingLoad),
            "lastUpdate": round3(status.lastUpdateSeconds),
            "slowestRecent": round3(status.recentSlowestUpdateSeconds),
            "slowest": round3(status.slowestUpdateSeconds),
            "levelDb": round3(Double(status.level)),
            "gainDb": round3(Double(status.gainDb)),
            "speaking": status.isSpeaking,
            "words": status.words,
            "turns": status.turns,
            "speakers": status.speakers.count,
            "contested": status.contestedTurns,
            "memoryMB": round3(Self.memoryFootprintMB()),
            "thermal": Self.thermalState(),
        ])
    }

    private func round3(_ value: Double) -> Double {
        value.isFinite ? (value * 1000).rounded() / 1000 : -1
    }

    private static func describe(_ fields: [String: Any]) -> String {
        fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
    }

    /// Physical footprint, the number iOS's memory limit is enforced against.
    public static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    public static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
