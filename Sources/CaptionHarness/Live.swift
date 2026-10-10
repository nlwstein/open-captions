import ArgumentParser
import CaptionKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - live

struct Live: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "Captions the Mac's microphone as it happens, breaking turns where speech stops.",
        discussion: """
        Nothing is scored here — there is no reference transcript for a live conversation. This \
        exists to show what the app's screen would do and to prove the engine keeps up, before any \
        iOS shell is built.

        With --from-file the same loop runs off a recording instead of the microphone, which is how \
        the live path is regression-tested: identical buffering, segmentation and rendering, no \
        person required to talk into a laptop.
        """
    )

    @OptionGroup var modelOptions: ModelOptions

    @Option(name: .long, help: "Play a file into the live loop instead of capturing the microphone.")
    var fromFile: String?

    @Option(name: .long, help: "Wall-clock multiplier when using --from-file. 1 is real time.")
    var speed: Double = 1

    @Option(name: .long, help: "Stop after this many seconds of audio.")
    var maxSeconds: Double?

    @Option(name: .long, help: "Silence, in seconds, that closes a turn.")
    var silence: Double = 0.8

    @Option(name: .long, help: "Comma-separated names to tag as critical information.")
    var names: String = ""

    @Flag(name: .long, help: "One line per turn, no redrawing — for piping to a file.")
    var plain: Bool = false

    @Flag(name: .long, help: "Skip the cold-start warm-up. The first turn will be slower.")
    var noWarmUp: Bool = false

    @Flag(name: .long, help: "Log every decode to stderr: what it saw and what it committed.")
    var verbose: Bool = false

    /// The gate is the reason a decode gets discarded, so measuring what it costs needs a run with
    /// it switched off — same flags, same fixture, same machine. Without that, a fixture that loses
    /// its tail has two candidate explanations (the gate, or a decoder that never produced the text
    /// at all) and no way to choose between them.
    @Flag(name: .long, help: "Let every decode through, including bracketed non-speech.")
    var noSpeechGate: Bool = false

    /// The live loop cannot use the model the offline report measures, and the difference is not a
    /// tuning preference — it is the difference between keeping up and not.
    ///
    /// Measured over the same eight fixtures, whole-file decode time as a fraction of audio time is
    /// 0.571 for large-v3-turbo against 0.065 for small, and time-to-first-word on a 10-second clip
    /// is 2054 ms against 169 ms. Whole-file figures flatter turbo, though, because it decodes one
    /// window instead of a growing slice every few seconds. In the live loop itself the real-time
    /// factors are **3.40** against 0.12–0.42 — and at 3.40 the queue of undecoded audio grows
    /// faster than the recognizer drains it, so the lag never recovers. Measured: turbo needed
    /// 170.9 s of wall clock to caption a 46.7 s recording. Small holds the sub-200 ms first word
    /// that makes text appear while someone is still talking.
    ///
    /// It costs accuracy: mean word error rate 28.5% against turbo's 17.8%, and 78.3% critical
    /// information against 87.0%. That trade is the whole point of the exercise — the numbers are
    /// in the README so the trade can be argued with rather than assumed.
    static let liveModel = "openai_whisper-small"

    func run() async throws {
        let engine = WhisperEngine(configuration: modelOptions.configuration(default: Self.liveModel))

        let knownNames = Set(
            names.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )

        let state = RunState()
        let interrupt = installInterruptHandler(state)

        let liveModel = modelOptions.resolvedModel(default: Self.liveModel)
        if modelOptions.model == nil {
            let note = "Live runs on \(Self.liveModel): large-v3-turbo is ~9x slower and falls "
                + "behind. Pass --model to override.\n"
            FileHandle.standardError.write(Data(note.utf8))
        }

        // The source is built and started before the model is loaded, so the microphone is live from
        // the moment the user is ready rather than a second or two later. `LiveTranscriber.run` does
        // the ordering; all that is needed here is to hand it the warm-up as a closure.
        let source = try makeSource()
        let display = LiveDisplay(
            knownNames: knownNames,
            plain: plain || !isatty(STDOUT_FILENO).isTTY
        )
        display.begin()

        if silence != 0.8 {
            FileHandle.standardError.write(Data(
                "Turn silence is \(silence)s, not the 0.8s the offline report measures with.\n".utf8
            ))
        }
        var configuration = LiveConfiguration()
        configuration.silenceGap = silence
        if noSpeechGate {
            configuration.speechGate = .open
            FileHandle.standardError.write(Data("Speech gate off — non-speech decodes will be shown.\n".utf8))
        }

        let transcriber = LiveTranscriber(engine: engine, configuration: configuration)
        var diagnosticSink: (@Sendable (LiveDecodeDiagnostic) -> Void)?
        if verbose { diagnosticSink = Live.logDecodeSink }

        var warmUpAction: (@Sendable () async -> Void)?
        if !noWarmUp {
            warmUpAction = {
                FileHandle.standardError.write(Data("Loading \(liveModel)…\n".utf8))
                await Self.warmUp(engine, fromFile: fromFile)
            }
        }

        let session = try await transcriber.run(
            source: source,
            warmUp: warmUpAction,
            shouldContinue: { state.isRunning },
            onUpdate: { display.update($0) },
            onDecode: diagnosticSink
        )

        display.end()

        // Printed outside the alternate screen, so the session survives in scrollback after the
        // display tears down — the same text the app would have left on screen.
        if !display.isPlain, !session.turns.isEmpty {
            print("")
            print("Session — \(session.turns.count) turn(s), "
                + "\(formatClock(session.audioSeconds))")
            for turn in session.turns {
                print("  [\(formatClock(Double(turn.start)))] \(turn.text)")
            }
        }

        // The numbers that decide whether this can be the app: how much of the recognizer's time a
        // second of conversation costs, and how many decodes it took to keep that up. Goes to
        // stderr so the transcript on stdout stays pipeable.
        FileHandle.standardError.write(Data(String(
            format: """
            %d decode(s) over %.1fs of audio — %.2fs each, live real-time factor %.2f%@
            wall clock %.1fs

            """,
            session.decodes,
            session.audioSeconds,
            session.meanDecodeSeconds,
            session.realTimeFactor,
            session.fallbacks > 0 ? ", \(session.fallbacks) fallback(s)" : "",
            session.wallSeconds
        ).utf8))

        // Speech the user did not see. A small uncovered tail is the silence after the last word —
        // read it against the audio behind the last commit, which is usually the same number. They
        // diverge only when the meter heard speech the transcript never showed.
        let coverage = String(
            format: "  %.1fs of audio after the last word, %.1fs of it heard as speech%@\n"
                + "  %d slice(s) rescued by re-decoding from an earlier start\n"
                + "  %d decode(s) dropped as non-speech\n\n",
            session.trailingAudio,
            session.uncoveredSpeech,
            session.uncoveredSpeech > 1.0 ? "  — speech went unshown" : "",
            session.recoveries,
            session.gatedDecodes
        )
        FileHandle.standardError.write(Data(coverage.utf8))

        interrupt.cancel()
        await engine.unload()
    }

    /// One line per decode, so a live loop that drops or repeats audio can be read rather than
    /// guessed at.
    static let logDecodeSink: @Sendable (LiveDecodeDiagnostic) -> Void = { logDecode($0) }

    static func logDecode(_ diagnostic: LiveDecodeDiagnostic) {
        var line = String(
            format: "decode%@ [%6.1fs +%5.1fs] %3d words (%3d decoded), last ends %6.1fs "
                + "→ %d turn(s), %d closed, committed to %6.1fs in %.2fs%@",
            diagnostic.forced ? "*" : " ",
            diagnostic.sliceStart,
            diagnostic.sliceSeconds,
            diagnostic.words,
            diagnostic.rawWords,
            diagnostic.lastWordEnd,
            diagnostic.turns,
            diagnostic.closed,
            diagnostic.committedTo,
            diagnostic.seconds,
            (diagnostic.recovered ? "  RECOVERED" : "")
                + (diagnostic.gate.map { "  DROPPED \($0.rawValue)" } ?? "")
        )
        // The decoder's own opinion of the window, spelled out rather than abbreviated: `ns` is the
        // probability it holds no speech, `lp` the mean log-probability of what it produced (high is
        // confident, and confidently wrong is the failure that matters), `cr` the compression ratio
        // that catches a decoder looping on itself, and `t` the fallback temperature.
        if let quality = diagnostic.quality {
            line += String(
                format: "  ns %.2f lp %+.2f cr %.2f t %.1f",
                quality.noSpeechProbability,
                quality.averageLogProbability,
                quality.compressionRatio,
                quality.temperature
            )
        }
        // Quoted, so a dropped line can be judged rather than counted. A gate that eats real speech
        // is worse than the hallucination it was built to stop, and a word count cannot tell them
        // apart.
        if let dropped = diagnostic.droppedText {
            line += "  »\(dropped)«"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func makeSource() throws -> LiveAudioSource {
        guard let fromFile else { return MicrophoneAudioSource() }
        let url = URL(fileURLWithPath: (fromFile as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No file at \(url.path)")
        }
        return FileAudioSource(url: url, speed: speed, limitSeconds: maxSeconds)
    }

    /// Pays the CoreML specialization cost on real speech before the session starts, so the first
    /// thing the user says is not the thing that pays for it. Borrows a fixture when one is
    /// available; the microphone path has no audio to borrow, and a synthesised buffer is worse than
    /// nothing here (silence skips the decode path entirely, and noise makes the decoder hallucinate
    /// a full window of tokens).
    /// Static, so the closure that hands it to the loop captures the engine and a path rather than
    /// the command itself.
    ///
    /// Failures are swallowed on purpose: this is an optimisation, and a warm-up that cannot find
    /// audio should cost the first turn its speed, not the session its run.
    private static func warmUp(_ engine: WhisperEngine, fromFile: String?) async {
        if let fromFile {
            let url = URL(fileURLWithPath: (fromFile as NSString).expandingTildeInPath)
            _ = try? await engine.warmUp(audioPath: url.path)
            return
        }
        if let root = FixtureLibrary.locate(explicit: nil),
           let fixture = try? FixtureLibrary(root: root).fixture(named: "quiet-single-speaker") {
            _ = try? await engine.warmUp(audioPath: fixture.audioURL.path)
            return
        }
        try? await engine.load()
    }
}

// MARK: - Interrupt handling

/// A flag the Ctrl-C handler can clear and the live loop can read.
final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}

/// Turns Ctrl-C into an orderly stop rather than an immediate exit, so the display is torn down and
/// the tail of the session is flushed. Default SIGINT handling would kill the process mid-decode and
/// leave the terminal in the alternate screen.
private func installInterruptHandler(_ state: RunState) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { state.stop() }
    source.resume()
    return source
}

// MARK: - Display

/// Renders the live session the way the app would show it: finished turns as blocks of text, the
/// turn still being spoken beneath them, and the critical words tagged as they arrive.
///
/// Uses the alternate screen buffer, so the redrawing never scrolls the user's terminal and Ctrl-C
/// leaves their scrollback exactly as it was.
final class LiveDisplay: @unchecked Sendable {

    let isPlain: Bool

    private let knownNames: Set<String>
    private let lock = NSLock()

    private var turns: [CaptionTurn] = []
    private var provisional: CaptionTurn?
    private var latest = LiveUpdate()
    private var lastDraw: Double = 0
    private var started = false
    private var printedCount = 0

    init(knownNames: Set<String>, plain: Bool) {
        self.knownNames = knownNames
        self.isPlain = plain
    }

    func begin() {
        guard !isPlain else { return }
        started = true
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func end() {
        guard started else { return }
        write("\u{1B}[?25h\u{1B}[?1049l")
        started = false
    }

    func update(_ update: LiveUpdate) {
        lock.lock()
        defer { lock.unlock() }

        turns.append(contentsOf: update.newTurns)
        provisional = update.provisional
        latest = update

        if isPlain {
            // Piped output cannot be redrawn, and should not be: one line per turn, in order, is
            // what a log wants.
            while printedCount < turns.count {
                print(turns[printedCount].text)
                printedCount += 1
            }
            return
        }

        // The loop delivers an update per 100 ms chunk; the terminal does not need 10 redraws a
        // second to look live.
        guard update.elapsed - lastDraw >= 0.08 || update.isFinal else { return }
        lastDraw = update.elapsed
        draw()
    }

    // MARK: - Rendering

    private func draw() {
        let size = terminalSize()
        let body = max(3, size.rows - 3)
        var lines = wrappedBody()

        if lines.count > body {
            lines = ["  ⋮"] + lines.suffix(body - 1)
        }

        var out = "\u{1B}[H"
        out += header(size.columns) + "\u{1B}[K\n"
        out += String(repeating: "─", count: max(1, size.columns)) + "\u{1B}[K\n"
        for line in lines {
            out += line + "\u{1B}[K\n"
        }
        for _ in lines.count..<body {
            out += "\u{1B}[K\n"
        }
        out += status(size.columns) + "\u{1B}[K"
        write(out)
    }

    /// The finished turns, then the provisional one, each wrapped and with critical words tagged.
    private func wrappedBody() -> [String] {
        var lines: [String] = []
        for turn in turns {
            lines.append("")
            lines += wrap(tagged(turn.text), width: bodyWidth)
        }
        if let provisional {
            lines.append("")
            lines += wrap(dim("▍" + tagged(provisional.text)), width: bodyWidth)
        }
        if turns.isEmpty, provisional == nil {
            lines.append("")
            lines.append(dim("  waiting for speech…"))
        }
        return lines
    }

    private var bodyWidth: Int { max(20, terminalSize().columns - 2) }

    private func header(_ columns: Int) -> String {
        let left = " live-caption"
        let clock = formatClock(latest.elapsed)
        let right = latest.level.isSpeaking ? "● listening  \(clock) " : "○ quiet      \(clock) "
        let gap = max(1, columns - left.count - right.count)
        return bold(left) + String(repeating: " ", count: gap) + right
    }

    private func status(_ columns: Int) -> String {
        let meter = latest.level.bar(width: 12)
        let lag = String(format: "lag %.1fs", latest.lag)
        let decodes = "\(latest.decodes) decode\(latest.decodes == 1 ? "" : "s")"
        var text = " \(meter)  \(lag)  \(decodes)"
        if latest.fallbacks > 0 {
            text += "  \(latest.fallbacks) fallback\(latest.fallbacks == 1 ? "" : "s")"
        }
        if columns - text.count > 8 {
            text += String(repeating: " ", count: max(0, columns - text.count - 6))
            text += " ^C ends"
        }
        return dim(text)
    }

    /// Colours the words the scorer would grade: names, numbers, negations. Reuses
    /// ``CriticalInfoScorer/category(of:knownNames:)`` rather than a second set of rules, so what is
    /// highlighted here is exactly what counts as critical information in the report.
    private func tagged(_ text: String) -> String {
        let surface = TextNormalizer.surfaceTokens(text)
        let semantic = TextNormalizer.semanticTokens(text)
        // Number folding can turn two tokens ("twenty five") into one ("25"), so the two arrays are
        // not always index-aligned. Plain text is the honest fallback.
        guard surface.count == semantic.count else { return text }

        let byWord = Dictionary(uniqueKeysWithValues: zip(surface, semantic))
        return text.split(separator: " ").map { word -> String in
            let key = String(word).lowercased().trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted
            )
            guard let semantic = byWord[key],
                  let kind = CriticalInfoScorer.category(of: semantic, knownNames: knownNames) else {
                return String(word)
            }
            return colour(String(word), kind)
        }.joined(separator: " ")
    }

    private func colour(_ word: String, _ kind: CriticalInfoReport.Category) -> String {
        switch kind {
        case .name: return "\u{1B}[36m\(word)\u{1B}[0m"
        case .number: return "\u{1B}[33m\(word)\u{1B}[0m"
        case .negation: return "\u{1B}[1;31m\(word)\u{1B}[0m"
        }
    }

    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        var visible = 0

        for piece in text.split(separator: " ", omittingEmptySubsequences: true) {
            let word = String(piece)
            let length = visibleLength(word)
            if visible > 0, visible + 1 + length > width {
                lines.append("  " + current)
                current = ""
                visible = 0
            }
            if visible > 0 {
                current += " "
                visible += 1
            }
            current += word
            visible += length
        }
        if !current.isEmpty { lines.append("  " + current) }
        return lines
    }

    /// ANSI escapes occupy no columns, so wrapping has to count what a reader would see.
    private func visibleLength(_ text: String) -> Int {
        var count = 0
        var inEscape = false
        for character in text {
            if inEscape {
                if character == "m" { inEscape = false }
            } else if character == "\u{1B}" {
                inEscape = true
            } else {
                count += 1
            }
        }
        return count
    }

    // MARK: - Terminal

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (100, 30)
    }
}

private extension Int32 {
    var isTTY: Bool { isatty(self) == 1 }
}

// MARK: - Formatting

func formatClock(_ seconds: Double) -> String {
    let total = max(0, seconds)
    return String(format: "%02d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
}

func bold(_ text: String) -> String { "\u{1B}[1m\(text)\u{1B}[0m" }
func dim(_ text: String) -> String { "\u{1B}[2m\(text)\u{1B}[0m" }
