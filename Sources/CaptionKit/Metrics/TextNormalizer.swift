import Foundation

/// Text normalization for transcript comparison.
///
/// Two levels are provided, because they answer different questions:
///
/// - ``surfaceTokens(_:)`` lowercases and strips punctuation. This is the conventional basis for
///   Word Error Rate, so numbers stay in whatever form they were spoken ("fifteen" stays
///   "fifteen"). Figures computed on this basis are comparable to published WER numbers.
/// - ``semanticTokens(_:)`` additionally folds spelled-out numbers into digits, so "fifteen" and
///   "15" compare equal. For a captioning aid, meaning is what matters — but a *wrong* number must
///   still register as an error, which this preserves: 15 and 50 remain different tokens.
public enum TextNormalizer {

    // MARK: - Tokenization

    /// Lowercases, strips punctuation, and collapses whitespace. Apostrophes are retained so
    /// contractions such as "don't" survive intact; hyphen and comma separate tokens.
    public static func surfaceTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let chars = Array(text.lowercased())

        /// True when the character at `offset` exists and is a digit. Used to decide whether an
        /// interior "." or ":" is part of a number ("3.5", "2:30") or just punctuation.
        func isDigit(at offset: Int) -> Bool {
            guard offset >= 0, offset < chars.count else { return false }
            return chars[offset].isNumber
        }

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for (index, char) in chars.enumerated() {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else if char == "'" || char == "\u{2019}" || char == "\u{2018}" {
                // Keep an apostrophe only when it sits inside a word, so quoted speech such as
                // 'hello' does not produce stray leading/trailing apostrophes.
                if !current.isEmpty, isDigit(at: index + 1) || chars[safe: index + 1]?.isLetter == true {
                    current.append("'")
                }
            } else if char == "." || char == ":" {
                // Interior separators in times and decimals: 2:30, 3.5
                if isDigit(at: index - 1), isDigit(at: index + 1) {
                    current.append(char)
                } else {
                    flush()
                }
            } else if char == "," {
                // Thousands separators vanish ("2,000" -> "2000"); otherwise the comma separates.
                if isDigit(at: index - 1), isDigit(at: index + 1) {
                    continue
                }
                flush()
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// ``surfaceTokens(_:)`` with spelling differences that carry no meaning folded away: numbers
    /// written as digits or words, and titles written long or abbreviated. This is the basis for
    /// every measurement except plain Word Error Rate.
    public static func semanticTokens(_ text: String) -> [String] {
        foldTitles(foldNumbers(surfaceTokens(text)))
    }

    // MARK: - Title folding

    /// Recognizers alternate freely between the long and abbreviated form of a title, and the
    /// difference is formatting rather than meaning: "Doctor Feldman" and "Dr. Feldman" are the
    /// same utterance. Folding both to the abbreviation keeps that out of the error counts.
    ///
    /// "misses" is included because it is how the honorific is normally spoken aloud — a
    /// recognizer given "Mrs. Patel" will often write "Misses Patel". The verb "she misses him"
    /// folds to the same token, so a reference/recognizer disagreement between those two forms
    /// would compare equal; that is a narrow enough collision to accept for the gain.
    private static let titleFolds: [String: String] = [
        "doctor": "dr", "mister": "mr", "misses": "mrs", "missus": "mrs",
    ]

    private static func foldTitles(_ tokens: [String]) -> [String] {
        tokens.map { titleFolds[$0] ?? $0 }
    }

    // MARK: - Number folding

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Ordinals map to their cardinal value: "the second pill" and "the 2nd pill" agree.
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]

    private static func isNumberWord(_ token: String) -> Bool {
        units[token] != nil || tens[token] != nil || scales[token] != nil || ordinals[token] != nil
    }

    /// Folds a digit ordinal to its cardinal: "2nd" and "second" both become "2". Recognizers emit
    /// either form for the same words, and a difference here is formatting rather than meaning.
    private static func stripOrdinalSuffix(_ token: String) -> String {
        for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
            let digits = token.dropLast(suffix.count)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                return String(digits)
            }
        }
        return token
    }

    /// Replaces each maximal run of number words with the single digit token it denotes.
    /// Runs that do not form a coherent number are left untouched.
    private static func foldNumbers(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            guard isNumberWord(tokens[index]) else {
                result.append(stripOrdinalSuffix(tokens[index]))
                index += 1
                continue
            }
            // Extend across an "oh" sitting between number words, which is how years in the
            // 1900s and 2000s are spoken: "nineteen oh five". An "oh" elsewhere is an interjection.
            var end = index
            while end < tokens.count {
                if isNumberWord(tokens[end]) {
                    end += 1
                    continue
                }
                let isConnective = tokens[end] == "oh" || tokens[end] == "o"
                if isConnective, end + 1 < tokens.count, isNumberWord(tokens[end + 1]) {
                    end += 1
                    continue
                }
                break
            }
            let run = Array(tokens[index..<end])
            if let value = compose(run) {
                result.append(String(value))
            } else {
                result.append(contentsOf: run)
            }
            index = end
        }
        return result
    }

    /// Computes the value of a run of number words, or nil if the run is not a coherent number.
    ///
    /// Known limitation: bare digit sequences ("one two three" for a phone number) do not compose
    /// and are left as separate words.
    static func compose(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }

        // Years are spoken as a pair — "nineteen eighty four" is 1984, not 19 + 80 + 4.
        // The year reading applies only when the century word is followed by a tens word
        // ("eighty four", "twenty four") or an "oh" ("oh five"). That condition is what separates
        // the year "twenty twenty" = 2020 from the ordinary number "twenty two" = 22, whose second
        // word is a unit rather than a tens.
        // The century word can come from either table: "nineteen" is a unit, "twenty" is a tens.
        if words.count >= 2, let century = units[words[0]] ?? tens[words[0]], century == 19 || century == 20 {
            let rest = Array(words.dropFirst())
            let startsWithOh = rest[0] == "oh" || rest[0] == "o"
            if tens[rest[0]] != nil || startsWithOh {
                let tail = startsWithOh ? Array(rest.dropFirst()) : rest
                if tail.isEmpty { return century * 100 }
                if let remainder = compose(tail), remainder < 100 {
                    return century * 100 + remainder
                }
            }
        }

        var total = 0
        var current = 0
        var sawValue = false
        for word in words {
            if let ordinal = ordinals[word] {
                current += ordinal
                sawValue = true
            } else if let unit = units[word] {
                current += unit
                sawValue = true
            } else if let ten = tens[word] {
                current += ten
                sawValue = true
            } else if let scale = scales[word] {
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                sawValue = true
            } else {
                return nil
            }
        }
        return sawValue ? total + current : nil
    }

    // MARK: - Negation

    private static let negationWords: Set<String> = [
        "no", "not", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor",
        "without", "cannot", "lack", "lacks", "lacking", "deny", "denies", "denied",
        "avoid", "avoids", "avoided", "stop", "stops", "stopped", "quit", "quits",
        "hardly", "barely", "scarcely", "rarely", "seldom", "refuse", "refuses", "refused",
    ]

    /// True when a token negates. Contractions are matched by suffix, which catches the whole
    /// "n't" family (don't, doesn't, didn't, can't, won't, isn't, aren't, wasn't, weren't,
    /// couldn't, shouldn't, wouldn't, hasn't, haven't, hadn't) without enumerating each one.
    public static func isNegation(_ token: String) -> Bool {
        if token.hasSuffix("n't") { return true }
        return negationWords.contains(token)
    }

    // MARK: - Proper nouns

    private static let sentenceStartableCommonWords: Set<String> = [
        "i", "the", "a", "an", "and", "but", "or", "so", "then", "when", "where", "what",
        "why", "how", "who", "that", "this", "these", "those", "there", "here", "it", "he",
        "she", "they", "we", "you", "my", "your", "his", "her", "their", "our", "its",
        "if", "because", "well", "oh", "okay", "ok", "yes", "yeah", "no", "not", "just",
        "now", "today", "tomorrow", "yesterday", "maybe", "sure", "right", "please",
        "thank", "thanks", "hello", "hi", "hey", "good", "great", "sorry", "excuse",
    ]

    /// Titles that make the word after them a name rather than a new sentence, and that are not
    /// themselves names. Both the abbreviated and the spoken form are listed: a reference that
    /// says "Doctor Feldman" and a recognizer that writes "Dr. Feldman" mean the same thing, and
    /// neither word should be scored as a person.
    private static let honorifics: Set<String> = [
        // Abbreviated
        "dr", "mr", "mrs", "ms", "miss", "prof", "rev", "fr", "capt", "sgt", "lt", "col",
        "gen", "st", "ave", "jr", "sr",
        // Spoken in full
        "doctor", "mister", "misses", "missus", "professor", "sir", "madam", "madame",
        "dame", "lord", "lady", "reverend", "captain", "sergeant", "lieutenant", "colonel",
        "general",
    ]

    /// Heuristically extracts proper nouns from the original (case-preserving) text.
    ///
    /// A capitalized word counts as a name when three things hold: it is not a common word, its
    /// lowercase form never appears elsewhere in the text, and it either sits mid-sentence or
    /// follows a title. Each condition rules out a specific false positive — "Okay" opens a
    /// sentence, "Today ... today" proves the word is ordinary, and a lone "Take" at the start of
    /// an utterance is capitalization rather than a name.
    ///
    /// This is deliberately conservative and will miss names the recognizer lowercased entirely,
    /// as well as a name that only ever appears sentence-initially. Callers who know which names
    /// matter — family, doctors — should pass them explicitly via ``CriticalInfoScorer/knownNames``,
    /// which is the reliable path and the one the app should use.
    public static func detectProperNouns(in text: String) -> [String] {
        let trimSet = CharacterSet.punctuationCharacters.union(.symbols)
        let rawWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let stripped = rawWords.map { $0.trimmingCharacters(in: trimSet) }

        var appearsLowercase: Set<String> = []
        for word in rawWords where word.first?.isLowercase == true {
            appearsLowercase.insert(word.trimmingCharacters(in: trimSet).lowercased())
        }

        var found: [String] = []
        var seen: Set<String> = []
        for index in rawWords.indices {
            let word = stripped[index]
            guard word.first?.isUppercase == true else { continue }
            let lowered = word.lowercased()
            guard lowered.count >= 3 else { continue }
            guard lowered.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            guard !sentenceStartableCommonWords.contains(lowered) else { continue }
            guard !appearsLowercase.contains(lowered) else { continue }
            // A title is not itself a name.
            guard !honorifics.contains(lowered) else { continue }
            guard !isNegation(lowered) else { continue }
            // Contractions of common words are not names, however they are capitalized. "I'll"
            // satisfies every other test here when it sits mid-sentence ("Sit down, I'll get you
            // a drink"), and "I" is already excluded above — so the stem before the apostrophe is
            // the check that catches it. Genuine names with apostrophes (O'Brien) keep a stem that
            // is not a common word, and pass through.
            if let apostrophe = lowered.firstIndex(of: "'") {
                let stem = String(lowered[lowered.startIndex..<apostrophe])
                if sentenceStartableCommonWords.contains(stem) { continue }
            }

            let previous = index > 0 ? rawWords[index - 1] : nil
            let startsSentence = previous == nil
                || previous!.hasSuffix(".") || previous!.hasSuffix("!") || previous!.hasSuffix("?")
            let followsHonorific = index > 0 && honorifics.contains(stripped[index - 1].lowercased())
            guard !startsSentence || followsHonorific else { continue }

            if seen.insert(lowered).inserted { found.append(lowered) }
        }
        return found
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
