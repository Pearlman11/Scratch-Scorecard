import Foundation

/// Pulls golfers' scores out of the reconstructed table.
///
/// This type is held to a stricter standard than the static extractor, and the difference is deliberate.
/// A verified template can repair a misread yardage because the course's yardages are a fixed, knowable
/// fact. Nothing anywhere knows what the golfer shot. So:
///
/// - A cell that cannot be read confidently becomes `nil`, never a plausible-looking number.
/// - The plausible-score range is used only to **reject** readings, never to choose one. "It must be
///   between 1 and 15" is not a reason to write 4 into an empty cell.
/// - A blank cell stays blank. Golfers pick up, skip holes and play nine; an empty hole is information.
public struct PlayerScoreExtractor: Sendable {

    public struct Configuration: Sendable {
        /// OCR confidence below which a reading is kept but flagged for review.
        public var reviewThreshold: Double
        /// OCR confidence below which a reading is discarded entirely.
        ///
        /// Handwriting read this poorly is closer to noise than to a digit, and an empty cell the golfer
        /// fills in is far cheaper than a wrong number they do not notice.
        public var rejectThreshold: Double
        /// Fewest scored holes a row needs before it counts as a golfer rather than a stray mark.
        public var minimumScoredHoles: Int

        public init(
            reviewThreshold: Double = 0.82,
            rejectThreshold: Double = 0.30,
            minimumScoredHoles: Int = 2
        ) {
            self.reviewThreshold = reviewThreshold
            self.rejectThreshold = rejectThreshold
            self.minimumScoredHoles = minimumScoredHoles
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Extracts every golfer row on the card.
    ///
    /// - Parameters:
    ///   - table: the reconstructed table.
    ///   - holeCount: how many holes the card covers.
    ///   - pars: par per hole when known, used **only** to sanity-check implausible readings
    ///     (a "score" six strokes under par is a misread), never to fill a blank.
    public func extractPlayers(
        from table: DetectedTable,
        holeCount: Int,
        pars: [Int?] = []
    ) -> [DetectedPlayer] {
        guard holeCount > 0 else { return [] }

        // A player's row may be split across stacked sections (front nine above, back nine below). Rows are
        // keyed by the name written in the gutter when there is one, and otherwise by their position within
        // the section, which is how a card orders its blank score lines.
        var byKey: [String: (
            name: String?,
            scores: [ParsedField<Int>],
            confidence: Double,
            rowIndex: Int?,
            order: Int,
            out: ParsedField<Int>,
            inward: ParsedField<Int>,
            total: ParsedField<Int>
        )] = [:]
        var order = 0

        for section in table.sections {
            var unnamedIndex = 0
            for rowIndex in section.rowIndices {
                guard table.rows.indices.contains(rowIndex) else { continue }
                let row = table.rows[rowIndex]
                guard case .playerScores(let detectedName) = row.role else { continue }

                let name = detectedName.flatMap(cleanPlayerName)
                let key: String
                if let name {
                    key = TextNormalizer.normalizeLabel(name)
                } else {
                    key = "__row_\(unnamedIndex)"
                    unnamedIndex += 1
                }

                var entry = byKey[key] ?? (
                    name: name,
                    scores: [ParsedField<Int>](repeating: .empty, count: holeCount),
                    confidence: row.roleConfidence,
                    rowIndex: rowIndex,
                    order: order,
                    out: ParsedField<Int>.empty,
                    inward: ParsedField<Int>.empty,
                    total: ParsedField<Int>.empty
                )
                if byKey[key] == nil { order += 1 }
                if entry.name == nil { entry.name = name }
                entry.confidence = max(entry.confidence, row.roleConfidence)

                for cell in TableCellReader.holeCells(in: row, section: section) {
                    guard let hole = cell.holeNumber, hole >= 1, hole <= holeCount else { continue }
                    guard entry.scores[hole - 1].value == nil else { continue }
                    let par = pars.indices.contains(hole - 1) ? pars[hole - 1] : nil
                    entry.scores[hole - 1] = readScore(
                        cell: cell,
                        columnIsInterpolated: section.column(forHole: hole)?.isInterpolated ?? false,
                        par: par
                    )
                }

                // The written OUT / IN / TOTAL cells. These are the card's own checksum: a nine with one
                // unreadable score is fully determined by its subtotal, so they are worth reading even
                // though they duplicate information already in the row.
                for cell in TableCellReader.aggregateCells(in: row, section: section) {
                    guard !cell.isEmpty else { continue }
                    let field = readSubtotal(cell: cell, holeCount: holeCount)
                    switch cell.aggregateKind {
                    case .out: if !entry.out.hasValue { entry.out = field }
                    case .inward: if !entry.inward.hasValue { entry.inward = field }
                    case .total: if !entry.total.hasValue { entry.total = field }
                    case .none: break
                    }
                }
                byKey[key] = entry
            }
        }

        let ordered = byKey.values
            .sorted { $0.order < $1.order }
            .filter { entry in
                entry.scores.filter { $0.hasValue }.count >= configuration.minimumScoredHoles
            }

        return ordered.enumerated().map { index, entry in
            DetectedPlayer(
                name: entry.name,
                fallbackLabel: "Player \(index + 1)",
                sourceRowIndex: entry.rowIndex,
                scores: entry.scores,
                rowConfidence: entry.confidence,
                writtenOut: entry.out,
                writtenIn: entry.inward,
                writtenTotal: entry.total
            )
        }
    }

    /// Reads one score cell.
    ///
    /// Returns an empty field for anything that is blank, illegible, implausible, or read too poorly to
    /// trust. Every one of those outcomes is preferable to a confident wrong number, because a wrong number
    /// that looks right is the one error the golfer will not catch on the review screen.
    func readScore(cell: TableCell, columnIsInterpolated: Bool, par: Int?) -> ParsedField<Int> {
        guard !cell.isEmpty else { return .empty }

        let raw = cell.text
        guard let reading = NumericOCR.bestInteger(from: raw, plausibleRange: ScoreMath.plausibleScoreRange),
              reading.penalty < 1.0 else {
            // Something was written here but it could not be read as a stroke count. Say so, rather than
            // leaving the golfer to wonder whether the parser saw the cell at all.
            return ParsedField(value: nil, confidence: 0, provenance: .ocr, rawText: raw)
        }

        var confidence = cell.ocrConfidence
        // Glyph substitution, an invented column, or a value that is not golf all reduce trust.
        confidence *= (1 - reading.penalty * 0.6)
        if columnIsInterpolated { confidence *= 0.75 }
        if let par, !isPlausible(score: reading.value, par: par) {
            // The range check rejects; it never selects. An implausible reading yields no value at all.
            return ParsedField(value: nil, confidence: 0, provenance: .ocr, rawText: raw)
        }
        // A multi-digit score is unusual and is a classic misread of two adjacent single-digit cells.
        if reading.value >= 10 { confidence *= 0.7 }

        guard confidence >= configuration.rejectThreshold else {
            return ParsedField(value: nil, confidence: confidence, provenance: .ocr, rawText: raw)
        }
        return ParsedField(value: reading.value, confidence: min(1, confidence), provenance: .ocr, rawText: raw)
    }

    /// Reads a written OUT / IN / TOTAL cell.
    ///
    /// Bounded by what a real round can produce — nine (or eighteen) holes at one stroke minimum, capped
    /// generously above any plausible score. A reading outside that is discarded rather than kept, because
    /// a wrong subtotal is worse than none: the checksum solver trusts it enough to write a score from it.
    func readSubtotal(cell: TableCell, holeCount: Int) -> ParsedField<Int> {
        guard !cell.isEmpty else { return .empty }
        let holesInTotal = holeCount > 9 ? 18 : 9
        let range = holesInTotal...(holesInTotal * ScoreMath.plausibleScoreRange.upperBound)
        guard let reading = NumericOCR.bestInteger(from: cell.text, plausibleRange: range),
              reading.penalty < 1.0 else {
            return ParsedField(value: nil, confidence: 0, provenance: .ocr, rawText: cell.text)
        }
        let confidence = cell.ocrConfidence * (1 - reading.penalty * 0.6)
        return ParsedField(
            value: reading.value,
            confidence: min(1, confidence),
            provenance: .ocr,
            rawText: cell.text
        )
    }

    /// Whether a stroke count is possible on a hole of this par.
    ///
    /// Generous on the high side — anyone can make a 10 on a par 3 — but a score below par minus two is a
    /// hole-in-one on a par 4 or better, which is far more often a misread than a fact.
    func isPlausible(score: Int, par: Int) -> Bool {
        guard ScoreMath.plausibleScoreRange.contains(score) else { return false }
        if score < max(1, par - 3) { return false }
        if score > par + 9 { return false }
        return true
    }

    /// Cleans a name read from the gutter, rejecting anything that is clearly not one.
    func cleanPlayerName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let normalized = TextNormalizer.normalizeLabel(trimmed)
        guard RowLabelLexicon.match(token: normalized) == nil else { return nil }
        let letters = trimmed.filter { $0.isLetter }.count
        guard letters >= 2 else { return nil }
        return trimmed
    }
}
