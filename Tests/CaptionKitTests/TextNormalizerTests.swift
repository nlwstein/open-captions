import XCTest

@testable import CaptionKit

final class TextNormalizerTests: XCTestCase {

    // MARK: - Tokenization

    func testStripsPunctuationAndLowercases() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("Hello, world!"), ["hello", "world"])
    }

    func testKeepsContractionsIntact() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("Don't do that."), ["don't", "do", "that"])
    }

    func testKeepsCurlyApostrophesAsContractions() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("I don\u{2019}t know"), ["i", "don't", "know"])
    }

    func testDropsQuotationApostrophes() {
        // A leading apostrophe is punctuation, not part of a word.
        XCTAssertEqual(TextNormalizer.surfaceTokens("'hello' there"), ["hello", "there"])
    }

    func testFoldsThousandsSeparators() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("$2,000.50 total"), ["2000.50", "total"])
    }

    func testKeepsTimesIntact() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("at 2:30 pm"), ["at", "2:30", "pm"])
    }

    func testHyphenSeparatesWords() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("twenty-two"), ["twenty", "two"])
    }

    func testEmptyInputYieldsNoTokens() {
        XCTAssertEqual(TextNormalizer.surfaceTokens("   "), [])
    }

    // MARK: - Number folding

    func testFoldsSimpleNumberWords() {
        XCTAssertEqual(TextNormalizer.semanticTokens("fifteen"), ["15"])
        XCTAssertEqual(TextNormalizer.semanticTokens("seven"), ["7"])
    }

    func testFoldsCompoundNumbers() {
        XCTAssertEqual(TextNormalizer.semanticTokens("twenty two"), ["22"])
        XCTAssertEqual(TextNormalizer.semanticTokens("one hundred"), ["100"])
        XCTAssertEqual(TextNormalizer.semanticTokens("two thousand five hundred"), ["2500"])
    }

    func testFoldsOrdinals() {
        XCTAssertEqual(TextNormalizer.semanticTokens("the second pill"), ["the", "2", "pill"])
    }

    /// The year reading depends on the word after the century being a tens word. Without that
    /// distinction "twenty two" would decode as the year 2002.
    func testDistinguishesYearsFromCompoundNumbers() {
        XCTAssertEqual(TextNormalizer.semanticTokens("nineteen eighty four"), ["1984"])
        XCTAssertEqual(TextNormalizer.semanticTokens("nineteen fifty two"), ["1952"])
        XCTAssertEqual(TextNormalizer.semanticTokens("twenty twenty"), ["2020"])
        XCTAssertEqual(TextNormalizer.semanticTokens("twenty twenty four"), ["2024"])
        XCTAssertEqual(TextNormalizer.semanticTokens("nineteen oh five"), ["1905"])

        XCTAssertEqual(TextNormalizer.semanticTokens("twenty two"), ["22"])
        XCTAssertEqual(TextNormalizer.semanticTokens("twenty five hundred"), ["2500"])
        XCTAssertEqual(TextNormalizer.semanticTokens("nineteen hundred"), ["1900"])
    }

    func testLeavesDigitsAlone() {
        XCTAssertEqual(TextNormalizer.semanticTokens("take 2 pills"), ["take", "2", "pills"])
    }

    func testDigitsAndWordsAgree() {
        XCTAssertEqual(
            TextNormalizer.semanticTokens("fifteen milligrams"),
            TextNormalizer.semanticTokens("15 milligrams")
        )
    }

    /// Ordinary words that merely look numeric-adjacent must survive untouched.
    func testLeavesNonNumbersAlone() {
        XCTAssertEqual(TextNormalizer.semanticTokens("oh I see"), ["oh", "i", "see"])
        XCTAssertEqual(TextNormalizer.semanticTokens("one of them"), ["1", "of", "them"])
    }

    // MARK: - Negation

    func testDetectsNegationWords() {
        for token in ["not", "no", "never", "without", "cannot", "nothing"] {
            XCTAssertTrue(TextNormalizer.isNegation(token), "\(token) should negate")
        }
    }

    func testDetectsContractedNegationsBySuffix() {
        for token in ["don't", "doesn't", "didn't", "can't", "won't", "isn't", "weren't", "shouldn't"] {
            XCTAssertTrue(TextNormalizer.isNegation(token), "\(token) should negate")
        }
    }

    func testDoesNotTreatOrdinaryWordsAsNegation() {
        for token in ["know", "note", "now", "knot", "cannotstop"] {
            XCTAssertFalse(TextNormalizer.isNegation(token), "\(token) should not negate")
        }
    }

    // MARK: - Proper nouns

    func testFindsNamesAfterTitles() {
        // The abbreviation period must not make the name look sentence-initial and hide it.
        let names = TextNormalizer.detectProperNouns(in: "Dr. Feldman said to rest.")
        XCTAssertTrue(names.contains("feldman"), "got \(names)")
    }

    func testFindsNamesMidSentence() {
        let names = TextNormalizer.detectProperNouns(in: "I saw Margaret at the store.")
        XCTAssertTrue(names.contains("margaret"), "got \(names)")
    }

    func testRejectsWordsThatAlsoAppearLowercase() {
        // "Today" is capitalized only because it starts a sentence.
        let names = TextNormalizer.detectProperNouns(in: "Today is nice. I like today a lot.")
        XCTAssertFalse(names.contains("today"), "got \(names)")
    }

    func testRejectsCommonSentenceOpeners() {
        let names = TextNormalizer.detectProperNouns(in: "Okay, well, then we went home.")
        XCTAssertTrue(names.isEmpty, "got \(names)")
    }

    func testRejectsTokensContainingDigits() {
        let names = TextNormalizer.detectProperNouns(in: "Call 555-1234 tomorrow.")
        XCTAssertTrue(names.filter { $0.contains(where: \.isNumber) }.isEmpty, "got \(names)")
    }

    func testDeduplicatesRepeatedNames() {
        let names = TextNormalizer.detectProperNouns(in: "Margaret called. Then Margaret left.")
        XCTAssertEqual(names.filter { $0 == "margaret" }.count, 1, "got \(names)")
    }

    /// "I'll" mid-sentence is capitalized, is not a common word, and never appears lowercase — so
    /// it passed every other test and was scored as a person's name. Caught on the family-dinner
    /// fixture, where "Sit down, I'll get you a drink" produced a bogus name failure.
    func testContractionIsNotTreatedAsAName() {
        let names = TextNormalizer.detectProperNouns(in: "Sit down, I'll get you a drink.")
        XCTAssertFalse(names.contains("i'll"), "got \(names)")
    }

    /// The stem rule must not swallow genuine names that contain an apostrophe.
    func testApostropheNameIsStillDetected() {
        let names = TextNormalizer.detectProperNouns(in: "I spoke to O'Brien about it.")
        XCTAssertTrue(names.contains("o'brien"), "got \(names)")
    }

    func testTitleIsNotTreatedAsAName() {
        let names = TextNormalizer.detectProperNouns(in: "I'm Doctor Feldman.")
        XCTAssertFalse(names.contains("doctor"), "got \(names)")
        XCTAssertTrue(names.contains("feldman"), "got \(names)")
    }

    // MARK: - Title folding

    func testSpokenAndAbbreviatedTitlesAgree() {
        XCTAssertEqual(
            TextNormalizer.semanticTokens("I'm Doctor Feldman."),
            TextNormalizer.semanticTokens("I'm Dr. Feldman.")
        )
    }

    func testTitleFoldingDoesNotAlterSurfaceTokens() {
        // Conventional WER must stay conventional: the two forms really are different words.
        XCTAssertNotEqual(
            TextNormalizer.surfaceTokens("Doctor Feldman"),
            TextNormalizer.surfaceTokens("Dr. Feldman")
        )
    }
}
