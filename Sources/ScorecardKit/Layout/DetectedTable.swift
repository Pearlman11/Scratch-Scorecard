import Foundation

/// A column that holds one hole's cells.
public struct HoleColumn: Hashable, Codable, Sendable {
    public var holeNumber: Int
    /// Horizontal extent used to decide which cells belong to this hole.
    public var minX: Double
    public var maxX: Double
    public var centerX: Double
    /// `true` when the column's position was interpolated between neighbours because the hole number
    /// itself was never recognized. Cells in such a column start with reduced confidence.
    public var isInterpolated: Bool

    public init(holeNumber: Int, minX: Double, maxX: Double, centerX: Double, isInterpolated: Bool = false) {
        self.holeNumber = holeNumber
        self.minX = minX
        self.maxX = maxX
        self.centerX = centerX
        self.isInterpolated = isInterpolated
    }

    public func contains(_ x: Double) -> Bool { x >= minX && x < maxX }
}

/// A summary column: `OUT`, `IN` or `TOTAL`.
public struct AggregateColumn: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case out
        case inward
        case total
    }
    public var kind: Kind
    public var minX: Double
    public var maxX: Double
    public var centerX: Double

    public init(kind: Kind, minX: Double, maxX: Double, centerX: Double) {
        self.kind = kind
        self.minX = minX
        self.maxX = maxX
        self.centerX = centerX
    }

    public func contains(_ x: Double) -> Bool { x >= minX && x < maxX }
}

/// One clustered line of text.
public struct DetectedRow: Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    /// Observations left-to-right, in deskewed coordinates.
    public var observations: [TextObservation]
    public var rect: CardRect
    /// Observations left of the hole grid: the row's label gutter.
    public var labelObservations: [TextObservation]
    public var role: ScorecardRowRole
    /// `0...1` confidence in `role`.
    public var roleConfidence: Double
    /// Which section (hole-number band) this row belongs to.
    public var sectionIndex: Int?

    public init(
        index: Int,
        observations: [TextObservation],
        rect: CardRect,
        labelObservations: [TextObservation] = [],
        role: ScorecardRowRole = .unknown,
        roleConfidence: Double = 0,
        sectionIndex: Int? = nil
    ) {
        self.index = index
        self.observations = observations
        self.rect = rect
        self.labelObservations = labelObservations
        self.role = role
        self.roleConfidence = roleConfidence
        self.sectionIndex = sectionIndex
    }

    public var centerY: Double { rect.midY }

    public var labelText: String {
        labelObservations.map(\.trimmed).joined(separator: " ")
    }

    /// Mean OCR confidence across the row. Printed rows score noticeably higher than handwritten ones,
    /// which is one of the signals used to keep par rows and player rows apart.
    public var meanConfidence: Double {
        guard !observations.isEmpty else { return 0 }
        return observations.map(\.confidence).reduce(0, +) / Double(observations.count)
    }

    /// `0...1`, where 1 means every token in the row has the same glyph height.
    /// Typeset rows are near-uniform; handwriting is not.
    public var heightUniformity: Double {
        let heights = observations.map(\.rect.height).filter { $0 > 0 }
        guard heights.count > 1 else { return 1 }
        let mean = heights.reduce(0, +) / Double(heights.count)
        guard mean > 0 else { return 1 }
        let variance = heights.map { pow($0 - mean, 2) }.reduce(0, +) / Double(heights.count)
        let coefficientOfVariation = variance.squareRoot() / mean
        return max(0, 1 - min(1, coefficientOfVariation * 2.5))
    }
}

/// A band of rows sharing one hole-number header.
///
/// A card that prints `1...9 OUT 10...18 IN TOT` on one line yields a single section with eighteen hole
/// columns. A card that stacks the front nine above the back nine yields two sections, and the parser
/// stitches them together. Supporting both is why the hole axis is modelled per-section rather than once
/// for the whole card.
public struct ScorecardSection: Sendable {
    public var index: Int
    public var headerRowIndex: Int?
    public var holeColumns: [HoleColumn]
    public var aggregateColumns: [AggregateColumn]
    public var rowIndices: [Int]

    public init(
        index: Int,
        headerRowIndex: Int?,
        holeColumns: [HoleColumn],
        aggregateColumns: [AggregateColumn] = [],
        rowIndices: [Int] = []
    ) {
        self.index = index
        self.headerRowIndex = headerRowIndex
        self.holeColumns = holeColumns
        self.aggregateColumns = aggregateColumns
        self.rowIndices = rowIndices
    }

    public var holeNumbers: [Int] { holeColumns.map(\.holeNumber).sorted() }

    public func column(forHole holeNumber: Int) -> HoleColumn? {
        holeColumns.first { $0.holeNumber == holeNumber }
    }

    public func aggregateColumn(_ kind: AggregateColumn.Kind) -> AggregateColumn? {
        aggregateColumns.first { $0.kind == kind }
    }

    /// Left edge of the grid. Everything to the left of this is label gutter.
    public var gridMinX: Double {
        holeColumns.map(\.minX).min() ?? 0
    }
}

/// The reconstructed scorecard table.
public struct DetectedTable: Sendable {
    public var rows: [DetectedRow]
    public var sections: [ScorecardSection]
    /// Estimated page skew in radians, already applied to every rect in `rows`.
    public var skewRadians: Double
    public var medianTextHeight: Double

    public init(
        rows: [DetectedRow],
        sections: [ScorecardSection],
        skewRadians: Double,
        medianTextHeight: Double
    ) {
        self.rows = rows
        self.sections = sections
        self.skewRadians = skewRadians
        self.medianTextHeight = medianTextHeight
    }

    /// Every hole number covered by any section, ascending and de-duplicated.
    public var allHoleNumbers: [Int] {
        Array(Set(sections.flatMap(\.holeNumbers))).sorted()
    }

    public var detectedHoleCount: Int { allHoleNumbers.count }

    public func rows(withRole predicate: (ScorecardRowRole) -> Bool) -> [DetectedRow] {
        rows.filter { predicate($0.role) }
    }

    public var playerRows: [DetectedRow] {
        rows.filter(\.role.isPlayerData)
    }

    /// Finds the section that owns `row`, falling back to the only section when unassigned.
    public func section(for row: DetectedRow) -> ScorecardSection? {
        if let index = row.sectionIndex, sections.indices.contains(index) {
            return sections[index]
        }
        return sections.count == 1 ? sections[0] : nil
    }
}
