import ArgumentParser
import CaptionKit
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
        abstract: "Live captions with speaker colours: Parakeet EOU + streaming Sortformer.",
        discussion: """
        Captures the microphone and prints one colour per speaker as the words arrive. With \
        --from-file the identical pipeline runs off a recording instead, which is how this is \
        tested without asking anyone to talk into a laptop.

        The two models are the ones the measurements point at. Words come from Parakeet EOU at \
        320 ms, not from Whisper and not from batch Parakeet: the batch TDT export re-encodes 5.6 \
        seconds of left context per 80 ms chunk and runs slower than real time, so it cannot be used \
        live however accurate it is on a file. Speakers come from streaming Sortformer, which beat \
        every LS-EEND variant on all ten DiPCo sessions.

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

    @Option(name: .long, help: "Audio chunks, in ms, that the recogniser works on: 160, 320 or 1280.")
    var chunkMs: Int = 320

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

    @Flag(name: .long, help: "Print turns as they close, no redrawing — for piping to a file.")
    var plain: Bool = false

    @Flag(name: .long, help: "Show engine timing on the status line all the time, not only when behind.")
    var stats: Bool = false

    func run() async throws {
        guard let size = try? TerminalSize.current() else {
            throw ValidationError("could not read the terminal size")
        }

        var options = StreamingCaptioner.Options()
        switch chunkMs {
        case 160: options.chunkSize = .ms160
        case 320: options.chunkSize = .ms320
        case 1280: options.chunkSize = .ms1280
        default: throw ValidationError("--chunk-ms must be 160, 320 or 1280")
        }
        options.eouDebounceMs = eouDebounceMs
        options.minTurnSeconds = minTurn

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

        if !plain { renderer.enter() }
        renderer.note("loading models… this is slow the first time")
        try await captioner.prepare { message in renderer.note(message) }
        renderer.clearNote()

        let session = Session(recorder: recorder, renderer: renderer)

        renderer.begin(at: Date())
        do {
            try await captioner.run(source: source) { update in
                session.receive(update)
            }
        } catch {
            if !plain { renderer.leave() }
            throw error
        }
        await source.stop()

        if let recorder {
            try recorder.finish()
            renderer.note("wrote \(recorder.url.path)")
        }
        if !plain { renderer.finish(turns: session.turns) }
    }

    /// The settings, as one line for the title. A smoke test that produces a surprising result is
    /// only useful if the settings that produced it are on screen.
    ///
    /// `chunkMs`, not `chunkSize.durationMs`: upstream's own property returns 630 for `.ms320`,
    /// because that is how much audio the manager accumulates before each decode. Its shift is the
    /// 320 ms the mode is named for, and its own source comment says so — "~630ms of audio per
    /// chunk (but 320ms latency due to shift)". Printing 630 would have doubled the apparent
    /// latency on the one display built for judging latency.
    private func settings(_ options: StreamingCaptioner.Options) -> String {
        "EOU \(chunkMs) ms · debounce \(options.eouDebounceMs) ms · min turn "
            + String(format: "%.2f s", options.minTurnSeconds)
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

    init(recorder: SessionRecorder?, renderer: StreamRenderer) {
        self.recorder = recorder
        self.renderer = renderer
    }

    func receive(_ update: CaptionerUpdate) {
        lock.lock()
        latest = update.turns
        lock.unlock()

        recorder?.append(update.audio)
        renderer.update(update)
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

    func begin(at date: Date) {
        started = date
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
            let label = turn.speaker.map { "Speaker \($0 + 1)" } ?? "—"
            print("\(String(format: "%6.1fs", turn.start))  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(turn.text)")
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
                let label = turn.speaker.map { "Speaker \($0 + 1)" } ?? "—"
                print("\(String(format: "%5.1fs", turn.start))  \(label)  \(turn.text)")
                printed += 1
            }
            return
        }

        lock.lock()
        lastStatus = update.status
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

        // Five rows of chrome: title, rule, meter, footer, settings.
        let available = max(1, rows - 5)
        // Show the tail, because the app scrolls and the newest words are the ones being read.
        let visible = body.count > available ? Array(body.suffix(available)) : body

        var out = "\u{1B}[H"
        out += clamp(header(width), to: width) + "\u{1B}[K\n"
        out += String(repeating: "─", count: width) + "\u{1B}[K\n"
        out += clamp(meterRow(update?.status), to: width) + "\u{1B}[K\n"
        for line in visible {
            out += clamp(line, to: width) + "\u{1B}[K\n"
        }
        for _ in visible.count..<available {
            out += "\u{1B}[K\n"
        }
        out += clamp(footer(update?.status), to: width) + "\u{1B}[K\n"
        out += clamp(settingsLine(), to: width) + "\u{1B}[K"
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
        let ranked = status.talkTime.sorted { ($0.value, $0.key) > ($1.value, $0.key) }
        for (speaker, seconds) in ranked {
            let colour = Self.palette[speaker % Self.palette.count]
            row += "  " + colour + "█\(speaker + 1)" + Self.reset + dim(" " + Self.clock(seconds))
        }
        return row
    }

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
    private func settingsLine() -> String {
        " " + dim(options)
    }

    // MARK: - Turns

    /// One entry per visual line, already coloured.
    private func body(_ turns: [StreamedTurn], width: Int) -> [String] {
        var lines: [String] = []
        for turn in turns {
            let label = turn.speaker.map { "Speaker \($0 + 1)" } ?? "—"
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
