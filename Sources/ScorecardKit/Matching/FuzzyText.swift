import Foundation

/// Fuzzy comparison for course names.
///
/// Course names come off a card through the worst possible channel: small stylised type, often reversed
/// out of a logo, often curved. `Steel Canyon Golf Club` routinely arrives as `STEE CANYON GOLE CLUB` or
/// as three separate observations. Two complementary measures are combined so neither failure mode is
/// fatal on its own — character damage is handled by edit distance, and dropped or re-ordered words are
/// handled by token overlap.
public enum FuzzyText {

    /// Edit-distance similarity in `0...1` over normalized strings.
    public static func characterSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(TextNormalizer.normalizeName(lhs))
        let b = Array(TextNormalizer.normalizeName(rhs))
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let distance = NumericOCR.levenshtein(a, b)
        return max(0, 1 - Double(distance) / Double(max(a.count, b.count)))
    }

    /// Token-overlap similarity that ignores word order and generic golf words.
    ///
    /// Each observed token is matched to its best expected token, so `CANYON STEEL` scores as highly as
    /// `STEEL CANYON`, and `Golf Club` contributes nothing to either side.
    public static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = TextNormalizer.significantNameTokens(lhs)
        let right = TextNormalizer.significantNameTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        func bestMatchScore(_ tokens: [String], against others: [String]) -> Double {
            var total = 0.0
            for token in tokens {
                var best = 0.0
                for other in others {
                    let a = Array(token)
                    let b = Array(other)
                    let distance = NumericOCR.levenshtein(a, b)
                    let score = max(0, 1 - Double(distance) / Double(max(a.count, b.count)))
                    best = max(best, score)
                }
                total += best
            }
            return total / Double(tokens.count)
        }

        // Symmetric: a short OCR fragment should not score perfectly just because it is contained in a
        // long course name, and a long name should not be punished for OCR dropping a word.
        let forward = bestMatchScore(left, against: right)
        let backward = bestMatchScore(right, against: left)
        return (forward * 0.5) + (backward * 0.5)
    }

    /// Combined name similarity, `0...1`.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let character = characterSimilarity(lhs, rhs)
        let token = tokenSimilarity(lhs, rhs)
        return max(character, token) * 0.7 + min(character, token) * 0.3
    }

    /// Best similarity between any observed text fragment and any of a course's matchable names.
    ///
    /// Adjacent fragments are also joined before comparing, because Vision frequently splits a course name
    /// across observations and neither half alone resembles the full name.
    public static func bestSimilarity(observedFragments: [String], candidateNames: [String]) -> (score: Double, fragment: String?, matchedName: String?) {
        guard !observedFragments.isEmpty, !candidateNames.isEmpty else { return (0, nil, nil) }

        let singles = observedFragments.filter { !TextNormalizer.normalizeName($0).isEmpty }
        var fragments = singles
        // Adjacent runs of up to three fragments, so a name split across observations is still comparable.
        for width in 2...3 where singles.count >= width {
            for start in 0...(singles.count - width) {
                fragments.append(singles[start..<(start + width)].joined(separator: " "))
            }
        }

        var best = (score: 0.0, fragment: nil as String?, matchedName: nil as String?)
        for fragment in fragments {
            for name in candidateNames {
                let score = similarity(fragment, name)
                if score > best.score {
                    best = (score, fragment, name)
                }
            }
        }
        return best
    }
}
