import Foundation

/// Recovers the vertical structure of the card: which x-range belongs to which hole.
///
/// The hole-number header is the only row whose *content* is predictable across every scorecard ever
/// printed — some ascending run of `1, 2, 3, …`. That makes it the anchor for the whole grid, and it is why
/// this type hunts for an ascending run rather than trusting a `HOLE` label that may be missing, rotated,
/// or rendered as a logo.
public struct ColumnGridBuilder: Sendable {

    public struct Configuration: Sendable {
        /// Fewest holes an ascending run must contain before it is accepted as a header row.
        public var minimumHeaderRun: Int
        /// How far past a column's own extent a cell may sit and still be assigned to it, as a multiple of
        /// the mean column pitch.
        public var columnPaddingFactor: Double

        public init(minimumHeaderRun: Int = 6, columnPaddingFactor: Double = 0.5) {
            self.minimumHeaderRun = minimumHeaderRun
            self.columnPaddingFactor = columnPaddingFactor
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// A hole number found in a header row, with the observation that produced it.
    struct HeaderHit {
        var holeNumber: Int
        var centerX: Double
        var minX: Double
        var maxX: Double
        var wasExactRead: Bool
    }

    // MARK: - Header detection

    /// Scans a row for an ascending run of hole numbers.
    ///
    /// Tolerates two things real cards do: interleaved non-numeric cells (`… 9  OUT  10 …`) and a single
    /// missing or unreadable hole number, which is absorbed as a gap rather than ending the run.
    func headerHits(in row: DetectedRow, startingAt start: Int) -> [HeaderHit] {
        var hits: [HeaderHit] = []
        var expected = start
        let upperBound = start + 17

        for observation in row.observations {
            guard expected <= upperBound else { break }
            guard let reading = NumericOCR.bestInteger(from: observation.trimmed, plausibleRange: 1...18),
                  reading.penalty < 1.0 else { continue }
            let value = reading.value

            if value == expected {
                hits.append(HeaderHit(
                    holeNumber: value,
                    centerX: observation.rect.midX,
                    minX: observation.rect.minX,
                    maxX: observation.rect.maxX,
                    wasExactRead: reading.penalty == 0
                ))
                expected += 1
            } else if value == expected + 1 && !hits.isEmpty {
                // One hole number was dropped or misread. Keep the run alive; the missing column is
                // interpolated later and its cells start with reduced confidence.
                hits.append(HeaderHit(
                    holeNumber: value,
                    centerX: observation.rect.midX,
                    minX: observation.rect.minX,
                    maxX: observation.rect.maxX,
                    wasExactRead: reading.penalty == 0
                ))
                expected = value + 1
            }
            // Anything else (a repeated number, an out-of-sequence yardage) is simply skipped.
        }
        return hits
    }

    /// Row indices that look like hole-number headers, best first.
    ///
    /// Both `1` and `10` are tried as starting values so a card that stacks the back nine in its own table
    /// is recognized as such rather than being forced to start at hole 1.
    func findHeaderRows(in rows: [DetectedRow]) -> [(rowIndex: Int, hits: [HeaderHit])] {
        var candidates: [(rowIndex: Int, hits: [HeaderHit])] = []
        for row in rows {
            var best: [HeaderHit] = []
            for start in [1, 10] {
                let hits = headerHits(in: row, startingAt: start)
                if hits.count > best.count { best = hits }
            }
            guard best.count >= configuration.minimumHeaderRun else { continue }
            candidates.append((row.index, best))
        }
        // Prefer longer runs, then higher on the card.
        return candidates.sorted {
            if $0.hits.count != $1.hits.count { return $0.hits.count > $1.hits.count }
            return $0.rowIndex < $1.rowIndex
        }
    }

    // MARK: - Column construction

    /// Turns header hits into columns with explicit boundaries, interpolating any hole the header lost.
    func makeColumns(from hits: [HeaderHit]) -> [HoleColumn] {
        let sorted = hits.sorted { $0.centerX < $1.centerX }
        guard !sorted.isEmpty else { return [] }

        var centers: [(hole: Int, x: Double, interpolated: Bool)] = sorted.map {
            (hole: $0.holeNumber, x: $0.centerX, interpolated: false)
        }

        // Fill holes skipped by the header run by linear interpolation between the neighbours that were
        // actually read. A column we invented is flagged so its cells never inherit full confidence.
        var filled: [(hole: Int, x: Double, interpolated: Bool)] = []
        for (index, entry) in centers.enumerated() {
            filled.append(entry)
            guard index + 1 < centers.count else { continue }
            let next = centers[index + 1]
            let gap = next.hole - entry.hole
            guard gap > 1, gap <= 3 else { continue }
            let step = (next.x - entry.x) / Double(gap)
            for offset in 1..<gap {
                filled.append((hole: entry.hole + offset, x: entry.x + step * Double(offset), interpolated: true))
            }
        }
        centers = filled.sorted { $0.x < $1.x }

        let pitch = meanPitch(of: centers.map { $0.x }) ?? 0.05
        var columns: [HoleColumn] = []
        for (index, entry) in centers.enumerated() {
            let leftBoundary: Double
            if index == 0 {
                leftBoundary = entry.x - pitch * (0.5 + configuration.columnPaddingFactor * 0.2)
            } else {
                leftBoundary = (centers[index - 1].x + entry.x) / 2
            }
            let rightBoundary: Double
            if index == centers.count - 1 {
                rightBoundary = entry.x + pitch * (0.5 + configuration.columnPaddingFactor * 0.2)
            } else {
                rightBoundary = (entry.x + centers[index + 1].x) / 2
            }
            columns.append(HoleColumn(
                holeNumber: entry.hole,
                minX: leftBoundary,
                maxX: rightBoundary,
                centerX: entry.x,
                isInterpolated: entry.interpolated
            ))
        }
        return columns.sorted { $0.holeNumber < $1.holeNumber }
    }

    private func meanPitch(of centers: [Double]) -> Double? {
        guard centers.count >= 2 else { return nil }
        let sorted = centers.sorted()
        var gaps: [Double] = []
        for index in 1..<sorted.count {
            gaps.append(sorted[index] - sorted[index - 1])
        }
        gaps.sort()
        // Median gap: resistant to the wide OUT/IN cells that sit between hole columns.
        let middle = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[middle] : (gaps[middle - 1] + gaps[middle]) / 2
    }

    // MARK: - Aggregate columns

    /// Locates `OUT`, `IN` and `TOTAL` columns from their printed labels anywhere in the section.
    ///
    /// Labels are searched across all rows, not just the header, because many cards print `OUT` once in the
    /// par row and leave the header cell blank.
    func findAggregateColumns(
        rows: [DetectedRow],
        rowIndices: [Int],
        holeColumns: [HoleColumn]
    ) -> [AggregateColumn] {
        guard !holeColumns.isEmpty else { return [] }
        let gridMinX = holeColumns.map(\.minX).min() ?? 0
        var found: [AggregateColumn.Kind: [CardRect]] = [:]

        for index in rowIndices {
            guard rows.indices.contains(index) else { continue }
            for observation in rows[index].observations {
                // Aggregate labels live inside or to the right of the grid, never in the label gutter.
                guard observation.rect.midX >= gridMinX else { continue }
                let token = observation.normalizedLabel
                let kind: AggregateColumn.Kind?
                if RowLabelLexicon.outSynonyms.contains(token) {
                    kind = .out
                } else if RowLabelLexicon.inSynonyms.contains(token) {
                    kind = .inward
                } else if RowLabelLexicon.totalSynonyms.contains(token) {
                    kind = .total
                } else {
                    kind = nil
                }
                guard let kind else { continue }
                found[kind, default: []].append(observation.rect)
            }
        }

        let pitch = meanPitch(of: holeColumns.map(\.centerX)) ?? 0.05
        var columns: [AggregateColumn] = []
        for (kind, rects) in found {
            // Several rows label the same column; take the median centre so one stray label cannot move it.
            let centers = rects.map(\.midX).sorted()
            let center = centers[centers.count / 2]
            let halfWidth = max(pitch * 0.6, rects.map(\.width).max() ?? pitch * 0.6)
            columns.append(AggregateColumn(
                kind: kind,
                minX: center - halfWidth / 2,
                maxX: center + halfWidth / 2,
                centerX: center
            ))
        }
        return columns.sorted { $0.centerX < $1.centerX }
    }

    // MARK: - Refinement

    /// Re-centres columns using the cells beneath the header.
    ///
    /// Header digits are narrow and often right-aligned while the data cells below are centred, so the
    /// header alone can bias every boundary by a fraction of a column. Re-deriving centres from the median
    /// of the cells actually assigned to each column removes that bias, which matters most at the card's
    /// edges where errors accumulate.
    func refineColumns(
        _ columns: [HoleColumn],
        using rows: [DetectedRow],
        rowIndices: [Int],
        aggregateColumns: [AggregateColumn]
    ) -> [HoleColumn] {
        guard columns.count >= 2 else { return columns }
        var samples: [Int: [Double]] = [:]

        for index in rowIndices {
            guard rows.indices.contains(index) else { continue }
            let row = rows[index]
            for observation in row.observations {
                guard observation.looksNumeric else { continue }
                let x = observation.rect.midX
                if aggregateColumns.contains(where: { $0.contains(x) }) { continue }
                guard let nearest = columns.min(by: { abs($0.centerX - x) < abs($1.centerX - x) }) else { continue }
                // Only accept a sample that already lands inside the column's boundaries; otherwise a
                // misplaced token could drag the column toward itself and make the drift worse.
                guard nearest.contains(x) else { continue }
                samples[nearest.holeNumber, default: []].append(x)
            }
        }

        var refined: [HoleColumn] = []
        for column in columns {
            guard let values = samples[column.holeNumber], values.count >= 2 else {
                refined.append(column)
                continue
            }
            let sorted = values.sorted()
            let median = sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            var updated = column
            // Move at most a third of the way, so a couple of samples cannot overpower the header anchor.
            updated.centerX = column.centerX + (median - column.centerX) * 0.34
            refined.append(updated)
        }

        // Rebuild boundaries from the refined centres.
        let ordered = refined.sorted { $0.centerX < $1.centerX }
        let pitch = meanPitch(of: ordered.map(\.centerX)) ?? 0.05
        var result: [HoleColumn] = []
        for (index, column) in ordered.enumerated() {
            var updated = column
            updated.minX = index == 0 ? column.centerX - pitch * 0.6 : (ordered[index - 1].centerX + column.centerX) / 2
            updated.maxX = index == ordered.count - 1
                ? column.centerX + pitch * 0.6
                : (column.centerX + ordered[index + 1].centerX) / 2
            result.append(updated)
        }
        return result.sorted { $0.holeNumber < $1.holeNumber }
    }
}
