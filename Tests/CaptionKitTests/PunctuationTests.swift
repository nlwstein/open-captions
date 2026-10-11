import XCTest

@testable import CaptionKit

final class PunctuationTests: XCTestCase {

    // MARK: - Formatting rules, without the model

    private func label(_ cased: String, _ mark: Character? = nil, ends: Bool = false) -> WordLabel {
        WordLabel(mark: mark, endsSentence: ends, cased: cased)
    }

    func testModelAddsSentenceEndsAndCommas() {
        let turns = ["so how was the drive", "long there was construction"]
        let labels = [label("so"), label("how"), label("was"), label("the"), label("drive", "?"),
                      label("long", "."), label("there"), label("was"), label("construction", ".")]
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels),
                       "So how was the drive? Long. There was construction.")
    }

    func testEngineSentenceEndsStand() {
        // The model would run these together; the engine heard a full stop.
        let turns = ["Morning, Margaret. I'm Doctor Feldman."]
        let labels = [label("morning"), label("margaret"), label("I'm"), label("doctor"), label("feldman", ".")]
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels),
                       "Morning, Margaret. I'm Doctor Feldman.")
    }

    func testEngineSpellingsAndProperNounsKept() {
        let turns = ["I'm a LA Lakers fan", "Kobe was the best"]
        let labels = [label("I'm"), label("a"), label("La"), label("lakers"), label("fan", "."),
                      label("kobe"), label("was"), label("the"), label("best", ".")]
        // "LA" keeps the engine's capitals, "Lakers" its proper noun. "Kobe" starts a turn, where
        // the engine's capital is not evidence, but starts a sentence here anyway.
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels),
                       "I'm a LA Lakers fan. Kobe was the best.")
    }

    func testTurnStartCapitalIsNotTakenAsAProperNoun() {
        let turns = ["I'd like you to start", "Lisinopril ten milligrams"]
        let labels = [label("I'd"), label("like"), label("you"), label("to"), label("start"),
                      label("lisinopril", ","), label("ten"), label("milligrams", ".")]
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels),
                       "I'd like you to start lisinopril, ten milligrams.")
    }

    func testUnfinishedParagraphGetsNoFinalStop() {
        let turns = ["and then we went"]
        let labels = [label("and"), label("then"), label("we"), label("went", ",")]
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels, closed: false), "And then we went")
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels, closed: true), "And then we went.")
    }

    func testWordsTheModelWouldChangeAreLeftAlone() {
        // A label whose casing spells a different word must not get through.
        let turns = ["take the metformin"]
        let labels = [label("take"), label("the"), label("metoprolol", ".")]
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels), "take the metformin")
    }

    func testMismatchedLabelsLeaveTextAlone() {
        XCTAssertEqual(ParagraphFormatter.format(turns: ["one two"], labels: [label("one")]), "one two")
    }

    func testPunctuationOnlyTokensSurvive() {
        let turns = ["well -- maybe"]
        let labels = [label("well", ","), label(""), label("maybe")]
        XCTAssertEqual(ParagraphFormatter.format(turns: turns, labels: labels), "Well, -- maybe.")
    }

    // MARK: - Against SentencePiece and the original model

    private struct Reference: Decodable {
        struct Paragraph: Decodable {
            var turns: [String]
            var closed: Bool
            var expected: String
        }
        var tokens: [String: [Int32]]
        var paragraphs: [Paragraph]
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Written by the Python reference from SentencePiece and the converted model. Committed; the
    /// model it is compared with is not, and is built by `Scripts/make-punctuation-model.sh`.
    private func reference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Data/punctuation-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private var modelDirectory: URL { root.appendingPathComponent(".models/punctuation") }

    private func requireModel() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("vocabulary.tsv").path),
                          "Run Scripts/make-punctuation-model.sh to test against the model")
    }

    func testTokenizerMatchesSentencePiece() throws {
        try requireModel()
        let vocabulary = try String(contentsOf: modelDirectory.appendingPathComponent("vocabulary.tsv"), encoding: .utf8)
        let tokenizer = try PieceTokenizer(vocabulary: vocabulary)
        let reference = try reference()
        XCTAssertGreaterThan(reference.tokens.count, 200)
        for (word, ids) in reference.tokens {
            XCTAssertEqual(tokenizer.encode(word: word), ids, word)
        }
    }

    func testFormatsLikeTheReference() throws {
        try requireModel()
        let punctuator = try Punctuator.load(directory: modelDirectory)
        for paragraph in try reference().paragraphs {
            let words = ParagraphFormatter.words(in: paragraph.turns).words
            let labels = try punctuator.label(words)
            XCTAssertEqual(ParagraphFormatter.format(turns: paragraph.turns, labels: labels, closed: paragraph.closed),
                           paragraph.expected)
        }
    }

    func testLongParagraphsSpanWindows() throws {
        try requireModel()
        let punctuator = try Punctuator.load(directory: modelDirectory)
        // Far past one window of 256 tokens, so labels are stitched across several.
        let turn = Array(repeating: "and then we went down to the lake where the children used to swim", count: 60)
            .joined(separator: " ")
        let words = ParagraphFormatter.words(in: [turn]).words
        let labels = try punctuator.label(words)
        XCTAssertEqual(labels.count, words.count)
        let text = ParagraphFormatter.format(turns: [turn], labels: labels)
        XCTAssertTrue(ParagraphFormatter.sameWords(text, turn))
        XCTAssertGreaterThan(text.filter { $0 == "." }.count, 5)
    }
}
