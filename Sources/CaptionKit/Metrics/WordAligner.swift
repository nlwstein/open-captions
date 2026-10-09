import Foundation

/// A word-level alignment between a reference transcript and a hypothesis.
///
/// This is the shared spine of evaluation: Word Error Rate reads the operation counts, and
/// ``CriticalInfoScorer`` reads ``hypothesisIndex(forReference:)`` to find what the recognizer
/// produced where a name, number, or negation was spoken.
public struct WordAlignment {

    public enum Operation: Equatable {
        case correct(reference: Int, hypothesis: Int)
        case substitution(reference: Int, hypothesis: Int)
        /// A word the recognizer produced that was never spoken.
        case insertion(hypothesis: Int)
        /// A spoken word the recognizer dropped.
        case deletion(reference: Int)
    }

    public let operations: [Operation]
    public let referenceCount: Int
    public let hypothesisCount: Int

    public init(operations: [Operation], referenceCount: Int, hypothesisCount: Int) {
        self.operations = operations
        self.referenceCount = referenceCount
        self.hypothesisCount = hypothesisCount
    }

    public var correct: Int { count { if case .correct = $0 { return true }; return false } }
    public var substitutions: Int { count { if case .substitution = $0 { return true }; return false } }
    public var insertions: Int { count { if case .insertion = $0 { return true }; return false } }
    public var deletions: Int { count { if case .deletion = $0 { return true }; return false } }

    private func count(matching predicate: (Operation) -> Bool) -> Int {
        var total = 0
        for operation in operations where predicate(operation) { total += 1 }
        return total
    }

    /// Word Error Rate: (substitutions + deletions + insertions) / reference word count.
    /// Returns 0 for an empty reference (nothing was spoken, so nothing could be missed).
    public var wordErrorRate: Double {
        guard referenceCount > 0 else { return hypothesisCount == 0 ? 0 : 1 }
        return Double(substitutions + deletions + insertions) / Double(referenceCount)
    }

    /// Index into the hypothesis aligned to a reference token, or nil when the word was dropped.
    public func hypothesisIndex(forReference index: Int) -> Int? {
        for operation in operations {
            switch operation {
            case .correct(let reference, let hypothesis), .substitution(let reference, let hypothesis):
                if reference == index { return hypothesis }
            case .deletion(let reference):
                if reference == index { return nil }
            case .insertion:
                continue
            }
        }
        return nil
    }

    /// Reference token indices whose aligned hypothesis token is an insertion adjacent to them —
    /// used to spot a negation that was *added* rather than dropped.
    public func hypothesisTokens(where predicate: (Operation) -> Bool) -> [Int] {
        operations.compactMap { operation in
            guard predicate(operation) else { return nil }
            if case .insertion(let hypothesis) = operation { return hypothesis }
            return nil
        }
    }
}

/// Computes word-level alignments using Levenshtein edit distance with a full backtrace.
///
/// Complexity is O(n·m) time and space over word counts. A ten-minute conversation runs to
/// roughly 1,500 words, so the 2.25M-cell worst case is comfortably fast; pathological inputs
/// beyond ~10,000 words would need a banded or Hirschberg alignment instead.
public enum WordAligner {

    /// Shorthand for the nested operation type. Spelling it out is necessary rather than
    /// stylistic: an unqualified `Operation` inside this type resolves to Foundation's
    /// `Operation` (NSOperation) and every case then fails to match.
    private typealias Op = WordAlignment.Operation

    private enum Move: UInt8 {
        case diagonal = 0
        case up = 1    // reference word deleted (missing from hypothesis)
        case left = 2  // hypothesis word inserted (never spoken)
    }

    public static func align(reference: [String], hypothesis: [String]) -> WordAlignment {
        let n = reference.count
        let m = hypothesis.count

        if n == 0 || m == 0 {
            var operations: [Op] = []
            if n == 0 {
                operations = (0..<m).map { .insertion(hypothesis: $0) }
            } else {
                operations = (0..<n).map { .deletion(reference: $0) }
            }
            return WordAlignment(operations: operations, referenceCount: n, hypothesisCount: m)
        }

        // Rolling cost rows keep the distance computation at O(m) memory; the backtrace pointers
        // are retained in full so the alignment can be reconstructed.
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        var moves = [Move](repeating: .diagonal, count: (n + 1) * (m + 1))
        let stride = m + 1

        for i in 1...n {
            current[0] = i
            moves[i * stride] = .up
            for j in 1...m {
                let isMatch = reference[i - 1] == hypothesis[j - 1]
                let diagonalCost = previous[j - 1] + (isMatch ? 0 : 1)
                let upCost = previous[j] + 1
                let leftCost = current[j - 1] + 1

                // Ties prefer the diagonal so alignment stays tight rather than padding with
                // insert/delete pairs, which would overstate both error counts.
                if diagonalCost <= upCost, diagonalCost <= leftCost {
                    current[j] = diagonalCost
                    moves[i * stride + j] = .diagonal
                } else if upCost <= leftCost {
                    current[j] = upCost
                    moves[i * stride + j] = .up
                } else {
                    current[j] = leftCost
                    moves[i * stride + j] = .left
                }
            }
            swap(&previous, &current)
        }

        var operations: [Op] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            // Written as statements rather than a nested ternary: the chained conditional defeats
            // the type checker on this expression.
            let move: Move
            if i > 0, j > 0 {
                move = moves[i * stride + j]
            } else if i > 0 {
                move = .up
            } else {
                move = .left
            }
            switch move {
            case .diagonal:
                let isMatch = reference[i - 1] == hypothesis[j - 1]
                operations.append(isMatch
                    ? .correct(reference: i - 1, hypothesis: j - 1)
                    : .substitution(reference: i - 1, hypothesis: j - 1))
                i -= 1
                j -= 1
            case .up:
                operations.append(.deletion(reference: i - 1))
                i -= 1
            case .left:
                operations.append(.insertion(hypothesis: j - 1))
                j -= 1
            }
        }

        return WordAlignment(
            operations: operations.reversed(),
            referenceCount: n,
            hypothesisCount: m
        )
    }

    /// Levenshtein distance between two strings, used to tell a mis-spelled name from a different
    /// name. Uses two rolling rows, so memory is O(min(a, b)).
    public static func characterEditDistance(_ a: String, _ b: String) -> Int {
        let left = Array(a)
        let right = Array(b)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
