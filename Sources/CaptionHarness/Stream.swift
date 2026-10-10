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
/// Nothing here is scored. The numbers that justify these two models are in ENGINES.md, measured
/// over ten sessions of the DiPCo corpus; this is for finding out whether the thing those numbers
/// describe is actually pleasant to sit in front of.
///
/// **Read the colours as a hint, not a fact.** Sortformer is right about 72% of the time on turns of
/// two seconds or more, and its slot identities hold steady for a whole recording in about five
/// sessions out of six. When it drifts, a colour moves to a different person mid-conversation —
/// which is precisely the failure a reader cannot detect and will not forgive.
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

    @Flag(name: .long, help: "Print turns as they close, no redrawing — for piping to a file.")
    var plain: Bool = false

    @Flag(name: .long, help: "Show recogniser and diarizer timing on the status line.")
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

        let plain = self.plain || isatty(STDOUT_FILENO) != 1
        let renderer = StreamRenderer(plain: plain, stats: stats) { size.current() }

        if !plain { renderer.enter() }
        defer { if !plain { renderer.leave() } }

        renderer.note("loading models… this is slow the first time")
        try await captioner.prepare { message in renderer.note(message) }
        renderer.clearNote()

        let source: LiveAudioSource
        if let fromFile {
            source = FileAudioSource(
                url: URL(fileURLWithPath: fromFile),
                speed: speed,
                limitSeconds: maxSeconds
            )
        } else {
            source = MicrophoneAudioSource()
        }

        renderer.begin(at: Date())
        do {
            try await captioner.run(source: source) { turns, isFinal in
                renderer.update(turns, isFinal: isFinal)
            }
        } catch {
            if !plain { renderer.leave() }
            throw error
        }
        await source.stop()
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

    /// ~12 fps. Fast enough that text appears to arrive with the speech, slow enough that the
    /// terminal is not asked to repaint faster than anyone can read.
    private static let minimumRedrawInterval: TimeInterval = 0.08

    private let plain: Bool
    private let stats: Bool
    private let terminalSize: () -> TerminalSize
    private let lock = NSLock()

    private var started = Date()
    private var note: String?
    private var printed = 0
    private var lastDraw = Date.distantPast
    private var peaks: [Double] = []

    init(plain: Bool, stats: Bool, size: @escaping () -> TerminalSize) {
        self.plain = plain
        self.stats = stats
        self.terminalSize = size
    }

    func enter() {
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func leave() {
        write("\u{1B}[?25h\u{1B}[?1049l")
    }

    func note(_ message: String) {
        guard !plain else { return }
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

    func update(_ turns: [StreamedTurn], isFinal: Bool) {
        if plain {
            // Only closed turns, and only once: a turn that is still being spoken would be printed
            // again on every chunk.
            var closed = turns.filter { !$0.isOpen }
            while printed < closed.count {
                let turn = closed[printed]
                let label = turn.speaker.map { "Speaker \($0 + 1)" } ?? "—"
                print("\(turn.start.formatted(.number.precision(.fractionLength(1))))s  \(label)  \(turn.text)")
                printed += 1
            }
            closed.removeAll()
            return
        }
        lock.lock()
        let now = Date()
        // Rate-limited, because the captioner calls this once per 100 ms audio chunk and drawing is
        // far more expensive than deciding: an unthrottled build repainted 565 times in ten
        // seconds. The final frame is never dropped — see the note on `run`.
        guard isFinal || now.timeIntervalSince(lastDraw) >= Self.minimumRedrawInterval else {
            lock.unlock()
            return
        }
        lastDraw = now
        lock.unlock()
        draw(turns)
    }

    private func draw(_ turns: [StreamedTurn]?) {
        guard let size = try? terminalSize() else { return }
        let width = max(20, size.columns)
        let rows = max(4, size.rows)

        var body: [String] = []
        if let turns {
            let since = Date().timeIntervalSince(started)
            body = self.body(turns, width: width, since: since)
        }

        // Show the tail, because the app scrolls and the newest words are the ones being read.
        let available = rows - 3
        let visible = body.count > available ? Array(body.suffix(available)) : body

        var out = "\u{1B}[H"
        out += header(size.columns)
        out += "\n" + String(repeating: "─", count: width) + "\u{1B}[K\n"
        for line in visible {
            out += line + "\u{1B}[K\n"
        }
        for _ in visible.count..<available {
            out += "\u{1B}[K\n"
        }
        out += status(width)
        write(out)
    }

    private func header(_ columns: Int) -> String {
        let title = "live captions · Parakeet EOU + Sortformer"
        guard let note else { return bold(title) + "\u{1B}[K" }
        return bold(title) + "   " + dim(note) + "\u{1B}[K"
    }

    private func status(_ columns: Int) -> String {
        let elapsed = Date().timeIntervalSince(started)
        let clock = String(format: "%6.1fs", elapsed)
        guard stats else { return dim("\(clock)  ·  colours are a hint, not a guarantee") + "\u{1B}[K" }
        let peak = peaks.max().map { String(format: "%.0f ms", $0) } ?? "—"
        return dim("\(clock)  ·  slowest update \(peak)") + "\u{1B}[K"
    }

    /// One entry per visual line, already coloured.
    private func body(_ turns: [StreamedTurn], width: Int, since: Double) -> [String] {
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

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
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
