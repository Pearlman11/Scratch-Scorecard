import Foundation

/// One cell of the reconstructed table.
public struct TableCell: Sendable {
    public var holeNumber: Int?
    public var aggregateKind: AggregateColumn.Kind?
    public var observations: [TextObservation]
    /// Union of the observations' boxes, or the column/row intersection when the cell is empty.
    public var rect: CardRect

    public init(
        holeNumber: Int? = nil,
        aggregateKind: AggregateColumn.Kind? = nil,
        observations: [TextObservation] = [],
        rect: CardRect
    ) {
        self.holeNumber = holeNumber
        self.aggregateKind = aggregateKind
        self.observations = observations
        self.rect = rect
    }

    public var isEmpty: Bool { observations.isEmpty }

    /// Observation text joined left-to-right. Vision sometimes splits `1 7 1` into separate observations
    /// inside one cell, and joining them recovers `171`.
    public var text: String {
        observations
            .sorted { $0.rect.minX < $1.rect.minX }
            .map(\.trimmed)
            .joined()
    }

    public var ocrConfidence: Double {
        guard !observations.isEmpty else { return 0 }
        return observations.map(\.confidence).reduce(0, +) / Double(observations.count)
    }

    /// Alternative readings, used when the top candidate conflicts with strong structural evidence.
    public var alternativeTexts: [String] {
        guard observations.count == 1 else { return [] }
        return observations[0].alternativeTexts
    }
}

/// Slices rows into cells using a section's column geometry.
public enum TableCellReader {

    /// Reads every hole cell in `row`.
    ///
    /// Empty cells are returned too, and that is deliberate: a blank score cell is a *fact* about an
    /// unfinished hole, and dropping it would make an incomplete round indistinguishable from a failed read.
    public static func holeCells(in row: DetectedRow, section: ScorecardSection) -> [TableCell] {
        var byHole: [Int: [TextObservation]] = [:]
        for observation in row.observations {
            let x = observation.rect.midX
            // Aggregate columns can overlap the outermost hole column's padding; they win.
            if section.aggregateColumns.contains(where: { $0.contains(x) }) { continue }
            guard let column = section.holeColumns.first(where: { $0.contains(x) }) else { continue }
            byHole[column.holeNumber, default: []].append(observation)
        }

        return section.holeColumns.map { column in
            let observations = (byHole[column.holeNumber] ?? []).sorted { $0.rect.minX < $1.rect.minX }
            let rect: CardRect
            if let first = observations.first {
                rect = observations.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            } else {
                rect = CardRect(
                    x: column.minX,
                    y: row.rect.minY,
                    width: column.maxX - column.minX,
                    height: row.rect.height
                )
            }
            return TableCell(holeNumber: column.holeNumber, observations: observations, rect: rect)
        }
    }

    public static func aggregateCells(in row: DetectedRow, section: ScorecardSection) -> [TableCell] {
        section.aggregateColumns.map { column in
            let observations = row.observations
                .filter { column.contains($0.rect.midX) }
                .sorted { $0.rect.minX < $1.rect.minX }
            let rect: CardRect
            if let first = observations.first {
                rect = observations.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            } else {
                rect = CardRect(
                    x: column.minX,
                    y: row.rect.minY,
                    width: column.maxX - column.minX,
                    height: row.rect.height
                )
            }
            return TableCell(aggregateKind: column.kind, observations: observations, rect: rect)
        }
    }

    /// Observations to the left of the grid: the row's label gutter.
    public static func labelObservations(in row: DetectedRow, section: ScorecardSection) -> [TextObservation] {
        let gridMinX = section.gridMinX
        return row.observations.filter { $0.rect.maxX <= gridMinX + ($0.rect.width * 0.25) }
    }

    /// Best integer reading of each non-empty hole cell, constrained to `range`.
    ///
    /// Cells that cannot be read in range are dropped rather than coerced, so a signature is computed from
    /// what was actually legible.
    public static func integerValues(
        of cells: [TableCell],
        in range: ClosedRange<Int>
    ) -> [Int] {
        cells.compactMap { cell in
            guard !cell.isEmpty else { return nil }
            guard let reading = NumericOCR.bestInteger(from: cell.text, plausibleRange: range),
                  reading.penalty < 1.0 else { return nil }
            return reading.value
        }
    }
}
