import CaptionKit
@testable import CaptionSession
import XCTest

final class SavedSessionTests: XCTestCase {

    func testSpeakersAreNumberedByFirstAppearanceNotSlot() {
        let session = SavedSession(turns: [
            SavedTurn(speaker: 2, text: "hello", start: 0, end: 1),
            SavedTurn(speaker: 0, text: "hi", start: 1, end: 2),
            SavedTurn(speaker: 2, text: "how are you", start: 2, end: 3),
        ])
        XCTAssertEqual(session.label(for: 2), "Speaker 1")
        XCTAssertEqual(session.label(for: 0), "Speaker 2")
        XCTAssertEqual(session.label(for: nil), "Someone")
    }

    func testNamesReplaceNumbers() {
        var session = SavedSession(turns: [SavedTurn(speaker: 1, text: "x", start: 0, end: 1)])
        session.names[1] = "Dr Patel"
        XCTAssertEqual(session.label(for: 1), "Dr Patel")
    }

    func testSearchIgnoresCaseAndAccents() {
        let session = SavedSession(turns: [SavedTurn(speaker: 0, text: "The Café is open",
                                                     start: 0, end: 1)])
        XCTAssertTrue(session.matches("cafe"))
        XCTAssertTrue(session.matches(""))
        XCTAssertFalse(session.matches("closed"))
    }

    func testTitlesReadTheWayAPersonWouldSayThem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = ISO8601DateFormatter().date(from: "2026-10-11T18:00:00Z")!  // a Sunday
        func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

        XCTAssertEqual(SessionTitle.make(for: at("2026-10-11T09:00:00Z"), now: now,
                                         calendar: calendar, locale: locale), "Today, morning")
        XCTAssertEqual(SessionTitle.make(for: at("2026-10-10T14:00:00Z"), now: now,
                                         calendar: calendar, locale: locale), "Yesterday, afternoon")
        XCTAssertEqual(SessionTitle.make(for: at("2026-10-07T19:00:00Z"), now: now,
                                         calendar: calendar, locale: locale), "Wednesday evening")
        XCTAssertEqual(SessionTitle.make(for: at("2026-09-01T23:00:00Z"), now: now,
                                         calendar: calendar, locale: locale),
                       "Tuesday, September 1, night")
    }

    func testExportNamesEveryTurn() {
        var session = SavedSession(turns: [
            SavedTurn(speaker: 0, text: "Take one tablet twice a day.", start: 0, end: 2),
            SavedTurn(speaker: 1, text: "With food?", start: 2, end: 3),
        ])
        session.names[0] = "Doctor"
        let text = TranscriptExport.plainText(session, title: "Visit")
        XCTAssertTrue(text.hasPrefix("Visit\n"))
        XCTAssertTrue(text.contains("Doctor: Take one tablet twice a day."))
        XCTAssertTrue(text.contains("Speaker 2: With food?"))
    }
}

final class CaptionLinesTests: XCTestCase {

    func testNameShownOnlyWhenTheSpeakerChanges() {
        let lines = CaptionLines.make(turns: [
            SavedTurn(speaker: 3, text: "a", start: 0, end: 1),
            SavedTurn(speaker: 3, text: "b", start: 2, end: 3),
            SavedTurn(speaker: 1, text: "c", start: 3, end: 4, contested: true),
            SavedTurn(speaker: 3, text: "", start: 4, end: 5),
            SavedTurn(speaker: 3, text: "d", start: 5, end: 6),
            SavedTurn(speaker: 3, text: "e", start: 10, end: 11),
        ], names: [1: "Ann"], openLast: true)
        // One speaker's turns are one paragraph, until a long pause.
        XCTAssertEqual(lines.map(\.text), ["a b", "c", "d", "e"])
        XCTAssertEqual(lines.map(\.firstTurn), [0, 2, 4, 5])
        XCTAssertEqual(lines.map(\.startsNewSpeaker), [true, true, true, false])
        XCTAssertEqual(lines.map(\.speakerNumber), [1, 2, 1, 1])
        XCTAssertEqual(lines.map(\.label), ["Speaker 1", "Ann", "Speaker 1", "Speaker 1"])
        XCTAssertEqual(lines.map(\.isOpen), [false, false, false, true])
        XCTAssertTrue(lines[1].contested)
    }

    func testLongRunsAreSplitIntoParagraphsEvenWithoutPunctuation() {
        let sentence = Array(repeating: "word", count: 30).joined(separator: " ")
        let turns = (0..<20).map { SavedTurn(speaker: 0, text: sentence, start: Double($0), end: Double($0) + 0.9) }
        let lines = CaptionLines.make(turns: turns)
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.text.split(separator: " ").count < ParagraphBreaks.hardWords + 30 })
        XCTAssertEqual(lines.dropFirst().map(\.startsNewSpeaker), Array(repeating: false, count: lines.count - 1))
    }

    /// One speaker, ten words a turn, half a second apart unless said; "stop" ends a sentence.
    private func monologue(_ texts: [(String, pause: Double)]) -> [SavedTurn] {
        var turns: [SavedTurn] = []
        var time = 0.0
        for (text, pause) in texts {
            time += pause
            let words = text.split(separator: " ").count
            let filled = text + String(repeating: " w", count: max(0, 10 - words))
            turns.append(SavedTurn(speaker: 0, text: filled, start: time, end: time + 3))
            time += 3
        }
        return turns
    }

    /// A stand-in for the punctuation model: a full stop after "stop", and after the last word of
    /// a finished paragraph.
    private func punctuate(_ turns: [String], _ closed: Bool) -> String? {
        let text = turns.joined(separator: " ").replacingOccurrences(of: "stop", with: "stop.")
        return closed && !text.hasSuffix(".") ? text + "." : text
    }

    func testOneSpeakerIsBrokenAtSentenceEnds() {
        let turns = monologue([
            // 0–6: seventy words, a sentence ending at 40 (too short) and at 70 (long enough).
            ("w", 0.5), ("w", 0.5), ("w", 0.5), ("w w w w w w w w w stop", 0.5), ("w", 0.5),
            ("w", 0.5), ("w w w w w w w w w stop", 0.5),
            // 7–8: twenty words, then a pause.
            ("w", 0.5), ("w w w w w w w w w stop", 0.5),
            // 9–11: thirty words, then "So".
            ("w", 2), ("w", 0.5), ("w w w w w w w w w stop", 0.5), ("so w", 0.5),
            // A pause, but no sentence end before it: no break.
            ("w", 2), ("w", 0.5),
        ])
        let lines = CaptionLines.make(turns: turns, format: punctuate)
        XCTAssertEqual(lines.map(\.firstTurn), [0, 7, 9, 12])
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.text.hasSuffix("stop.") })
        XCTAssertEqual(lines.map(\.startsNewSpeaker), [true, false, false, false])

        // No break is guessed before the punctuation that would justify it is ready.
        XCTAssertEqual(CaptionLines.make(turns: turns, format: { _, _ in nil }).map(\.firstTurn), [0])
        // And none after it either, until it is: deciding it later must not move them.
        let first = turns[0...6].map(\.text)
        XCTAssertEqual(CaptionLines.make(turns: turns, format: {
            $0.starts(with: first) && $0.count == 8 ? nil : self.punctuate($0, $1)
        }).map(\.firstTurn), [0])
    }

    func testASentenceEndIsJudgedByTheWordsAfterIt() {
        // As the model does with nothing after them: a full stop at the end of every request.
        let eager: CaptionLines.Format = { turns, _ in turns.joined(separator: " ") + "." }
        var texts = Array(repeating: ("w", pause: 0.5), count: 7)
        texts.append(("and then w", pause: 0.5))
        let turns = monologue(texts)
        // Read with the next turn's first words, the full stop falls after them, not at the break.
        XCTAssertEqual(CaptionLines.make(turns: turns, format: eager).map(\.firstTurn), [0])

        // While the next turn has fewer whole words than that, no break is decided yet.
        var asked: [[String]] = []
        var open = turns
        open[7].text = "and then w"
        _ = CaptionLines.make(turns: open, openLast: true, format: { turns, closed in
            asked.append(turns)
            return eager(turns, closed)
        })
        // The open paragraph is shown read with "and then" — not the "w", which may still grow.
        XCTAssertTrue(asked.contains { $0.last == "and then" })
        XCTAssertFalse(asked.contains { $0.last == "and then w" })
        XCTAssertEqual(CaptionLines.make(turns: open, openLast: true, format: eager).map(\.firstTurn), [0])
    }

    func testABreakOnceShownNeverMoves() {
        var texts: [(String, pause: Double)] = []
        for index in 0..<60 {
            let text = index % 3 == 2 ? "w w w w w w w w w stop" : index % 7 == 0 ? "so w" : "w"
            texts.append((text, index % 5 == 0 ? 2 : 0.5))
        }
        let turns = monologue(texts)
        var shown: Set<Int> = []
        for count in 1...turns.count {
            let lines = CaptionLines.make(turns: Array(turns.prefix(count)), openLast: true,
                                          format: punctuate)
            let ids = Set(lines.map(\.id))
            XCTAssertTrue(shown.isSubset(of: ids), "a break moved after \(count) turns")
            shown = ids
        }
        XCTAssertGreaterThan(shown.count, 5)
    }

    func testMarkersAreWholeWords() {
        XCTAssertTrue(ParagraphBreaks.startsWithMarker("So, what did he say"))
        XCTAssertTrue(ParagraphBreaks.startsWithMarker("by the way it rained"))
        XCTAssertFalse(ParagraphBreaks.startsWithMarker("some people"))
        XCTAssertFalse(ParagraphBreaks.startsWithMarker("okay so"))
        XCTAssertTrue(ParagraphBreaks.endsSentence("he said \"no.\""))
        XCTAssertFalse(ParagraphBreaks.endsSentence("e.g like"))
    }

    func testFinishedTurnsArePunctuatedAndTheNewestShownAsIs() {
        var asked: [([String], Bool)] = []
        let format: CaptionLines.Format = { turns, closed in
            asked.append((turns, closed))
            return turns.joined(separator: " ").capitalized + "."
        }
        let turns = [
            SavedTurn(speaker: 0, text: "hello there", start: 0, end: 1),
            SavedTurn(speaker: 1, text: "how are you", start: 1, end: 2),
            SavedTurn(speaker: 1, text: "i was saying", start: 2.5, end: 3),
            SavedTurn(speaker: 1, text: "that we should", start: 3.5, end: 4),
        ]
        let lines = CaptionLines.make(turns: turns, openLast: true, format: format)
        // The finished turns are read with the newest turn's whole words after them, so the full
        // stop the stand-in puts at the end falls there, and is not shown.
        XCTAssertEqual(lines.map(\.text), ["Hello There.", "How Are You I Was Saying that we should"])
        XCTAssertEqual(asked.map(\.0), [["hello there"], ["how are you", "i was saying", "that we"]])
        XCTAssertEqual(asked.map(\.1), [true, false])

        // With a sentence end before the newest turn, its first word starts the next sentence.
        let ended = CaptionLines.make(turns: turns, openLast: true, format: { turns, _ in
            turns.joined(separator: " ").replacingOccurrences(of: "saying", with: "saying.")
        })
        XCTAssertEqual(ended.last?.text, "how are you i was saying. That we should")

        // Not ready yet: the engine's text.
        XCTAssertEqual(CaptionLines.make(turns: turns, openLast: true, format: { _, _ in nil }).map(\.text),
                       ["hello there", "how are you i was saying that we should"])
    }
}

final class TranscriptStoreTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripNewestFirst() throws {
        let store = TranscriptStore(directory: directory)
        let old = SavedSession(startedAt: Date(timeIntervalSince1970: 1_000),
                               turns: [SavedTurn(speaker: 0, text: "old", start: 0, end: 1)],
                               names: [0: "Mum"])
        let new = SavedSession(startedAt: Date(timeIntervalSince1970: 2_000))
        try store.save(old)
        try store.save(new)
        let all = store.all()
        XCTAssertEqual(all.map(\.id), [new.id, old.id])
        XCTAssertEqual(store.load(old.id), old)
        XCTAssertEqual(store.load(old.id)?.names[0], "Mum")
    }

    func testDamagedFileDoesNotHideTheRest() throws {
        let store = TranscriptStore(directory: directory)
        try store.save(SavedSession())
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        XCTAssertEqual(store.all().count, 1)
    }

    func testPruneKeepsRecent() throws {
        let store = TranscriptStore(directory: directory)
        let now = Date()
        try store.save(SavedSession(startedAt: now.addingTimeInterval(-40 * 86_400)))
        try store.save(SavedSession(startedAt: now.addingTimeInterval(-1 * 86_400)))
        XCTAssertEqual(store.prune(olderThanDays: 30, now: now), 1)
        XCTAssertEqual(store.all().count, 1)
    }
}

final class ReplayTests: XCTestCase {
    let script = ReplayScript(turns: [
        SavedTurn(speaker: 0, text: "one two three four", start: 0, end: 4),
        SavedTurn(speaker: 1, text: "five six", start: 5, end: 7, contested: true),
    ])

    func testTurnsRevealWordsAtSpeakingPace() {
        XCTAssertEqual(script.turns(at: -1), [])
        let early = script.turns(at: 1.5)
        XCTAssertEqual(early.map(\.text), ["one two"])
        XCTAssertTrue(early[0].isOpen)

        let later = script.turns(at: 6)
        XCTAssertEqual(later.map(\.text), ["one two three four", "five six"])
        XCTAssertEqual(later.map(\.isOpen), [false, true])
        XCTAssertTrue(later[1].isContested)
    }

    func testLoadsAHarnessDump() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dump-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        {"settings": "x", "turns": [
          {"speaker": 1, "start": 2.0, "end": 3.0, "overlapSeconds": 0.0, "open": false, "text": "b"},
          {"speaker": null, "start": 0.0, "end": 1.0, "overlapSeconds": 0.5, "open": false, "text": "a"}
        ]}
        """.utf8).write(to: url)
        let loaded = try ReplayScript.load(url)
        XCTAssertEqual(loaded.turns.map(\.text), ["a", "b"])
        XCTAssertEqual(loaded.turns[0].contested, true)
        XCTAssertNil(loaded.turns[0].speaker)
    }
}

final class SettingsTests: XCTestCase {

    func testOldSettingsFilesStillLoad() throws {
        let settings = try JSONDecoder().decode(AppSettings.self,
                                                from: Data(#"{"textSize": 60, "theme": "dark"}"#.utf8))
        XCTAssertEqual(settings.textSize, 60)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.simpleMode)
        XCTAssertEqual(settings.engine, .nemotron)
    }

    func testMicrophoneSettingsRoundTripAndDefault() throws {
        let old = try JSONDecoder().decode(AppSettings.self,
                                           from: Data(#"{"microphone": "voiceIsolation"}"#.utf8))
        XCTAssertEqual(old.microphoneSetup, MicrophoneSetup(processing: .voiceIsolation))
        XCTAssertEqual(old.gain, GainTuning())
        XCTAssertFalse(old.showMicrophoneMeter)

        var settings = AppSettings()
        settings.microphoneSetup = MicrophoneSetup(processing: .videoRecording, microphone: .back,
                                                   pattern: .cardioid, hardwareGain: 0.8)
        settings.gain = GainTuning(automatic: true, maxGainDb: 44, targetSpeechDb: -20)
        let decoded = try JSONDecoder().decode(AppSettings.self,
                                               from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.microphoneSetup, settings.microphoneSetup)
        XCTAssertEqual(decoded.gain, settings.gain)
        XCTAssertEqual(settings.microphoneSetup.slug, "videoRecording-back-cardioid-gain80")
        XCTAssertNotEqual(GainTuning().key, settings.gain.key)
    }

    func testLaunchArguments() {
        let options = LaunchOptions(arguments: [
            "/app", "-replay", "/tmp/a.json", "-speed", "4", "-autostart", "-screen", "history",
            "-simple", "0", "-text-size", "48", "-theme", "highContrastDark", "-engine", "unified",
            "-NSSomething", "YES",
        ])
        XCTAssertEqual(options.replay?.path, "/tmp/a.json")
        XCTAssertEqual(options.speed, 4)
        XCTAssertTrue(options.autostart)
        XCTAssertEqual(options.screen, .history)
        var settings = AppSettings()
        options.apply(to: &settings)
        XCTAssertFalse(settings.simpleMode)
        XCTAssertEqual(settings.textSize, 48)
        XCTAssertEqual(settings.theme, .highContrastDark)
        XCTAssertEqual(settings.engine, .unified)
    }
}

@MainActor
final class LiveConversationTests: XCTestCase {

    func testAReplayedSessionIsSavedAndLogged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(directory: root.appendingPathComponent("t"))
        let script = ReplayScript(turns: [
            SavedTurn(speaker: 0, text: "good morning", start: 0, end: 1),
            SavedTurn(speaker: 1, text: "morning to you", start: 1.2, end: 2),
        ])
        let live = LiveConversation(store: store, diagnosticsDirectory: root.appendingPathComponent("d")) {
            LiveConversation.Configuration(
                engineKey: "replay", engineName: "replay",
                makeEngine: { ReplayEngine(script: script) },
                makeSource: { ClockAudioSource(speed: 50, limitSeconds: 3) })
        }
        await live.start()

        XCTAssertEqual(live.phase, .idle)
        let saved = try XCTUnwrap(store.all().first)
        XCTAssertEqual(saved.turns.map(\.text), ["good morning", "morning to you"])
        XCTAssertNotNil(saved.endedAt)

        let log = try String(contentsOf: root.appendingPathComponent("d/\(saved.id.uuidString).jsonl"),
                             encoding: .utf8)
        XCTAssertTrue(log.contains(#""event":"start""#))
        XCTAssertTrue(log.contains(#""event":"end""#))
        XCTAssertFalse(log.contains("good morning"), "diagnostics must not contain the words")
    }

    func testStopEndsTheSessionAndKeepsWhatWasHeard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(directory: root)
        let script = ReplayScript(turns: [SavedTurn(speaker: 0, text: "a b c d e f", start: 0, end: 60)])
        let live = LiveConversation(store: store, diagnosticsDirectory: root.appendingPathComponent("d")) {
            LiveConversation.Configuration(
                engineKey: "replay", engineName: "replay",
                makeEngine: { ReplayEngine(script: script) },
                makeSource: { ClockAudioSource(speed: 20) })
        }
        let running = Task { await live.start() }
        while live.turns.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        await live.stop()
        await running.value
        XCTAssertEqual(live.phase, .idle)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertFalse(live.turns.contains(where: \.isOpen))
    }
}

@MainActor
final class FirstRunTests: XCTestCase {

    private func conversation(_ download: ReplayEngine.SimulatedDownload) -> (LiveConversation, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID())")
        let live = LiveConversation(store: TranscriptStore(directory: root.appendingPathComponent("t")),
                                    diagnosticsDirectory: root.appendingPathComponent("d")) {
            LiveConversation.Configuration(
                engineKey: "replay", engineName: "replay",
                makeEngine: { ReplayEngine(script: ReplayScript(turns: []), download: download) },
                makeSource: { ClockAudioSource(speed: 50, limitSeconds: 1) })
        }
        return (live, root)
    }

    func testADroppedDownloadSaysSoInPlainWords() async {
        let (live, root) = conversation(.init(seconds: 0.5, fails: true))
        defer { try? FileManager.default.removeItem(at: root) }
        await live.warmUp()
        XCTAssertFalse(live.isWarm)
        XCTAssertNil(live.progress)
        XCTAssertEqual(live.phase,
                       .failed("The download stopped. Check the internet connection, then try again."))
    }

    func testACompletedDownloadEndsReady() async {
        let (live, root) = conversation(.init(seconds: 0.3))
        defer { try? FileManager.default.removeItem(at: root) }
        await live.warmUp()
        XCTAssertTrue(live.isWarm)
        XCTAssertEqual(live.progress, .ready)
        XCTAssertEqual(live.phase, .idle)
    }

    func testWrappedNetworkErrorsAreRecognised() {
        let wrapped = NSError(domain: "FluidAudio", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])
        XCTAssertTrue(LiveConversation.describeLoadFailure(wrapped).hasPrefix("The download stopped"))
        XCTAssertTrue(LiveConversation.describeLoadFailure(CocoaError(.fileReadCorruptFile))
            .hasPrefix("Could not load"))
    }

    func testSetupShowsUntilDoneExceptForScriptedRuns() {
        XCTAssertTrue(LaunchOptions(arguments: []).showsSetup(setupDone: false))
        XCTAssertFalse(LaunchOptions(arguments: []).showsSetup(setupDone: true))
        XCTAssertFalse(LaunchOptions(arguments: ["-autostart"]).showsSetup(setupDone: false))
        XCTAssertTrue(LaunchOptions(arguments: ["-autostart", "-setup", "1"]).showsSetup(setupDone: true))
        let fake = LaunchOptions(arguments: ["-fake-download", "8", "-fake-download-fail"])
        XCTAssertEqual(fake.fakeDownload, 8)
        XCTAssertTrue(fake.fakeDownloadFails)
    }

    func testSettingsFromBeforeSetupExistedStartWithSetup() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"textSize": 40}"#.utf8))
        XCTAssertFalse(old.setupDone)
    }

    func testProgressIsClampedAndReadsAsPercent() {
        let progress = ModelProgress(step: .downloading, fraction: 0.456, model: "x")
        XCTAssertEqual(progress.percent, 45)
        XCTAssertEqual(ModelProgress(step: .loading, fraction: 1.7, model: "x").fraction, 1)
    }
}

final class ChangelogTests: XCTestCase {

    private func log(_ records: [(String, String, String)]) -> String {
        records.map { "\($0.0)\u{1F}\($0.1)\u{1F}\($0.2)\u{1E}\n" }.joined()
    }

    func testReadsConventionalSubjects() {
        let changelog = Changelog(gitLog: log([
            ("aaaaaaa1", "2026-10-11T10:00:00-04:00", "feat(app)!: first-run setup with model download"),
            ("bbbbbbb2", "2026-10-11T09:00:00-04:00", "fix: keep word boundaries"),
            ("ccccccc3", "2026-10-10T09:00:00-04:00", "docs: measure on an M4"),
            ("ddddddd4", "2026-10-10T08:00:00-04:00", "Tidy things up"),
            ("eeeeeee5", "2026-10-09T08:00:00-04:00", "feat: iOS app shell"),
        ]))
        XCTAssertEqual(changelog.entries.count, 5)
        XCTAssertEqual(changelog.entries[4].summary, "iOS app shell")
        let first = changelog.entries[0]
        XCTAssertEqual(first.kind, .feat)
        XCTAssertEqual(first.scope, "app")
        XCTAssertTrue(first.breaking)
        XCTAssertEqual(first.summary, "First-run setup with model download")
        XCTAssertEqual(changelog.buildCommit, "aaaaaaa")
        XCTAssertEqual(changelog.entries[3].kind, .other)
        XCTAssertEqual(changelog.entries[3].summary, "Tidy things up")
    }

    func testUserFacingViewHidesHousekeepingAndGroupsByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let changelog = Changelog(gitLog: log([
            ("a", "2026-10-11T10:00:00-04:00", "fix: one"),
            ("b", "2026-10-11T09:00:00-04:00", "feat: two"),
            ("c", "2026-10-10T09:00:00-04:00", "chore: three"),
        ]))
        let shown = changelog.days(includingAll: false, calendar: calendar)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].groups.map(\.kind), [.feat, .fix], "new things come before fixes")
        XCTAssertEqual(changelog.days(includingAll: true, calendar: calendar).count, 2)
    }

    func testDamagedRecordsAreSkipped() {
        let changelog = Changelog(gitLog: "garbage\u{1E}x\u{1F}not-a-date\u{1F}feat: y\u{1E}")
        XCTAssertTrue(changelog.entries.isEmpty)
        XCTAssertNil(changelog.buildCommit)
    }

    /// The real history, as the build script writes it: every commit should parse as one of the
    /// conventional types, which is what keeps the in-app changelog readable.
    func testThisRepositorysHistoryIsConventional() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("changelog-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let script = Process()
        script.executableURL = root.appendingPathComponent("Scripts/make-changelog.sh")
        script.arguments = [out.path]
        try script.run()
        script.waitUntilExit()
        let changelog = try XCTUnwrap(Changelog.load(out))
        try XCTSkipIf(changelog.entries.isEmpty, "no git history here")
        let unconventional = changelog.entries.filter { $0.kind == .other }.map(\.summary)
        XCTAssertEqual(unconventional, [])
    }
}
