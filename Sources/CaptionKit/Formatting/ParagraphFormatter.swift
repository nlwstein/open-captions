import Foundation

/// One speaker's words, punctuated: the engine's text with the punctuation model's sentence ends,
/// commas and capitals added.
///
/// The engine's own full stops and question marks always stand. On clear speech they are better
/// than the model's — the model, reading words without the voice, ran "Morning, Margaret. I'm
/// Doctor Feldman" together — and they come from hearing the pitch of a question, which text
/// cannot recover. On far-field speech the engine writes almost none (no full stop in 3,139 words
/// of DiPCo), and the model supplies them.
///
/// Words are never changed. Each output word is the engine's word with, at most, a capital letter
/// moved and a mark after it; `format` checks that before returning, and gives back the engine's
/// text unchanged if anything else happened.
public enum ParagraphFormatter {

    public static func words(in turns: [String]) -> (words: [Substring], turnStarts: Set<Int>) {
        var words: [Substring] = []
        var starts = Set<Int>()
        for turn in turns {
            starts.insert(words.count)
            words += turn.split(whereSeparator: \.isWhitespace)
        }
        return (words, starts)
    }

    /// - Parameters:
    ///   - turns: The engine's turns for one speaker, in order.
    ///   - labels: The model's labels for `words(in: turns).words`, one per word.
    ///   - closed: Whether the speaker has finished. An unfinished paragraph gets no full stop
    ///     after its last word, because more words may follow it.
    public static func format(turns: [String], labels: [WordLabel], closed: Bool = true) -> String {
        let (words, turnStarts) = words(in: turns)
        let original = turns.joined(separator: " ")
        guard !words.isEmpty, labels.count == words.count else { return original }

        var out: [String] = []
        var sentenceStart = true
        for (index, (word, label)) in zip(words, labels).enumerated() {
            let core = Punctuator.core(word)
            guard !core.isEmpty else {
                out.append(String(word))
                continue
            }
            let before = word[word.startIndex..<core.startIndex]
            let after = word[core.endIndex...]
            let engineMark = after.last(where: { ".?!,".contains($0) })

            var text: String
            if core.dropFirst().contains(where: \.isUppercase) {
                // LA, McDonald's: the engine's spelling.
                text = String(core)
            } else {
                text = label.cased
                // The engine's proper nouns. Not at the start of a turn, where its capital is only
                // its guess at where a sentence starts.
                if core.first?.isUppercase == true, text.first?.isUppercase != true, !turnStarts.contains(index) {
                    text = String(core)
                }
            }
            if sentenceStart, let first = text.first {
                text = first.uppercased() + text.dropFirst()
            }

            var mark: String
            if let engineMark, ".?!".contains(engineMark) {
                // Whatever the engine wrote after it, if it ended a sentence ("..", "?").
                mark = String(after)
            } else if let modelMark = label.mark, modelMark == "." || modelMark == "?" {
                mark = String(modelMark)
            } else if label.endsSentence {
                mark = "."
            } else if engineMark == "," || label.mark == "," {
                mark = ","
            } else {
                mark = String(after)
            }
            if index == words.count - 1 {
                if closed, mark.isEmpty || mark == "," { mark = "." }
                if !closed, mark == "," { mark = "" }
            }
            out.append(before + text + mark)
            sentenceStart = mark.last.map { ".?!".contains($0) } ?? false
        }
        let result = out.joined(separator: " ")
        return sameWords(result, original) ? result : original
    }

    /// The guarantee: the same words in the same order, ignoring case and the marks around them.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        func cores(_ text: String) -> [String] {
            text.split(whereSeparator: \.isWhitespace).map { Punctuator.core($0).lowercased() }
        }
        return cores(a) == cores(b)
    }
}
