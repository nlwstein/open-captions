import ArgumentParser
import CaptionKit
import FluidAudio
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - stream

/// The engine the app is being built around, run live, with speaker colours.
///
/// `live` shows the Whisper loop the harness was first built on and has no diarization at all, so it
/// cannot answer the question this command exists to answer: what does it *feel* like to watch a
/// conversation come back with speakers attached? That is a subjective judgement no score replaces,
/// and it is the only reason to build this before the iOS shell.
///
/// **Read the colours as a hint, not a fact.** Sortformer is right about 72% of the time on turns of
/// two seconds or more, and its slot identities hold steady for a whole recording in about five
/// sessions out of six. When it drifts, a colour moves to a different person mid-conversation —
/// which is precisely the failure a reader cannot detect and will not forgive. The per-speaker talk
/// times on the status line are there to make that visible while it happens: a slot that goes quiet
/// ten minutes in, while a new one appears, *is* drift, and no score reports it as directly.
struct Stream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream",
        abstract: "Live captions with speaker colours: a streaming recogniser + Sortformer.",
        discussion: """
        Captures the microphone and prints one colour per speaker as the words arrive. With \
        --from-file the identical pipeline runs off a recording instead, which is how this is \
        tested without asking anyone to talk into a laptop.

        Words come from a streaming recogniser — Parakeet EOU at 320 ms by default, with \
        --asr choosing another. What the engine must not be is Whisper, or batch Parakeet: the \
        batch TDT export re-encodes 5.6 seconds of left context per 80 ms chunk and runs slower \
        than real time, so it cannot be used live however accurate it is on a file. Speakers come \
        from streaming Sortformer, which beat every LS-EEND variant on all ten DiPCo sessions.

        When it finishes, the transcript is reprinted below the screen so it survives in scrollback \
        and can be pasted somewhere.
        """
    )

    @Option(name: .long, help: "Play a file through the live pipeline instead of the microphone.")
    var fromFile: String?

    @Option(name: .long, help: "Wall-clock multiplier with --from-file. 1 is real time.")
    var speed: Double = 1

    @Option(name: .long, help: "Stop after this many seconds of audio.")
    var maxSeconds: Double?

    @Option(
        name: .long,
        help: """
            Recogniser to run. Any StreamingModelVariant raw value. Defaults to nemotron-1120ms, \
            which is what the far-field measurement in ENGINES.md chose; parakeet-eou-320ms is the \
            low-latency option, and parakeet-unified1120ms the other 0.6B one.
            """
    )
    var asr: String = "nemotron-1120ms"

    @Option(
        name: .long,
        help: """
        Override the EOU chunk size, in ms: 160, 320 or 1280. Omit it to use the size the chosen \
        variant is named for, so `--asr parakeet-eou-1280ms` really does run at 1280 ms. Pass it \
        only to run a variant at a size other than its own.
        """
    )
    var chunkMs: Int?

    @Option(name: .long, help: "Silence, in ms, before an utterance is called finished.")
    var eouDebounceMs: Int = 800

    @Option(name: .long, help: "Shortest speaker change to display, in seconds. 0 disables.")
    var minTurn: Double = 0.4

    @Option(
        name: .long,
        help: """
        Write the captured 16 kHz audio to this .wav as it runs. A live session is otherwise \
        unreproducible, and this is what turns "that run went wrong" into a fixture that can be \
        replayed with --from-file.
        """
    )
    var record: String?

    @Option(
        name: .long,
        help: """
        Write the whole session to this .json when it ends: every turn with its speaker, times and \
        overlap, and every raw diarizer segment behind them. This is what turns "the colours were \
        wrong there" into something that can be looked at, because the transcript alone cannot say \
        whether a bad colour came from a bad speaker decision or from a word landing in a gap.
        """
    )
    var dump: String?

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: """
        Introduce the diarizer to a voice before the session starts, as `name=path.wav`. Repeatable. \
        Measured on DiPCo S02 and not recommended: feeding all four participants through \
        `enrollSpeaker` cost fifteen points of speaker attribution (69% → 54%) and did not reduce \
        slot drift at all. Names stay a human overlay — press 1-4 while it runs, or fix a colour \
        up afterwards with `c`. Kept because the measurement is worth being able to repeat.
        """
    )
    var enroll: [String] = []

    @Flag(name: .long, help: "Print turns as they close, no redrawing — for piping to a file.")
    var plain: Bool = false

    @Flag(name: .long, help: "Show engine timing on the status line all the time, not only when behind.")
    var stats: Bool = false

    @Flag(
        name: .long,
        help: """
        Turn off the automatic gain stage. It is on by default because the measurement is not \
        close — nine and a half points of pooled WER on Nemotron, and nineteen on the harder of \
        the two far-field windows, between DiPCo's channel as captured and the same audio gained \
        to a normal level — but the stage is new, so being able to take it back out of the signal \
        path is worth a flag.
        """
    )
    var noGain: Bool = false

    @Option(
        name: .long,
        help: """
        Ceiling on the automatic gain stage, in dB. Exposed so the level can be swept rather than \
        argued about: the achieved gain on DiPCo is this number, because the corpus wants more than \
        any sane ceiling, so sweeping it sweeps how loud the recogniser is fed.
        """
    )
    var maxGainDb: Float?

    func run() async throws {
        guard let size = try? TerminalSize.current() else {
            throw ValidationError("could not read the terminal size")
        }

        var options = StreamingCaptioner.Options()
        guard let variant = StreamingModelVariant(rawValue: asr) else {
            let known = StreamingModelVariant.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("--asr must be one of: \(known)")
        }
        options.asrVariant = variant
        if let chunkMs {
            switch chunkMs {
            case 160: options.chunkSize = .ms160
            case 320: options.chunkSize = .ms320
            case 1280: options.chunkSize = .ms1280
            default: throw ValidationError("--chunk-ms must be 160, 320 or 1280")
            }
        }
        options.eouDebounceMs = eouDebounceMs
        options.minTurnSeconds = minTurn
        options.automaticGain = !noGain
        if let maxGainDb { options.maxGainDb = maxGainDb }

        let captioner = StreamingCaptioner(options: options)

        let source: LiveAudioSource = if let fromFile {
            FileAudioSource(
                url: URL(fileURLWithPath: (fromFile as NSString).expandingTildeInPath),
                speed: speed,
                limitSeconds: maxSeconds
            )
        } else {
            MicrophoneAudioSource()
        }

        var recorder: SessionRecorder?
        if let record {
            recorder = try SessionRecorder(url: URL(fileURLWithPath: (record as NSString).expandingTildeInPath))
        }

        let plain = self.plain || isatty(STDOUT_FILENO) != 1
        let renderer = StreamRenderer(
            plain: plain,
            stats: stats,
            options: settings(options),
            origin: { [weak source] in source?.origin() },
            size: { size.current() }
        )
        renderer.recording = recorder?.url

        // Started before the models load, so the first minutes of a smoke test — which is mostly
        // staring at "loading models…" — are still typable, and the terminal is in raw mode from the
        // start rather than after the first word.
        //
        // Ctrl-C stops the source rather than the process, so a run cut short still prints its
        // transcript and writes its dump — and the interesting runs are usually the cut-short ones.
        let keyboard = plain
            ? nil
            : Keyboard { [weak renderer, weak source] key in
                guard case .interrupt = key else {
                    renderer?.key(key)
                    return
                }
                renderer?.note("stopping…")
                Task { await source?.stop() }
            }

        if !plain { renderer.enter() }
        renderer.note("loading models… this is slow the first time")
        try await captioner.prepare { message in renderer.note(message) }

        if !enroll.isEmpty {
            renderer.note("enrolling \(enroll.count) speaker(s)…")
            let clips = try enrollmentClips()
            var landed: [Int: String] = [:]
            for enrolled in try captioner.enroll(clips.map { (name: $0.name, audio: $0.audio) }) {
                let where_ = enrolled.slot.map { "slot \($0 + 1)" } ?? "no speech found"
                renderer.note("  \(enrolled.name) → \(where_)")
                if let slot = enrolled.slot { landed[slot] = enrolled.name }
            }
            renderer.adopt(namesBySlot: landed)
            // Left on screen rather than cleared: which slot each name landed in is the first
            // thing to check when the colours look wrong, and it is decided before anything is
            // said into the microphone.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        renderer.clearNote()

        let session = Session(recorder: recorder, renderer: renderer)

        renderer.begin(at: Date())
        do {
            try await captioner.run(source: source) { update in
                session.receive(update)
            }
        } catch {
            // The terminal has to go back to line-at-a-time before anything else prints, or the
            // error message arrives one character at a time and the shell stays unusable.
            keyboard?.restore()
            if !plain { renderer.leave() }
            throw error
        }
        await source.stop()
        keyboard?.restore()

        if let recorder {
            try recorder.finish()
            renderer.note("wrote \(recorder.url.path)")
        }
        if let dump {
            let url = URL(fileURLWithPath: (dump as NSString).expandingTildeInPath)
            try SessionDump(
                turns: session.turns,
                segments: captioner.diarizerSegments(),
                status: session.status,
                settings: settings(options),
                source: source.origin(),
                names: renderer.givenNames,
                flags: renderer.flaggedMoments
            ).write(to: url)
            renderer.note("wrote \(url.path)")
        }
        if !plain { renderer.finish(turns: session.turns) }
    }

    /// Reads the `--enroll name=path` clips.
    ///
    /// Read here rather than in the captioner so the captioner never touches the filesystem: it
    /// takes samples, and where those samples came from is the harness's problem — the same split
    /// as `--from-file`, and it is what keeps the engine runnable on iOS where there are no paths.
    private func enrollmentClips() throws -> [(name: String, audio: [Float])] {
        try enroll.map { argument in
            guard let separator = argument.firstIndex(of: "=") else {
                throw ValidationError("--enroll wants name=path, got '\(argument)'")
            }
            let name = String(argument[argument.startIndex..<separator])
            let path = String(argument[argument.index(after: separator)...])
            guard !name.isEmpty else {
                throw ValidationError("--enroll has an empty name in '\(argument)'")
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                return (name, try AudioFile.load(url))
            } catch {
                throw ValidationError("could not read the enrollment clip at \(url.path)")
            }
        }
    }

    /// The settings, as one line for the title. A smoke test that produces a surprising result is
    /// only useful if the settings that produced it are on screen.
    ///
    /// `modelSubdirectory`, not `durationMs`: upstream's own duration returns 630 for `.ms320`,
    /// because that is how much audio the manager accumulates before each decode. Its shift is the
    /// 320 ms the mode is named for, and its own source comment says so — "~630ms of audio per
    /// chunk (but 320ms latency due to shift)". Printing 630 would have doubled the apparent
    /// latency on the one display built for judging latency.
    ///
    /// Read off the resolved options rather than the flag, so the title reports what is actually
    /// running when `--chunk-ms` was not passed.
    private func settings(_ options: StreamingCaptioner.Options) -> String {
        let recogniser = options.asrVariant.rawValue.hasPrefix("parakeet-eou")
            ? "EOU \(options.resolvedChunkSize.modelSubdirectory) · debounce \(options.eouDebounceMs) ms"
            : options.asrVariant.rawValue
        let gain = options.automaticGain ? "agc" : "no agc"
        return "\(recogniser) · min turn " + String(format: "%.2f s", options.minTurnSeconds)
            + " · \(gain)"
    }
}

/// What the run loop needs to hand on: the frames to the recorder, the turns to the renderer, and
/// the last frame to whoever asks after the stream ends.
///
/// A box rather than two captured variables in the callback, because the callback is `@Sendable`
/// and the compiler is right to refuse the alternative — the guarantee that only one task ever calls
/// it is real but it is not one the type system can see.
private final class Session: @unchecked Sendable {

    private let lock = NSLock()
    private let recorder: SessionRecorder?
    private let renderer: StreamRenderer
    private var latest: [StreamedTurn] = []
    private var latestStatus = CaptionerStatus()

    init(recorder: SessionRecorder?, renderer: StreamRenderer) {
        self.recorder = recorder
        self.renderer = renderer
    }

    func receive(_ update: CaptionerUpdate) {
        lock.lock()
        latest = update.turns
        latestStatus = update.status
        lock.unlock()

        recorder?.append(update.audio)
        renderer.update(update)
    }

    var status: CaptionerStatus {
        lock.lock()
        defer { lock.unlock() }
        return latestStatus
    }

    var turns: [StreamedTurn] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

// MARK: - Recording

/// Writes everything the engine hears to a 16 kHz mono float WAV.
///
/// The point is reproducibility. A live session cannot be replayed, so a report of "the colours
/// moved at about four minutes" has nothing behind it — with this, that run can be replayed through
/// `--from-file` until the bug is fixed, and the fix can be checked against the exact audio that
/// exposed it.
///
/// The header is written up front with placeholder sizes and patched on `finish()`. Buffering the
/// whole session in memory instead would be simpler and wrong: these are the sessions worth
/// recording precisely because they are long.
final class SessionRecorder {

    let url: URL
    private let handle: FileHandle
    private var frames: UInt32 = 0
    private var finished = false

    /// - Throws: if the file cannot be created, which is better found before the session starts
    ///   than discovered when it ends.
    init(url: URL) throws {
        self.url = url
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
        handle.write(Self.header(dataBytes: 0))
    }

    func append(_ samples: [Float]) {
        guard !finished, !samples.isEmpty else { return }
        frames += UInt32(samples.count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            handle.write(Data(bytes: base, count: buffer.count * MemoryLayout<Float>.size))
        }
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        // Patch the two size fields rather than rewriting the header, so the audio never has to be
        // held in memory.
        let bytes = frames * 4
        try handle.seek(toOffset: 4)
        handle.write(Self.littleEndian(UInt32(36) + bytes))
        try handle.seek(toOffset: 40)
        handle.write(Self.littleEndian(bytes))
        try handle.close()
    }

    /// A canonical 44-byte WAV header for IEEE float samples — format tag 3, not 1. Writing PCM tag
    /// 1 over float data produces a file every player will happily open and read as noise.
    private static func header(dataBytes: UInt32) -> Data {
        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(littleEndian(36 + dataBytes))
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        out.append(littleEndian(UInt32(16)))       // fmt chunk size
        out.append(littleEndian(UInt16(3)))        // IEEE float
        out.append(littleEndian(UInt16(1)))        // mono
        out.append(littleEndian(UInt32(16_000)))   // sample rate
        out.append(littleEndian(UInt32(64_000)))   // byte rate
        out.append(littleEndian(UInt16(4)))        // block align
        out.append(littleEndian(UInt16(32)))       // bits per sample
        out.append(contentsOf: Array("data".utf8))
        out.append(littleEndian(dataBytes))
        return out
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func littleEndian(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// The whole session as one JSON document: what was drawn, and the diarizer segments it was drawn
/// from.
///
/// Both halves matter, and neither is enough alone. The turns say what the reader saw; the segments
/// say what the engine believed. A colour that looks wrong is either a word landing in a segment
/// that was itself wrong, or two segments genuinely overlapping there — and those need opposite
/// fixes, which cannot be told apart from the transcript.
///
/// Hand-rolled rather than `Codable`, and for the same reason the rest of this file is: the shape
/// is a debugging artifact, and a struct that quietly changes shape when a field is renamed would
/// break the only consumer of it.
struct SessionDump {

    var turns: [StreamedTurn]
    var segments: [DiarizerSegmentInfo]
    var status: CaptionerStatus
    var settings: String
    var source: AudioOrigin

    /// Names the tester gave the slots, by slot index. Recorded because a name is a claim about the
    /// audio, and a dump read a week later needs to know which claim was being tested.
    var names: [Int: String] = [:]

    /// Audio-clock seconds the tester flagged while watching. These are the whole point of the
    /// dump: they are the moments worth looking at, marked by the only person who was there.
    var flags: [Double] = []

    func write(to url: URL) throws {
        try Data(json().utf8).write(to: url)
    }

    func json() -> String {
        var out = "{\n"

        out += "  \"settings\": \(Self.string(settings)),\n"
        out += "  \"source\": {\"kind\": \(Self.string(source.kind.rawValue)), "
        out += "\"name\": \(Self.string(source.name)), "
        out += "\"duration\": \(Self.number(source.duration))},\n"
        out += "  \"audioSeconds\": \(Self.number(status.audioSeconds)),\n"
        out += "  \"wallSeconds\": \(Self.number(status.wallSeconds)),\n"
        out += "  \"processingLoad\": \(Self.number(status.processingLoad)),\n"
        out += "  \"slowestUpdateSeconds\": \(Self.number(status.slowestUpdateSeconds)),\n"
        out += "  \"words\": \(status.words),\n"
        out += "  \"contestedTurns\": \(status.contestedTurns),\n"

        out += "  \"names\": {"
        out += names.keys.sorted()
            .map { "\(Self.string(String($0))): \(Self.string(names[$0] ?? ""))" }
            .joined(separator: ", ")
        out += "},\n"

        out += "  \"flags\": [\(flags.map(Self.number).joined(separator: ", "))],\n"

        out += "  \"speechSeconds\": {"
        out += status.speakers
            .map { "\(Self.string(String($0))): \(Self.number(status.talkTime[$0] ?? 0))" }
            .joined(separator: ", ")
        out += "},\n"

        out += "  \"segments\": [\n"
        out += segments.map { segment in
            "    {\"speaker\": \(segment.speaker), \"start\": \(Self.number(segment.start)), "
                + "\"end\": \(Self.number(segment.end)), \"final\": \(segment.isFinal)}"
        }.joined(separator: ",\n")
        out += "\n  ],\n"

        out += "  \"turns\": [\n"
        out += turns.map { turn in
            "    {\"speaker\": \(turn.speaker.map(String.init) ?? "null"), "
                + "\"start\": \(Self.number(turn.start)), \"end\": \(Self.number(turn.end)), "
                + "\"overlapSeconds\": \(Self.number(turn.overlapSeconds)), "
                + "\"open\": \(turn.isOpen), \"text\": \(Self.string(turn.text))}"
        }.joined(separator: ",\n")
        out += "\n  ]\n}\n"

        return out
    }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "null" }
        return String(format: "%.4f", value)
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.4f", value) : "null"
    }

    /// Escapes the two characters that appear in a transcript often enough to matter — quote and
    /// backslash — plus a slash for the paths. Emoji and accents are valid UTF-8 JSON as they are.
    private static func string(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Rendering

/// Draws the live view on the alternate screen, the way the app's screen will scroll.
///
/// Redrawing the whole screen per update rather than appending is what lets the open turn be
/// revised: the speaker of a word is decided a second or so after the word is said, so the newest
/// line changes colour after it has already been read. Appending would either show the wrong colour
/// permanently or show no colour at all until the turn ended.
///
/// The text is wrapped here by counting characters, not display columns, and the colour is applied
/// to a whole visual line afterwards. That keeps escape sequences out of the width arithmetic
/// entirely — a line that measures its own ANSI codes wraps short and ragged.
private final class StreamRenderer: @unchecked Sendable {

    /// Eight hues, distinguishable next to each other on a dark terminal. The app wants the same
    /// property from its palette; Sortformer only ever fills four of these.
    private static let palette = [
        "\u{1B}[36m",  // cyan
        "\u{1B}[33m",  // yellow
        "\u{1B}[35m",  // magenta
        "\u{1B}[32m",  // green
        "\u{1B}[34m",  // blue
        "\u{1B}[31m",  // red
        "\u{1B}[96m",  // bright cyan
        "\u{1B}[95m",  // bright magenta
    ]
    private static let reset = "\u{1B}[0m"
    private static let dimEscape = "\u{1B}[2m"
    private static let boldEscape = "\u{1B}[1m"

    /// ~12 fps. Fast enough that text appears to arrive with the speech, slow enough that the
    /// terminal is not asked to repaint faster than anyone can read.
    private static let minimumRedrawInterval: TimeInterval = 0.08

    /// How fast the meter's peak-hold falls back, as a fraction of full scale per second. Without it
    /// the bar tracks a 100 ms RMS window and flickers at syllable rate.
    private static let meterDecayPerSecond: Float = 0.9

    private let plain: Bool
    private let stats: Bool
    private let options: String
    private let origin: () -> AudioOrigin?
    private let lock = NSLock()

    private var started = Date()
    private var note: String?
    private var printed = 0
    private var left = false
    private var lastDraw = Date.distantPast

    private var displayedLevel: Float = 0
    private var lastMeterAt = Date.distantPast
    private var lastStatus: CaptionerStatus?
    private var lastTurns: [StreamedTurn] = []
    private var lastUpdate: CaptionerUpdate?

    /// Names the tester has given the slots, and the moments they flagged. Guarded by `lock`,
    /// because the keyboard thread writes them while this one draws.
    private var names: [Int: String] = [:]
    private var flags: [Double] = []
    private var namingSlot: Int?
    private var namingText = ""

    /// Set when the session is being written to disk, so the indicator is on every frame rather
    /// than in one message that scrolls away.
    var recording: URL?

    init(
        plain: Bool,
        stats: Bool,
        options: String,
        origin: @escaping () -> AudioOrigin?,
        size: @escaping () -> TerminalSize
    ) {
        self.plain = plain
        self.stats = stats
        self.options = options
        self.origin = origin
        self.terminalSize = size
    }

    private let terminalSize: () -> TerminalSize

    func enter() {
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func leave() {
        guard !left else { return }
        left = true
        write("\u{1B}[?25h\u{1B}[?1049l")
    }

    func note(_ message: String) {
        if plain {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            return
        }
        lock.lock()
        note = message
        lock.unlock()
        draw(nil)
    }

    func clearNote() {
        lock.lock()
        note = nil
        lock.unlock()
    }

    /// Seeds the slot labels from `--enroll`, so an enrolled run is labelled from its first word
    /// rather than looking identical to an unenrolled one until someone types a name.
    ///
    /// These are the diarizer's own opinion of where each voice landed, which is exactly the thing
    /// being tested — the note that prints the same mapping at enrolment time scrolls away, and a
    /// run whose labels never appear cannot be compared against one whose labels did. Typing a name
    /// still overrides: the keyboard is the human's veto on the diarizer's guess.
    func adopt(namesBySlot: [Int: String]) {
        lock.lock()
        for (slot, name) in namesBySlot where names[slot] == nil {
            names[slot] = name
        }
        lock.unlock()
    }

    func begin(at date: Date) {
        started = date
    }

    // MARK: - Annotations

    /// Handles one keystroke.
    ///
    /// Deliberately tiny: flag the moment, or name a slot. Anything more would be a UI, and the
    /// thing being tested is the engine — every key added here is one more way for a smoke test to
    /// report on the harness instead of on the diarizer.
    func key(_ key: Keyboard.Key) {
        // State first, under the lock; drawing after, without it. `draw` takes the lock itself, so
        // holding it across the redraw would deadlock the keyboard thread against the engine's.
        lock.lock()

        if let slot = namingSlot {
            switch key {
            case .enter:
                let trimmed = namingText.trimmingCharacters(in: .whitespaces)
                // An empty name takes one back off, which has to be possible: a name on the wrong
                // slot is worse than no name, and it will happen while someone is learning which
                // slot is which.
                names[slot] = trimmed.isEmpty ? nil : trimmed
                namingSlot = nil
                namingText = ""
            case .escape:
                namingSlot = nil
                namingText = ""
            case .backspace:
                if !namingText.isEmpty { namingText.removeLast() }
            case .character(let character):
                if namingText.count < Self.maximumNameLength { namingText.append(character) }
            case .interrupt:
                break
            }
        } else {
            switch key {
            case .character(let character) where ("1"..."4").contains(character):
                namingSlot = Int(String(character)).map { $0 - 1 }
                namingText = ""
            case .character("f"), .character(" "):
                flags.append(lastStatus?.audioSeconds ?? 0)
            case .character("c"):
                // Correct the slot the newest turn was given, which is the mistake a tester
                // actually notices: the line just written was the wrong colour, and they want to
                // say so without waiting for that slot to come round again.
                if let speaker = lastTurns.last?.speaker {
                    namingSlot = speaker
                    namingText = names[speaker] ?? ""
                }
            default:
                break
            }
        }

        let update = lastUpdate
        lock.unlock()

        // A keystroke is the one event someone is waiting on, so it redraws at once rather than
        // waiting out the throttle.
        draw(update)
    }

    /// Long enough for "Grandma", short enough that it cannot push the label off a narrow line.
    static let maximumNameLength = 12

    var flaggedMoments: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return flags
    }

    var givenNames: [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    /// Leaves the screen and reprints the conversation on the primary one.
    ///
    /// The alternate screen is discarded on exit, which would take the entire transcript with it —
    /// the thing a smoke test produces and the only part of it worth keeping. Reprinting costs
    /// nothing and means a surprising run can be read, scrolled and pasted afterwards.
    func finish(turns: [StreamedTurn]) {
        guard !plain else { return }
        leave()
        guard !turns.isEmpty else {
            print("\nNo speech was transcribed.\n")
            return
        }
        print("")
        print("Transcript — \(options)")
        print(String(repeating: "─", count: 72))
        for turn in turns {
            let label = label(turn).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("\(String(format: "%6.1fs", turn.start))  \(label) \(turn.text)")
        }
        print("")
    }

    func update(_ update: CaptionerUpdate, force: Bool = false) {
        if plain {
            // Only closed turns, and only once: a turn that is still being spoken would be printed
            // again on every chunk.
            let closed = update.turns.filter { !$0.isOpen }
            while printed < closed.count {
                let turn = closed[printed]
                print("\(String(format: "%5.1fs", turn.start))  \(label(turn))  \(turn.text)")
                printed += 1
            }
            return
        }

        lock.lock()
        lastStatus = update.status
        lastTurns = update.turns
        lastUpdate = update
        let now = Date()
        // Rate-limited, because the captioner calls this once per audio chunk and drawing is far
        // more expensive than deciding: an unthrottled build repainted 565 times in ten seconds.
        // The final frame is never dropped, or the last words of a conversation can be decoded and
        // never drawn.
        guard force || update.isFinal || now.timeIntervalSince(lastDraw) >= Self.minimumRedrawInterval
        else {
            lock.unlock()
            return
        }
        lastDraw = now
        lock.unlock()
        draw(update)
    }

    private func draw(_ update: CaptionerUpdate?) {
        let size = terminalSize()
        let width = max(40, size.columns)
        let rows = max(8, size.rows)

        let body = update.map { self.body($0.turns, width: width) } ?? []

        // Six rows of chrome: title, rule, meter, slots, footer, and the prompt or settings line.
        let available = max(1, rows - 6)
        // Show the tail, because the app scrolls and the newest words are the ones being read.
        let visible = body.count > available ? Array(body.suffix(available)) : body

        var out = "\u{1B}[H"
        out += clamp(header(width), to: width) + "\u{1B}[K\n"
        out += String(repeating: "─", count: width) + "\u{1B}[K\n"
        out += clamp(meterRow(update?.status), to: width) + "\u{1B}[K\n"
        out += clamp(slotRow(update?.status), to: width) + "\u{1B}[K\n"
        for line in visible {
            out += clamp(line, to: width) + "\u{1B}[K\n"
        }
        for _ in visible.count..<available {
            out += "\u{1B}[K\n"
        }
        out += clamp(footer(update?.status), to: width) + "\u{1B}[K\n"
        out += clamp(promptOrSettings(), to: width) + "\u{1B}[K"
        write(out)
    }

    // MARK: - Chrome

    /// Title on the left, input source on the right.
    ///
    /// The source is on every frame rather than printed once at the top, because the failure it
    /// guards against is silent: a headset that switched to hands-free mode, or a file that was not
    /// the recording anyone meant, looks exactly like the model being bad.
    private func header(_ width: Int) -> String {
        // Short on purpose. The settings used to live here, which pushed the title past 60 columns
        // and made the source — the thing this row exists to show — the first casualty of a narrow
        // terminal. It has its own row at the bottom now.
        let title = " live captions · Parakeet EOU + Sortformer"

        var right = ""
        if recording != nil {
            right += Self.palette[5] + "● rec" + Self.reset + " "
        }

        // The source is assembled from the outside in and dropped from the outside in: name first,
        // then each detail, and only then the title. A row that shows nothing but the title is a row
        // that has thrown away the one thing it was added for.
        var essentials = ""
        var details: [String] = []
        if let origin = origin() {
            essentials = Self.boldEscape + origin.kind.rawValue + Self.reset + " " + origin.name
            details = origin.details
        }

        func fits(_ left: String, _ right: String) -> Bool {
            Self.displayWidth(left) + Self.displayWidth(right) + 1 < width
        }

        var tail = essentials
        for detail in details where fits(title, right + tail + dim(" · " + detail)) {
            tail += dim(" · " + detail)
        }
        guard !tail.isEmpty else { return Self.boldEscape + title + Self.reset }
        tail += " "

        if fits(title, right + tail) {
            let pad = width - Self.displayWidth(title) - Self.displayWidth(right + tail)
            return Self.boldEscape + title + Self.reset
                + String(repeating: " ", count: pad) + right + tail
        }
        // Not even the source fits beside the title, so the title goes: knowing what is being
        // listened to is worth more than knowing the command is called `stream`.
        let pad = max(1, width - Self.displayWidth(right + tail))
        return String(repeating: " ", count: pad) + right + tail
    }

    /// Level meter, whether there is speech, and who has been talking for how long.
    ///
    /// The talk times are the drift detector. A colour that moves to a different person shows up
    /// here as one slot going quiet while another appears, and unlike a score it is visible during
    /// the conversation rather than after it.
    private func meterRow(_ status: CaptionerStatus?) -> String {
        lock.lock()
        let note = self.note
        lock.unlock()
        if let note { return " " + dim(note) }
        guard let status else { return "" }

        // Peak-hold with decay, so the bar follows the voice rather than the syllable.
        let now = Date()
        let elapsed = lastMeterAt == .distantPast ? 0 : now.timeIntervalSince(lastMeterAt)
        lastMeterAt = now
        let decayed = max(0, displayedLevel - Self.meterDecayPerSecond * Float(elapsed))
        displayedLevel = max(status.normalizedLevel, decayed)

        let meterWidth = min(24, max(10, terminalSize().columns / 4))
        let filled = Int((displayedLevel * Float(meterWidth)).rounded())
        let bar = String(repeating: "█", count: min(meterWidth, max(0, filled)))
            + String(repeating: "▁", count: max(0, meterWidth - filled))

        var row = " ▌ "
        row += status.isSpeaking ? Self.palette[0] + bar + Self.reset : dim(bar)
        row += String(format: "  %4.0f dBFS  ", status.level)
        row += status.isSpeaking ? Self.boldEscape + "speaking" + Self.reset : dim("silent")

        // Speaker chips, most talk time first so the ordering does not reshuffle as slots appear.
        // Numbered rather than named on purpose: this row is the drift detector, and the slot
        // number is what stays comparable when a name turns out to be on the wrong person. The name
        // is on the row below, next to the same colour.
        let ranked = status.talkTime.sorted { ($0.value, $0.key) > ($1.value, $0.key) }
        for (speaker, seconds) in ranked {
            let colour = Self.palette[speaker % Self.palette.count]
            row += "  " + colour + "█\(speaker + 1)" + Self.reset + dim(" " + Self.clock(seconds))
        }
        return row
    }

    /// One bar per slot: how much of the last second the diarizer thinks that slot was speaking.
    ///
    /// This is the row that explains a colour while it is happening. `talkTime` on the row above is
    /// a running total and barely moves; here a slot that is dark while the text is being coloured
    /// with it, or two bars up at once, is the diarizer's confusion made visible at the moment it
    /// matters rather than several seconds later when the transcript settles.
    private func slotRow(_ status: CaptionerStatus?) -> String {
        guard let status, !status.slotActivity.isEmpty else { return "" }

        // Sorted by name so the bars stay in one place. Ranked by talk time they would reshuffle as
        // the conversation moves, and a row that reorders itself is unreadable while it is the only
        // thing on screen moving faster than the transcript.
        var row = " ▌ "
        var first = true
        for (slot, activity) in status.slotActivity.enumerated() {
            if !first { row += "  " }
            first = false

            lock.lock()
            let name = names[slot]
            lock.unlock()

            let colour = Self.palette[slot % Self.palette.count]
            let lit = Int((activity * Double(Self.slotBarWidth)).rounded())
            // A dim floor rather than an empty one, so a slot that has never spoken still has a
            // place on the row and the reader can see the app is listening to four people.
            let bar = String(repeating: "▄", count: lit)
                + String(repeating: "▁", count: max(0, Self.slotBarWidth - lit))
            row += colour + bar + Self.reset
            row += name.map { " " + $0 } ?? dim(" \(slot + 1)")
        }
        return row
    }

    static let slotBarWidth = 8

    /// Position and engine load. The load figure is the one that says whether any of this is
    /// usable: a live pipeline that has fallen behind still produces correct text, just late, and
    /// nothing in the transcript admits it.
    ///
    /// Load rather than a wall-clock ratio, because a wall-clock ratio at `--speed 6` reports the
    /// speed of the file source and says nothing about the engine. Load is engine time per second
    /// of audio, so it reads the same whether the audio arrived live or was fast-forwarded.
    private func footer(_ status: CaptionerStatus?) -> String {
        guard let status else { return "" }

        var parts: [String] = []
        if let duration = status.sourceDuration {
            parts.append("\(Self.clock(status.audioSeconds)) / \(Self.clock(duration))")
        } else {
            parts.append(Self.clock(status.audioSeconds))
        }

        let behind = status.processingLoad > 1
        let load = String(format: "%.2f×", status.processingLoad)
        parts.append(behind
            ? Self.palette[5] + "load \(load) — behind" + Self.reset
            : "load \(load)")
        parts.append("\(status.turns) turns · \(status.words) words")
        if status.contestedTurns > 0 {
            parts.append("\(status.contestedTurns) contested")
        }

        // Flags are shown with the clock they were taken at, because a count is not actionable and
        // the time is: it is the difference between "four things looked wrong" and being able to
        // open the dump at 2:31.
        lock.lock()
        let flags = flags
        lock.unlock()
        if !flags.isEmpty {
            let stamps = flags.suffix(3).map(Self.clock).joined(separator: " ")
            parts.append(Self.palette[5] + "⚑ \(flags.count)" + Self.reset + " " + stamps)
        }

        if stats || behind {
            parts.append(String(format: "update %.0f ms · worst %.0f ms",
                                status.lastUpdateSeconds * 1000,
                                status.recentSlowestUpdateSeconds * 1000))
            parts.append("\(status.updates) updates")
        }

        let separator = " \(Self.dimEscape)·\(Self.reset) "
        return " " + parts.joined(separator: separator) + " "
    }

    /// The exact configuration, along the bottom.
    ///
    /// A smoke test that produces a surprising result is only worth reporting if the settings that
    /// produced it are on screen — and the flags that move the most are the ones nobody remembers
    /// changing.
    /// The naming prompt while one is open, and the settings line the rest of the time.
    ///
    /// The prompt takes the row over rather than appearing somewhere new: a line that comes and goes
    /// would shift the transcript, and the transcript is the thing being watched.
    private func promptOrSettings() -> String {
        lock.lock()
        let slot = namingSlot
        let typed = namingText
        lock.unlock()

        guard let slot else { return settingsLine() }
        return " Name slot \(slot + 1): " + Self.boldEscape + typed + Self.reset
            + dim("▏  ⏎ accept · esc cancel · empty to clear")
    }

    private func settingsLine() -> String {
        // The legend is not optional: `Speaker 2+` is unreadable without it, and an unexplained
        // marker on a screen built for judging the output is worse than no marker. "colour may be
        // wrong" rather than "two voices at once", because that is the part the reader has to act
        // on — the marker is a caveat, not a description of the audio.
        //
        // The options come before the keys so that a narrow terminal drops the keys, which are
        // learnable once, rather than the settings, which are the record of what was being tested.
        " " + dim(options) + dim("   ·   N+ = crosstalk   ·   space flag · 1-4 name · c correct")
    }

    // MARK: - Turns

    /// What a turn is called on screen, in both the drawn and the plain rendering.
    ///
    /// One function rather than two, because the `+` is the honest part of the label and the plain
    /// rendering is the one people diff between runs — a caveat that only appears in the version
    /// nobody is comparing would be worse than not having it.
    ///
    /// The `+` means the model had more than one slot over threshold at once, so it was choosing.
    /// A rare marker — around 2% of a DiPCo session — because streaming Sortformer is decisive
    /// about who is speaking, and it is not always right to be.
    ///
    /// A name, once given, replaces the number — and carries the slot's number with it, because the
    /// name is a label on the *slot*. Slots drift: measured on DiPCo the slot-to-person mapping held
    /// for a whole recording in four sessions of five, which means one dinner in five ends with a
    /// name on the wrong person. Anonymous, a drifted colour is a curiosity; named, it is the app
    /// telling someone their daughter is their son.
    func label(_ turn: StreamedTurn) -> String {
        guard let speaker = turn.speaker else { return "—" }
        lock.lock()
        let name = names[speaker]
        lock.unlock()
        // Named slots keep their number as well, so a drift is visible as a mismatch against the
        // talk-time chips rather than hidden behind a plausible word.
        let base = name.map { "\($0) (\(speaker + 1))" } ?? "Speaker \(speaker + 1)"
        return turn.isContested ? base + "+" : base
    }

    /// One entry per visual line, already coloured.
    private func body(_ turns: [StreamedTurn], width: Int) -> [String] {
        var lines: [String] = []
        for turn in turns {
            let label = label(turn)
            let colour = turn.speaker.map { Self.palette[$0 % Self.palette.count] } ?? Self.dimEscape
            let stamp = String(format: "%5.1fs ", turn.start)

            // The open turn is the one still being spoken, so it gets the inverse marker: without
            // it there is no way to tell "this person finished talking" from "the app has not
            // caught up yet", and the second is the whole reason to watch this run.
            let marker = turn.isOpen ? "▌" : " "

            let prefix = dim(stamp) + colour + label + Self.reset
            let indent = String(repeating: " ", count: min(width - 10, stamp.count + label.count + 2))
            let textWidth = max(12, width - indent.count - 2)

            let words = turn.text.split(separator: " ").map(String.init)
            var visual: [String] = []
            var current = ""
            for word in words {
                if current.isEmpty {
                    current = word
                } else if current.count + 1 + word.count <= textWidth {
                    current += " " + word
                } else {
                    visual.append(current)
                    current = word
                }
            }
            if !current.isEmpty { visual.append(current) }
            if visual.isEmpty { visual = [""] }

            for (index, line) in visual.enumerated() {
                let lead = index == 0 ? prefix + "  " : indent
                // A closed turn is left alone; only the open one flickers as its colour is revised.
                let text = turn.isOpen ? colour + line + Self.reset : line
                let tail = index == visual.count - 1 && turn.isOpen ? dim(marker) : ""
                lines.append(lead + text + tail)
            }
        }
        return lines
    }

    // MARK: - Text

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Columns a string occupies, ignoring escape sequences.
    static func displayWidth(_ text: String) -> Int {
        var width = 0
        var escaping = false
        for character in text {
            if escaping {
                if character == "m" { escaping = false }
                continue
            }
            if character == "\u{1B}" {
                escaping = true
                continue
            }
            width += 1
        }
        return width
    }

    /// Truncates to `width` columns without splitting an escape sequence, so a long line is cut
    /// rather than wrapped — a wrapped status line shifts every row below it and the screen
    /// corrupts for the rest of the session.
    private func clamp(_ line: String, to width: Int) -> String {
        guard Self.displayWidth(line) > width else { return line }
        var out = ""
        var columns = 0
        var escaping = false
        for character in line {
            if escaping {
                out.append(character)
                if character == "m" { escaping = false }
                continue
            }
            if character == "\u{1B}" {
                escaping = true
                out.append(character)
                continue
            }
            if columns >= width - 1 { break }
            out.append(character)
            columns += 1
        }
        return out + Self.reset
    }
}

// MARK: - Keyboard

/// Single-keystroke input while the run is going, so a smoke test can be annotated as it happens.
///
/// This exists because the feedback loop was otherwise lossy in the worst way: something looks wrong
/// at about two minutes in, the session ends, and what crosses back is "the colours went weird
/// somewhere in the middle". A keypress that stamps the audio clock turns that into a moment the
/// dump can be opened at.
///
/// Raw mode and a reading thread rather than a run loop, because the main actor is busy decoding:
/// the reader must not be able to block the engine, and the engine must not be able to drop a
/// keypress. Nothing here needs to be delivered quickly — a few frames of latency is invisible — so
/// the thread simply sleeps and hands whole keys to the callback.
final class Keyboard: @unchecked Sendable {

    enum Key: Equatable {
        case character(Character)
        case enter
        case escape
        case backspace
        case interrupt
    }

    private let lock = NSLock()
    private var original: termios?
    private var running = true
    private let handler: (Key) -> Void

    /// The live instance, so a signal arriving on another thread can put the terminal back. One
    /// session at a time, and `nil` as soon as it has restored.
    private static let activeLock = NSLock()
    private static var active: Keyboard?
    private static var sources: [DispatchSourceSignal] = []

    /// - Returns: nil when stdin is not a terminal — a piped run, or `--plain` — in which case
    ///   there is nothing to read and no state to restore.
    init?(handler: @escaping (Key) -> Void) {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else { return nil }
        self.handler = handler
        original = current

        // Non-canonical so a key arrives without Enter, and no echo because the renderer owns every
        // cell of the screen — an echoed character would land wherever the cursor happens to be and
        // corrupt the frame until the next repaint.
        //
        // ISIG goes too, which is the part that matters most: leaving it on means Ctrl-C raises
        // SIGINT and kills the process with the terminal still in raw mode, so the shell is left
        // without echo and every subsequent command is typed blind. Clearing it turns Ctrl-C into
        // an ordinary byte this object can see, which is what lets the run stop the way it always
        // does — transcript reprinted, dump written, terminal restored.
        var raw = current
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        raw.c_cc.0 = 1     // VMIN: return as soon as one byte is available
        raw.c_cc.1 = 0     // VTIME: never wait for more
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            self.original = nil
            return nil
        }

        Self.installSignalSafetyNet()
        Self.activeLock.lock()
        Self.active = self
        Self.activeLock.unlock()

        let thread = Thread { [weak self] in self?.read() }
        thread.stackSize = 256 * 1024
        thread.start()
    }

    deinit { restore() }

    /// A kill from outside — `kill`, a closing terminal, a `timeout` wrapper — cannot be turned into
    /// a keystroke, so the terminal has to be put back from the signal itself. The keyboard's own
    /// Ctrl-C never comes through here.
    private static func installSignalSafetyNet() {
        activeLock.lock()
        defer { activeLock.unlock() }
        guard sources.isEmpty else { return }

        let queue = DispatchQueue(label: "live-caption.signals")
        for number in [SIGINT, SIGTERM, SIGHUP] {
            // The default disposition is replaced by the source, but it must not *also* fire, or the
            // process dies before the handler runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                restore()
                _exit(130)
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Puts the terminal back, once, from whichever thread gets here first.
    static func restore() {
        activeLock.lock()
        let keyboard = active
        active = nil
        activeLock.unlock()
        keyboard?.restore()
    }

    func restore() {
        lock.lock()
        let saved = original
        original = nil
        running = false
        lock.unlock()
        guard var saved else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    private func read() {
        var byte: UInt8 = 0
        while true {
            lock.lock()
            let alive = running
            lock.unlock()
            guard alive else { return }

            let count = Foundation.read(STDIN_FILENO, &byte, 1)
            guard count == 1 else { continue }
            guard let key = Self.key(byte) else { continue }
            handler(key)
        }
    }

    /// Only the keys the harness acts on, and nothing else: a reader that forwarded everything
    /// would be a keyboard logger, and this one is attached to whatever is typed into the terminal
    /// for the length of a session.
    private static func key(_ byte: UInt8) -> Key? {
        switch byte {
        case 0x0A, 0x0D: return .enter
        case 0x1B: return .escape
        case 0x7F, 0x08: return .backspace
        case 0x03: return .interrupt
        default:
            guard let scalar = Unicode.Scalar(UInt32(byte)), scalar.isASCII else { return nil }
            return .character(Character(scalar))
        }
    }
}

// MARK: - Terminal

struct TerminalSize {
    var rows: Int
    var columns: Int

    /// Reads the current size, which changes when the window is resized mid-run.
    static func current() throws -> TerminalSize {
        #if canImport(Darwin)
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 {
            return TerminalSize(rows: Int(size.ws_row), columns: Int(size.ws_col))
        }
        #endif
        // A non-tty (a pipe, a test harness) reports no size; 80x24 is the conventional stand-in.
        return TerminalSize(rows: 24, columns: 80)
    }

    func current() -> TerminalSize { (try? TerminalSize.current()) ?? self }
}
