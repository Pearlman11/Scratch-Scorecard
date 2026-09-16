import Foundation

/// Reconstructs a scorecard's table from OCR observations.
///
/// The detector deliberately knows nothing about golf courses — no template, no catalog. It answers only
/// "what grid is on this card, and what is each row?". Keeping identification out of layout means the
/// layout can be tested against a card the app has never seen, and means a template can never influence
/// which row we think the golfer's scores are in.
public protocol ScorecardLayoutDetecting: Sendable {
    func detectTable(from observations: [TextObservation]) -> DetectedTable
}

public struct ScorecardLayoutDetector: ScorecardLayoutDetecting {

    public var clusterer: RowClusterer
    public var gridBuilder: ColumnGridBuilder
    public var classifier: RowLabelClassifier

    public init(
        clusterer: RowClusterer = RowClusterer(),
        gridBuilder: ColumnGridBuilder = ColumnGridBuilder(),
        classifier: RowLabelClassifier = RowLabelClassifier()
    ) {
        self.clusterer = clusterer
        self.gridBuilder = gridBuilder
        self.classifier = classifier
    }

    public func detectTable(from observations: [TextObservation]) -> DetectedTable {
        let clustered = clusterer.clusterRows(from: observations)
        var rows = clustered.rows
        guard !rows.isEmpty else {
            return DetectedTable(rows: [], sections: [], skewRadians: clustered.skewRadians, medianTextHeight: clustered.medianTextHeight, skewPivotX: clustered.skewPivotX, skewPivotY: clustered.skewPivotY)
        }

        var sections = buildSections(rows: rows)
        guard !sections.isEmpty else {
            return DetectedTable(rows: rows, sections: [], skewRadians: clustered.skewRadians, medianTextHeight: clustered.medianTextHeight, skewPivotX: clustered.skewPivotX, skewPivotY: clustered.skewPivotY)
        }

        // Refine each section's columns against the cells beneath its header, then classify its rows.
        for sectionIndex in sections.indices {
            sections[sectionIndex].holeColumns = gridBuilder.refineColumns(
                sections[sectionIndex].holeColumns,
                using: rows,
                rowIndices: sections[sectionIndex].rowIndices,
                aggregateColumns: sections[sectionIndex].aggregateColumns
            )
        }

        for sectionIndex in sections.indices {
            let section = sections[sectionIndex]
            for rowIndex in section.rowIndices {
                guard rows.indices.contains(rowIndex) else { continue }
                rows[rowIndex].sectionIndex = sectionIndex
                if rowIndex == section.headerRowIndex {
                    rows[rowIndex].role = .holeHeader
                    rows[rowIndex].roleConfidence = 0.95
                    rows[rowIndex].labelObservations = TableCellReader.labelObservations(in: rows[rowIndex], section: section)
                    continue
                }
                let labels = TableCellReader.labelObservations(in: rows[rowIndex], section: section)
                rows[rowIndex].labelObservations = labels

                let cells = TableCellReader.holeCells(in: rows[rowIndex], section: section)
                // Read once with a wide range so the signature sees yardages and scores alike.
                let values = TableCellReader.integerValues(of: cells, in: 1...999)
                let classification = classifier.classify(
                    labelTokens: labels.map(\.trimmed),
                    holeValues: values,
                    meanOCRConfidence: rows[rowIndex].meanConfidence,
                    heightUniformity: rows[rowIndex].heightUniformity
                )
                rows[rowIndex].role = classification.role
                rows[rowIndex].roleConfidence = classification.confidence
            }
        }

        resolveParVersusPlayerRows(rows: &rows, sections: sections)

        return DetectedTable(
            rows: rows,
            sections: sections,
            skewRadians: clustered.skewRadians,
            medianTextHeight: clustered.medianTextHeight,
            skewPivotX: clustered.skewPivotX,
            skewPivotY: clustered.skewPivotY
        )
    }

    // MARK: - Sections

    /// Splits the card into hole-number bands.
    ///
    /// Header rows are accepted greedily from longest run to shortest, skipping any that would duplicate
    /// hole numbers already covered. That handles both card shapes the parser must support: one wide header
    /// covering `1…18`, and two stacked headers covering `1…9` and `10…18`.
    func buildSections(rows: [DetectedRow]) -> [ScorecardSection] {
        let candidates = gridBuilder.findHeaderRows(in: rows)
        guard !candidates.isEmpty else { return [] }

        var claimedHoles = Set<Int>()
        var accepted: [(rowIndex: Int, columns: [HoleColumn])] = []

        for candidate in candidates {
            let columns = gridBuilder.makeColumns(from: candidate.hits)
            let holes = Set(columns.map(\.holeNumber))
            // Reject a header that mostly repeats holes an earlier, longer header already owns.
            let overlap = holes.intersection(claimedHoles).count
            guard Double(overlap) / Double(max(1, holes.count)) < 0.5 else { continue }
            claimedHoles.formUnion(holes)
            accepted.append((candidate.rowIndex, columns))
        }
        guard !accepted.isEmpty else { return [] }

        accepted.sort { $0.rowIndex < $1.rowIndex }

        // A section owns every row from its header down to the row above the next header.
        var sections: [ScorecardSection] = []
        for (position, entry) in accepted.enumerated() {
            let lowerBound = entry.rowIndex
            let upperBound = position + 1 < accepted.count ? accepted[position + 1].rowIndex : rows.count
            var rowIndices = Array(lowerBound..<upperBound)

            // The first section also absorbs anything above it (the course name, a logo caption), so those
            // observations remain reachable for course identification.
            if position == 0 && lowerBound > 0 {
                rowIndices = Array(0..<upperBound)
            }

            var section = ScorecardSection(
                index: sections.count,
                headerRowIndex: entry.rowIndex,
                holeColumns: entry.columns,
                aggregateColumns: [],
                rowIndices: rowIndices
            )
            section.aggregateColumns = gridBuilder.findAggregateColumns(
                rows: rows,
                rowIndices: rowIndices,
                holeColumns: entry.columns
            )
            sections.append(section)
        }
        return sections
    }

    // MARK: - Par / player disambiguation

    /// Resolves rows that could be either par or a golfer's scores.
    ///
    /// The evidence used, in order:
    ///
    /// - **Uniqueness.** A card has one par row and may have several player rows. If a confidently labelled
    ///   par row already exists, every ambiguous row is a player row.
    /// - **Position.** The par row is printed with the other static rows, directly under the hole header
    ///   and above the blank rows golfers write into.
    /// - **Print quality.** Typeset digits are uniform in height and read with high OCR confidence;
    ///   handwriting is neither.
    ///
    /// When the evidence does not clearly favour par, the row is left as a player row. That bias is
    /// deliberate: a player row is reviewed and corrected by the golfer, while a wrongly promoted par row
    /// would be treated as static data and silently hidden from editing.
    func resolveParVersusPlayerRows(rows: inout [DetectedRow], sections: [ScorecardSection]) {
        for section in sections {
            let indices = section.rowIndices.filter { rows.indices.contains($0) }
            let hasConfidentPar = indices.contains { rows[$0].role == .par && rows[$0].roleConfidence >= 0.65 }

            var ambiguous: [Int] = indices.filter { index in
                let row = rows[index]
                guard row.roleConfidence < 0.5 else { return false }
                if case .playerScores = row.role { return true }
                return row.role == .par
            }

            if hasConfidentPar {
                for index in ambiguous where rows[index].role == .par {
                    rows[index].role = .playerScores(name: nil)
                    rows[index].roleConfidence = 0.35
                }
                continue
            }
            guard !ambiguous.isEmpty else { continue }

            // Score each ambiguous row on how much it looks like printed static data.
            ambiguous.sort()
            var best: (index: Int, score: Double)?
            for (position, index) in ambiguous.enumerated() {
                let row = rows[index]
                let positionScore = 1.0 - Double(position) / Double(max(1, ambiguous.count))
                let printScore = row.heightUniformity * 0.5 + min(1.0, row.meanConfidence) * 0.5
                let total = positionScore * 0.45 + printScore * 0.55
                if best == nil || total > best!.score {
                    best = (index, total)
                }
            }

            for index in ambiguous {
                if let best, index == best.index, best.score >= 0.62 {
                    rows[index].role = .par
                    rows[index].roleConfidence = 0.45
                } else {
                    rows[index].role = .playerScores(name: nil)
                    rows[index].roleConfidence = 0.35
                }
            }
        }
    }
}
