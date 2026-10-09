import Foundation

/// Scores whether a transcript preserved the information that actually matters: names, numbers,
/// and negations.
///
/// Word Error Rate treats every word as equally important, which is exactly backwards for this
/// application. Dropping the word "the" is harmless; dropping the "not" in "do not take the
/// second pill" inverts the meaning, and "Dr. Feldman" becoming "Dr. Feldman's" is noise while
/// "Dr. Feldman" becoming "Dr. Bellman" is a different person.
///
/// The scorer aligns reference and hypothesis once (on semantically-folded tokens, so "fifteen"
/// and "15" compare equal) and then evaluates the three categories against that alignment.
public struct CriticalInfoScorer {

    /// Names that matter to this user — family, doctors, medications, places. These are matched in
    /// addition to heuristically detected proper nouns, and are the reliable way to catch names the
    /// recognizer lowercased.
    public var knownNames: Set<String>

    /// A number token: digits, optionally with an interior decimal point, colon, or hyphen
    /// ("15", "3.5", "2:30", "9-1-1").
    private static let numberPattern = try? NSRegularExpression(pattern: "^[0-9]+([.:-][0-9]+)*$")

    public init(knownNames: Set<String> = []) {
        self.knownNames = Set(knownNames.map { $0.lowercased() })
    }

    public func score(reference: String, hypothesis: String) -> CriticalInfoReport {
        let referenceTokens = TextNormalizer.semanticTokens(reference)
        let hypothesisTokens = TextNormalizer.semanticTokens(hypothesis)
        let alignment = WordAligner.align(reference: referenceTokens, hypothesis: hypothesisTokens)

        let nameTokens = Set(TextNormalizer.detectProperNouns(in: reference)).union(knownNames)

        var tallies: [CriticalInfoReport.Category: (total: Int, correct: Int)] = [:]
        var misses: [CriticalInfoReport.Miss] = []

        for (index, token) in referenceTokens.enumerated() {
            guard let kind = category(of: token, nameTokens: nameTokens) else { continue }
            tallies[kind, default: (0, 0)].total += 1

            let aligned = alignment.hypothesisIndex(forReference: index)
            let heard = aligned.map { hypothesisTokens[$0] }

            if let heard, isEquivalent(heard, to: token, kind: kind) {
                tallies[kind, default: (0, 0)].correct += 1
                continue
            }

            let outcome: CriticalInfoReport.Miss.Outcome = heard == nil ? .dropped : .changed
            misses.append(CriticalInfoReport.Miss(
                category: kind,
                spoken: token,
                heardAs: heard,
                outcome: outcome,
                severity: severity(kind: kind, spoken: token, heardAs: heard),
                context: context(around: index, in: referenceTokens),
                referenceIndex: index
            ))
        }

        // A negation the recognizer invented is as dangerous as one it dropped — it reverses
        // meaning that was never negated. These have no matching reference negation, so they need
        // their own pass over the hypothesis side.
        //
        // Both insertions and substitutions matter here. "said to take it" becoming "said not to
        // take it" aligns as an extra word, but "I can walk" becoming "I can't walk" aligns as a
        // substitution of "can" for "can't" — same inversion, different edit.
        for operation in alignment.operations {
            let hypothesisIndex: Int
            let referenceIndex: Int?
            switch operation {
            case .insertion(let hypothesis):
                hypothesisIndex = hypothesis
                referenceIndex = nil
            case .substitution(let reference, let hypothesis):
                hypothesisIndex = hypothesis
                referenceIndex = reference
            case .correct, .deletion:
                continue
            }

            let token = hypothesisTokens[hypothesisIndex]
            guard TextNormalizer.isNegation(token) else { continue }
            // A swap between two negations preserves polarity and is already scored above.
            if let referenceIndex, TextNormalizer.isNegation(referenceTokens[referenceIndex]) {
                continue
            }

            misses.append(CriticalInfoReport.Miss(
                category: .negation,
                spoken: referenceIndex.map { referenceTokens[$0] },
                heardAs: token,
                outcome: .added,
                severity: .severe,
                context: context(around: hypothesisIndex, in: hypothesisTokens),
                referenceIndex: nil
            ))
        }

        func score(_ category: CriticalInfoReport.Category) -> CriticalInfoReport.CategoryScore {
            let tally = tallies[category] ?? (0, 0)
            return CriticalInfoReport.CategoryScore(
                total: tally.total,
                correct: tally.correct,
                recall: tally.total == 0 ? 1 : Double(tally.correct) / Double(tally.total)
            )
        }

        return CriticalInfoReport(
            misses: misses,
            categories: CriticalInfoReport.CategoryScores(
                name: score(.name),
                number: score(.number),
                negation: score(.negation)
            )
        )
    }

    // MARK: - Classification

    /// Which category a single token belongs to, or `nil` if it is not critical information.
    ///
    /// Public and static so the live view can tag words with the same rule the scorer grades with.
    /// Two copies of this logic would drift, and the whole point of the tag is to show the user what
    /// the score is about to be computed over.
    ///
    /// The token is expected to be *semantic* — folded by ``TextNormalizer/semanticTokens(_:)``, so
    /// "fifteen" has already become "15". A raw surface token will still classify correctly for
    /// negations and known names, but spelled-out numbers will slip through.
    public static func category(
        of token: String,
        knownNames: Set<String>
    ) -> CriticalInfoReport.Category? {
        if TextNormalizer.isNegation(token) { return .negation }
        if isNumber(token) { return .number }
        if knownNames.contains(token) { return .name }
        return nil
    }

    private func category(
        of token: String,
        nameTokens: Set<String>
    ) -> CriticalInfoReport.Category? {
        Self.category(of: token, knownNames: nameTokens)
    }

    private static func isNumber(_ token: String) -> Bool {
        guard let numberPattern = Self.numberPattern else { return false }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return numberPattern.firstMatch(in: token, range: range) != nil
    }

    /// Whether the recognizer's token preserves the reference token's meaning.
    private func isEquivalent(
        _ heard: String,
        to spoken: String,
        kind: CriticalInfoReport.Category
    ) -> Bool {
        switch kind {
        case .negation:
            // Any negation in the aligned slot preserves polarity; "don't" for "do not" is fine.
            return TextNormalizer.isNegation(heard)
        case .number, .name:
            // Both sides are already folded to canonical form, so equality is the test.
            return heard == spoken
        }
    }

    private func severity(
        kind: CriticalInfoReport.Category,
        spoken: String,
        heardAs: String?
    ) -> CriticalInfoReport.Miss.Severity {
        switch kind {
        case .negation:
            // Losing or changing a negation inverts meaning outright.
            return .severe
        case .number:
            return .severe
        case .name:
            guard let heardAs else { return .moderate }
            // Only a single-character difference counts as the same name mis-spelled. The
            // threshold is deliberately tight: "Feldman" to "Bellman" is two edits and a
            // completely different person, and under-reporting a wrong name in a doctor's visit is
            // the failure this whole scorer exists to catch.
            return WordAligner.characterEditDistance(spoken, heardAs) <= 1 ? .minor : .moderate
        }
    }

    /// Surrounding words, so a person reading the report can see what was actually said.
    private func context(around index: Int, in tokens: [String]) -> String {
        let lower = max(0, index - 4)
        let upper = min(tokens.count - 1, index + 4)
        return tokens[lower...upper].joined(separator: " ")
    }
}
