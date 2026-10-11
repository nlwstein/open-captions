import Foundation

/// SentencePiece's unigram tokenizer, for one word at a time.
///
/// The punctuation model reads SentencePiece ids, and SentencePiece has no Swift port, so this is
/// the part of it that model needs: the Viterbi segmentation of a lowercase word into the
/// highest-scoring pieces. Words are tokenized one by one rather than as a sentence, which gives
/// the same ids (the model's tokenizer never lets a piece cross a space) and means every id is
/// known to belong to exactly one word.
///
/// Checked against SentencePiece itself on every word of the fixtures and DiPCo windows; see
/// `PieceTokenizerTests`.
public struct PieceTokenizer: Sendable {
    public static let unknownID: Int32 = 0
    public static let beginID: Int32 = 1
    public static let endID: Int32 = 2
    public static let padID: Int32 = 3

    /// Every ordinary piece, by its text.
    private let ids: [String: Int32]
    private let scores: [Float]
    private let pieces: [String]
    /// Longest piece, in Unicode scalars, which bounds the search at each position.
    private let longest: Int
    /// What an unknown character costs: SentencePiece's lowest score less its penalty of 10.
    private let unknownScore: Float

    /// - Parameter vocabulary: One piece per line, `piece<TAB>score<TAB>type`, in id order, as
    ///   `Scripts/make-punctuation-model.sh` writes it. Type 1 is an ordinary piece; others
    ///   (unknown, control) are never produced by segmentation.
    public init(vocabulary: String) throws {
        var ids: [String: Int32] = [:]
        var scores: [Float] = []
        var pieces: [String] = []
        var longest = 1
        var lowest = Float.greatestFiniteMagnitude
        for line in vocabulary.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let score = Float(fields[1]), let type = Int(fields[2]) else {
                throw PunctuationError.badVocabulary(String(line))
            }
            let piece = String(fields[0])
            let id = Int32(pieces.count)
            pieces.append(piece)
            scores.append(score)
            if type == 1 {
                ids[piece] = id
                longest = max(longest, piece.unicodeScalars.count)
                lowest = min(lowest, score)
            }
        }
        guard !ids.isEmpty else { throw PunctuationError.badVocabulary("no pieces") }
        self.ids = ids
        self.scores = scores
        self.pieces = pieces
        self.longest = longest
        self.unknownScore = lowest - 10
    }

    public func piece(_ id: Int32) -> String {
        pieces.indices.contains(Int(id)) ? pieces[Int(id)] : ""
    }

    /// The ids for one word, which should already be lowercase and free of spaces.
    public func encode(word: String) -> [Int32] {
        let scalars = Array(("\u{2581}" + word).unicodeScalars)
        let count = scalars.count
        // best[i]: the highest total score of any segmentation of the first i scalars.
        var best = [Float](repeating: -.infinity, count: count + 1)
        var from = [Int](repeating: -1, count: count + 1)
        var chosen = [Int32](repeating: Self.unknownID, count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] > -.infinity {
            var single = false
            for end in (start + 1)...min(count, start + longest) {
                var text = String.UnicodeScalarView()
                text.append(contentsOf: scalars[start..<end])
                guard let id = ids[String(text)] else { continue }
                if end == start + 1 { single = true }
                let score = best[start] + scores[Int(id)]
                if score > best[end] {
                    best[end] = score
                    from[end] = start
                    chosen[end] = id
                }
            }
            // A character no piece covers becomes the unknown piece, as SentencePiece does.
            if !single {
                let score = best[start] + unknownScore
                if score > best[start + 1] {
                    best[start + 1] = score
                    from[start + 1] = start
                    chosen[start + 1] = Self.unknownID
                }
            }
        }
        var result: [Int32] = []
        var position = count
        while position > 0 {
            result.append(chosen[position])
            position = from[position]
        }
        result.reverse()
        // SentencePiece reports a run of unknown characters as one unknown piece.
        var merged: [Int32] = []
        for id in result where !(id == Self.unknownID && merged.last == Self.unknownID) {
            merged.append(id)
        }
        return merged
    }
}

public enum PunctuationError: Error, CustomStringConvertible {
    case badVocabulary(String)
    case modelMissing(URL)
    case badOutput(String)

    public var description: String {
        switch self {
        case .badVocabulary(let line): return "Unreadable punctuation vocabulary line: \(line)"
        case .modelMissing(let url): return "No punctuation model at \(url.path)"
        case .badOutput(let what): return "Unexpected punctuation model output: \(what)"
        }
    }
}
