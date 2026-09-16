import Foundation

/// Digit-aware interpretation of OCR tokens.
///
/// Scorecards are dense grids of small printed numbers, which is exactly the regime where Vision returns
/// `33B` for `333`, `l71` for `171` and `S` for `5`. Every numeric read in this kit goes through here so
/// that "the OCR was nearly right" is a first-class, *scored* outcome rather than a silent failure.
///
/// The rule this type exists to support: a near-miss may be used to **recognize** a card (evidence for a
/// template match), and a matched template may then restore a printed value — but a near-miss is never
/// promoted to a confident value on its own.
public enum NumericOCR {

    /// Letters and symbols that are routinely emitted in place of a digit, with the digits they stand for.
    /// Ordered best-guess first.
    static let glyphToDigits: [Character: [Character]] = [
        "O": ["0"], "o": ["0"], "D": ["0"], "Q": ["0"], "U": ["0"],
        "I": ["1"], "i": ["1"], "l": ["1"], "L": ["1"], "|": ["1"], "!": ["1"], "]": ["1"], "[": ["1"],
        "Z": ["2"], "z": ["2"],
        "B": ["8", "3"], "E": ["3"],
        "A": ["4"], "h": ["4"], "y": ["4"],
        "S": ["5"], "s": ["5"],
        "G": ["6"], "b": ["6"],
        "T": ["7"], "t": ["7"], "/": ["7"], "\\": ["7"],
        "g": ["9"], "q": ["9"], "P": ["9"]
    ]

    /// Digit pairs a recognizer confuses often enough that disagreement is weak evidence, not proof.
    /// Symmetric; each entry is scored as a *partial* match.
    static let digitConfusionPairs: Set<Pair> = {
        let raw: [(Character, Character)] = [
            ("0", "8"), ("0", "6"), ("0", "9"), ("0", "D"),
            ("1", "7"), ("1", "4"),
            ("3", "8"), ("3", "9"), ("3", "5"), ("3", "2"),
            ("5", "6"), ("5", "8"), ("5", "9"),
            ("6", "8"), ("6", "5"),
            ("7", "1"), ("7", "9"),
            ("8", "9"), ("8", "3"), ("8", "6"), ("8", "0"),
            ("9", "4"), ("9", "7"), ("9", "8"),
            ("2", "7")
        ]
        return Set(raw.map { Pair($0.0, $0.1) })
    }()

    struct Pair: Hashable {
        let a: Character
        let b: Character
        init(_ x: Character, _ y: Character) {
            // Normalize ordering so the set behaves symmetrically.
            if x <= y { a = x; b = y } else { a = y; b = x }
        }
    }

    // MARK: - Candidate generation

    /// Every integer the token could plausibly be, most plausible first.
    ///
    /// Only *non-digit* characters are expanded. Expanding digits as well would turn `333` into hundreds of
    /// candidates and let the template matcher "confirm" anything it liked; disagreement between two digits
    /// is handled by scoring at comparison time instead.
    public static func integerCandidates(from raw: String, maxCandidates: Int = 8) -> [Int] {
        let cleaned = strippedForNumericReading(raw)
        guard !cleaned.isEmpty, cleaned.count <= 6 else { return [] }

        var expansions: [[Character]] = []
        var ambiguousCount = 0
        for character in cleaned {
            if character.isNumber {
                expansions.append([character])
            } else if let options = glyphToDigits[character] {
                ambiguousCount += 1
                // Guard against combinatorial blow-up on a token that is really just a word.
                guard ambiguousCount <= 3 else { return [] }
                expansions.append(options)
            } else {
                return []
            }
        }
        guard !expansions.isEmpty else { return [] }

        // A token with no digits at all (e.g. "OUT" -> "007") is a word, not a number. A lone glyph is
        // only read as a digit when it stands for exactly one digit, so a tee abbreviation like "B" is
        // never mistaken for the score 8.
        let digitCount = cleaned.filter { $0.isNumber }.count
        if digitCount == 0 {
            guard cleaned.count == 1, expansions[0].count == 1 else { return [] }
        }

        var results: [String] = [""]
        for options in expansions {
            var next: [String] = []
            next.reserveCapacity(results.count * options.count)
            for prefix in results {
                for option in options {
                    next.append(prefix + String(option))
                }
            }
            results = next
            if results.count > maxCandidates * 4 { break }
        }

        var seen = Set<Int>()
        var ordered: [Int] = []
        for candidate in results {
            guard let value = Int(candidate) else { continue }
            if seen.insert(value).inserted {
                ordered.append(value)
            }
            if ordered.count >= maxCandidates { break }
        }
        return ordered
    }

    /// The single best integer reading of a token, optionally constrained to a plausible range.
    ///
    /// `penalty` is `0` for a clean digits-only read and grows as the reading relies on glyph substitution,
    /// so callers can lower a field's confidence instead of pretending the read was clean.
    public static func bestInteger(
        from raw: String,
        plausibleRange: ClosedRange<Int>? = nil
    ) -> (value: Int, penalty: Double)? {
        let candidates = integerCandidates(from: raw)
        guard !candidates.isEmpty else { return nil }

        let cleaned = strippedForNumericReading(raw)
        let substitutions = cleaned.filter { !$0.isNumber }.count
        let basePenalty = Double(substitutions) * 0.25

        if let range = plausibleRange {
            for (index, candidate) in candidates.enumerated() where range.contains(candidate) {
                return (candidate, min(1.0, basePenalty + Double(index) * 0.1))
            }
            // Nothing in range: report the best reading but flag it hard, so the caller drops it.
            return (candidates[0], 1.0)
        }
        return (candidates[0], min(1.0, basePenalty))
    }

    /// Removes grouping separators and surrounding punctuation, keeping only glyphs that could be digits.
    static func strippedForNumericReading(_ raw: String) -> String {
        var out = ""
        for character in raw {
            if character == "," || character == " " || character == "." || character == "'" || character == "-" || character == "_" {
                continue
            }
            out.append(character)
        }
        return out
    }

    // MARK: - Comparison

    /// How well an OCR token supports an expected integer, in `0...1`.
    ///
    /// `1.0` means the token reads exactly as the expected value. Values in between mean "this is what a
    /// recognizer typically does to that number" — strong enough to *identify* a card, never strong enough
    /// to assert a value by itself.
    public static func similarity(observedText: String, expected: Int) -> Double {
        let cleaned = strippedForNumericReading(observedText)
        guard !cleaned.isEmpty else { return 0 }

        if integerCandidates(from: cleaned).contains(expected) { return 1.0 }

        let expectedDigits = Array(String(expected))
        let observedDigits = Array(cleaned)
        return digitStringSimilarity(observedDigits, expectedDigits)
    }

    /// How well two integers agree, allowing for recognizer confusion. `1.0` when equal.
    public static func similarity(observed: Int, expected: Int) -> Double {
        if observed == expected { return 1.0 }
        return digitStringSimilarity(Array(String(observed)), Array(String(expected)))
    }

    static func digitStringSimilarity(_ observed: [Character], _ expected: [Character]) -> Double {
        guard !expected.isEmpty else { return 0 }
        if observed.count == expected.count {
            var total = 0.0
            for (lhs, rhs) in zip(observed, expected) {
                total += characterAgreement(lhs, rhs)
            }
            return total / Double(expected.count)
        }
        // A dropped or hallucinated digit is a much bigger error than a swapped one: scale an edit-distance
        // score down so a length mismatch can never look like a good match.
        let distance = levenshtein(observed, expected)
        let longest = max(observed.count, expected.count)
        let raw = 1.0 - Double(distance) / Double(longest)
        return max(0, raw) * 0.5
    }

    static func characterAgreement(_ lhs: Character, _ rhs: Character) -> Double {
        if lhs == rhs { return 1.0 }
        // A letter standing in for the expected digit is a clean read of that digit.
        if let digits = glyphToDigits[lhs], digits.contains(rhs) { return 1.0 }
        if digitConfusionPairs.contains(Pair(lhs, rhs)) { return 0.5 }
        return 0
    }

    static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
