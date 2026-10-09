import Foundation

/// Outcome of scoring a transcript against a reference on the information that carries meaning.
public struct CriticalInfoReport: Codable, Equatable, Sendable {

    public enum Category: String, Codable, CaseIterable, Sendable {
        case name
        case number
        case negation
    }

    public struct CategoryScore: Codable, Equatable, Sendable {
        /// Critical tokens present in the reference.
        public let total: Int
        public let correct: Int
        /// Fraction of this category the recognizer preserved. A category with nothing to test
        /// scores 1 — absence of names is not a failure to capture names.
        public let recall: Double

        public init(total: Int, correct: Int, recall: Double) {
            self.total = total
            self.correct = correct
            self.recall = recall
        }
    }

    public struct Miss: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            /// The recognizer produced nothing where the word was spoken.
            case dropped
            /// The recognizer produced a different word.
            case changed
            /// The recognizer produced a word that was never spoken — a hallucinated negation.
            case added
        }

        public enum Severity: String, Codable, Comparable, Sendable {
            /// Inverts or invents meaning: a lost, altered, or hallucinated negation, or a wrong
            /// number.
            case severe
            /// A different name than the one spoken.
            case moderate
            /// Likely the same name, mis-spelled.
            case minor

            private var rank: Int {
                switch self {
                case .minor: return 0
                case .moderate: return 1
                case .severe: return 2
                }
            }

            public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
        }

        public let category: Category
        /// The reference word. Nil when the recognizer invented a word that was never spoken.
        public let spoken: String?
        /// What the recognizer produced instead, when it produced anything.
        public let heardAs: String?
        public let outcome: Outcome
        public let severity: Severity
        /// Surrounding words for a human reading the report.
        public let context: String
        public let referenceIndex: Int?

        public init(
            category: Category,
            spoken: String?,
            heardAs: String?,
            outcome: Outcome,
            severity: Severity,
            context: String,
            referenceIndex: Int?
        ) {
            self.category = category
            self.spoken = spoken
            self.heardAs = heardAs
            self.outcome = outcome
            self.severity = severity
            self.context = context
            self.referenceIndex = referenceIndex
        }
    }

    /// Per-category results as named fields rather than a dictionary keyed by enum, so the JSON
    /// report reads cleanly instead of encoding as an alternating key/value array.
    public struct CategoryScores: Codable, Equatable, Sendable {
        public let name: CategoryScore
        public let number: CategoryScore
        public let negation: CategoryScore

        public init(name: CategoryScore, number: CategoryScore, negation: CategoryScore) {
            self.name = name
            self.number = number
            self.negation = negation
        }

        public subscript(category: Category) -> CategoryScore {
            switch category {
            case .name: return name
            case .number: return number
            case .negation: return negation
            }
        }
    }

    public let misses: [Miss]
    public let categories: CategoryScores

    public init(misses: [Miss], categories: CategoryScores) {
        self.misses = misses
        self.categories = categories
    }

    /// Mean recall across the three categories, equally weighted. This is the headline number:
    /// 1.0 means every name, number, and negation survived.
    public var score: Double {
        let scores = Category.allCases.map { categories[$0].recall }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Failures that invert or invent meaning. This is the number to act on — a transcript can
    /// score well overall while containing a polarity flip that changes what a doctor said.
    public var severeMisses: [Miss] {
        misses.filter { $0.severity == .severe }
    }

    public var severeMissCount: Int { severeMisses.count }

    public var totalCriticalTokens: Int {
        Category.allCases.reduce(0) { $0 + categories[$1].total }
    }
}
