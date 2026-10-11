import CoreML
import Foundation

/// What the punctuation model says about one word.
public struct WordLabel: Equatable, Sendable {
    /// The mark after the word: ".", "?", "," or none.
    public var mark: Character?
    /// A sentence ends after this word, whether or not it has a mark.
    public var endsSentence: Bool
    /// The word as the model would case it, letters otherwise unchanged.
    public var cased: String

    public init(mark: Character?, endsSentence: Bool, cased: String) {
        self.mark = mark
        self.endsSentence = endsSentence
        self.cased = cased
    }
}

/// Punctuation, casing and sentence ends for text that has none, from `punct_cap_seg_en`
/// (1-800-BAD-CODE, Apache-2.0): a 52M-parameter token classifier.
///
/// A classifier rather than a model that writes text, which is the point. It can only label the
/// words it is given — a mark after this one, capitals in that one — so it cannot drop, add or
/// change a word however wrong it is. A rewriting model (an LLM) can, and on captions for someone
/// who cannot hear the original, a changed word is the one failure that must not happen.
///
/// Converted to Core ML by `Scripts/make-punctuation-model.sh`, whose predictions were checked
/// against the original ONNX model's.
public final class Punctuator: @unchecked Sendable {
    /// Tokens per window, BOS and EOS included. The model has 512 positions but was trained on 256.
    static let window = 256
    /// Tokens either side of a cut between windows that only lend context. Each token's labels
    /// come from the window where it is furthest from a cut.
    static let context = 16
    /// Index is the model's post-punctuation label. Label 1 is ACRONYM, a mark after every letter
    /// ("u.s."), which would change how a word is spelled; it is read as no mark.
    private static let marks: [Character?] = [nil, nil, ".", ",", "?"]

    private let model: MLModel
    private let tokenizer: PieceTokenizer
    private let lock = NSLock()

    public init(model: MLModel, tokenizer: PieceTokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    /// Loads a model directory as `make-punctuation-model.sh` writes it: `Punctuation.mlmodelc`
    /// or `Punctuation.mlpackage`, and `vocabulary.tsv`.
    public static func load(directory: URL, computeUnits: MLComputeUnits = .all) throws -> Punctuator {
        let fm = FileManager.default
        let compiled = directory.appendingPathComponent("Punctuation.mlmodelc")
        let package = directory.appendingPathComponent("Punctuation.mlpackage")
        let modelURL: URL
        if fm.fileExists(atPath: compiled.path) {
            modelURL = compiled
        } else if fm.fileExists(atPath: package.path) {
            modelURL = try MLModel.compileModel(at: package)
        } else {
            throw PunctuationError.modelMissing(directory)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let vocabulary = try String(contentsOf: directory.appendingPathComponent("vocabulary.tsv"), encoding: .utf8)
        return Punctuator(model: model, tokenizer: try PieceTokenizer(vocabulary: vocabulary))
    }

    /// The word itself, without punctuation the engine put around it. Apostrophes are part of a
    /// word; hyphens inside one are kept because only the ends are trimmed.
    public static func core(_ token: Substring) -> Substring {
        func inWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "_" }
        guard let first = token.firstIndex(where: inWord), let last = token.lastIndex(where: inWord) else {
            return token[token.startIndex..<token.startIndex]
        }
        return token[first...last]
    }

    /// One label per word, in order. `words` are the engine's, punctuation and all.
    public func label(_ words: [Substring]) throws -> [WordLabel] {
        let cores = words.map { Self.core($0).lowercased() }
        var spans: [Range<Int>] = []
        var flat: [Int32] = []
        for core in cores {
            let ids = core.isEmpty ? [] : tokenizer.encode(word: core)
            spans.append(flat.count..<(flat.count + ids.count))
            flat += ids
        }

        var post = [Int32](repeating: 0, count: flat.count)
        var seg = [Bool](repeating: false, count: flat.count)
        var caps = [[Bool]](repeating: [], count: flat.count)
        let usable = Self.window - 2
        var start = 0
        while start < flat.count {
            let stop = min(flat.count, start + usable)
            let out = try run(Array(flat[start..<stop]))
            let keepFrom = start == 0 ? start : start + Self.context
            let keepTo = stop == flat.count ? stop : stop - Self.context
            for token in keepFrom..<keepTo {
                let position = token - start + 1   // after BOS
                post[token] = out.post[position]
                seg[token] = out.seg[position]
                caps[token] = out.caps[position]
            }
            if stop == flat.count { break }
            start = stop - 2 * Self.context
        }

        return zip(words, zip(cores, spans)).map { word, entry in
            let (core, span) = entry
            let plain = String(Self.core(word))
            guard let lastToken = span.last else { return WordLabel(mark: nil, endsSentence: false, cased: plain) }
            var cased = ""
            for token in span {
                let piece = Array(tokenizer.piece(flat[token]))
                let offset = piece.first == "\u{2581}" ? 1 : 0
                for index in offset..<piece.count {
                    let upper = index < caps[token].count && caps[token][index]
                    cased += upper ? piece[index].uppercased() : String(piece[index])
                }
            }
            // A piece that is not the text, such as the unknown piece: leave the word as it was.
            if cased.lowercased() != core { cased = plain }
            let label = Int(post[lastToken])
            let mark = Self.marks.indices.contains(label) ? Self.marks[label] : nil
            return WordLabel(mark: mark, endsSentence: seg[lastToken], cased: cased)
        }
    }

    private struct Output {
        var post: [Int32]
        var seg: [Bool]
        var caps: [[Bool]]
    }

    private func run(_ ids: [Int32]) throws -> Output {
        let length = ids.count + 2
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.window)], dataType: .int32)
        let pointer = input.dataPointer.bindMemory(to: Int32.self, capacity: Self.window)
        for index in 0..<Self.window { pointer[index] = PieceTokenizer.padID }
        pointer[0] = PieceTokenizer.beginID
        for (index, id) in ids.enumerated() { pointer[index + 1] = id }
        pointer[length - 1] = PieceTokenizer.endID

        let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: input)])
        lock.lock()
        defer { lock.unlock() }
        let result = try model.prediction(from: provider)
        guard let post = result.featureValue(for: "post_preds")?.multiArrayValue,
              let cap = result.featureValue(for: "cap_preds")?.multiArrayValue,
              let seg = result.featureValue(for: "seg_preds")?.multiArrayValue,
              cap.shape.count == 3
        else { throw PunctuationError.badOutput("missing outputs") }
        let letters = cap.shape[2].intValue
        // Read by strides: Core ML may pad the rows of an output it allocated itself.
        func int(_ array: MLMultiArray, _ indexes: [Int]) -> Int32 {
            var offset = 0
            for (axis, index) in indexes.enumerated() { offset += index * array.strides[axis].intValue }
            return array.dataPointer.bindMemory(to: Int32.self, capacity: offset + 1)[offset]
        }
        var output = Output(post: [], seg: [], caps: [])
        for position in 0..<length {
            output.post.append(int(post, [0, position]))
            output.seg.append(int(seg, [0, position]) != 0)
            output.caps.append((0..<letters).map { int(cap, [0, position, $0]) != 0 })
        }
        return output
    }
}
