import Foundation

/// Groups OCR observations into table rows, correcting for page skew first.
///
/// Photographs of a scorecard held in one hand are rarely square to the camera. Even one or two degrees of
/// rotation is enough to make hole 1's cell sit in a different y-band than hole 18's, which silently
/// splits a single row into two and destroys the table. Deskewing before clustering is therefore not a
/// polish step — it is what makes row clustering work at all.
public struct RowClusterer: Sendable {

    public struct Configuration: Sendable {
        /// Row band tolerance as a multiple of the median glyph height.
        public var rowToleranceFactor: Double
        /// Minimum vertical overlap that forces two observations into the same row regardless of centres.
        public var forcedOverlapRatio: Double
        /// Largest skew we will attempt to correct, in radians (about 12°).
        public var maxSkewRadians: Double
        /// Skew below this is ignored as noise (about 0.2°).
        public var minSkewRadians: Double
        /// Largest horizontal gap, in normalized units, that still counts as "the next cell to the right"
        /// when estimating skew.
        public var neighbourMaxGap: Double

        public init(
            rowToleranceFactor: Double = 0.62,
            forcedOverlapRatio: Double = 0.40,
            maxSkewRadians: Double = 0.21,
            minSkewRadians: Double = 0.0035,
            neighbourMaxGap: Double = 0.14
        ) {
            self.rowToleranceFactor = rowToleranceFactor
            self.forcedOverlapRatio = forcedOverlapRatio
            self.maxSkewRadians = maxSkewRadians
            self.minSkewRadians = minSkewRadians
            self.neighbourMaxGap = neighbourMaxGap
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public struct Result: Sendable {
        public var rows: [DetectedRow]
        public var skewRadians: Double
        public var medianTextHeight: Double
        /// Observations after deskew, in the same order as the input.
        public var deskewedObservations: [TextObservation]
        /// The point the deskew rotation was applied about. Needed to map a rect derived from the
        /// deskewed grid back onto the original photograph, which is what a targeted re-read of a single
        /// cell has to do before it can crop the image.
        public var skewPivotX: Double
        public var skewPivotY: Double
    }

    public func clusterRows(from observations: [TextObservation]) -> Result {
        guard !observations.isEmpty else {
            return Result(rows: [], skewRadians: 0, medianTextHeight: 0, deskewedObservations: [], skewPivotX: 0.5, skewPivotY: 0.5)
        }

        let skew = estimateSkew(observations)
        let pivot = centroid(of: observations)
        let deskewed: [TextObservation]
        if abs(skew) >= configuration.minSkewRadians {
            deskewed = observations.map { $0.rotated(by: -skew, around: pivot) }
        } else {
            deskewed = observations
        }

        let medianHeight = median(deskewed.map(\.rect.height)) ?? 0.02
        let rows = buildRows(from: deskewed, medianHeight: medianHeight)
        return Result(
            rows: rows,
            skewRadians: abs(skew) >= configuration.minSkewRadians ? skew : 0,
            medianTextHeight: medianHeight,
            deskewedObservations: deskewed,
            skewPivotX: pivot.x,
            skewPivotY: pivot.y
        )
    }

    // MARK: - Skew

    /// Median angle from each observation to its nearest right-hand neighbour on the same visual line.
    ///
    /// The median is used rather than a fit because a scorecard contains vertical labels, logos and stray
    /// marks whose pairings would drag a least-squares estimate off by several degrees.
    public func estimateSkew(_ observations: [TextObservation]) -> Double {
        guard observations.count >= 4 else { return 0 }
        let sorted = observations.sorted { $0.rect.minX < $1.rect.minX }
        var angles: [Double] = []
        angles.reserveCapacity(sorted.count)

        for (index, observation) in sorted.enumerated() {
            var best: TextObservation?
            var bestGap = Double.greatestFiniteMagnitude
            // Only look forward: `sorted` is by minX, so the neighbour is always later in the array.
            for candidate in sorted[(index + 1)...] {
                let gap = candidate.rect.minX - observation.rect.maxX
                if gap > configuration.neighbourMaxGap { break }
                guard gap > -observation.rect.width * 0.5 else { continue }
                guard observation.rect.verticalOverlapRatio(with: candidate.rect) > 0.35 else { continue }
                if gap < bestGap {
                    bestGap = gap
                    best = candidate
                }
            }
            guard let neighbour = best else { continue }
            let dx = neighbour.rect.midX - observation.rect.midX
            let dy = neighbour.rect.midY - observation.rect.midY
            guard dx > 1e-6 else { continue }
            let angle = atan2(dy, dx)
            guard abs(angle) <= configuration.maxSkewRadians else { continue }
            angles.append(angle)
        }

        guard angles.count >= 3, let value = median(angles) else { return 0 }
        return value
    }

    private func centroid(of observations: [TextObservation]) -> (x: Double, y: Double) {
        let count = Double(observations.count)
        let x = observations.map(\.rect.midX).reduce(0, +) / count
        let y = observations.map(\.rect.midY).reduce(0, +) / count
        return (x, y)
    }

    // MARK: - Rows

    private func buildRows(from observations: [TextObservation], medianHeight: Double) -> [DetectedRow] {
        let tolerance = max(medianHeight * configuration.rowToleranceFactor, 0.004)
        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > 1e-9 { return lhs.rect.midY < rhs.rect.midY }
            return lhs.rect.minX < rhs.rect.minX
        }

        var clusters: [[TextObservation]] = []
        var currentCluster: [TextObservation] = []
        var currentSum = 0.0
        var currentRect: CardRect?

        for observation in sorted {
            guard let rect = currentRect else {
                currentCluster = [observation]
                currentSum = observation.rect.midY
                currentRect = observation.rect
                continue
            }
            let mean = currentSum / Double(currentCluster.count)
            let withinTolerance = abs(observation.rect.midY - mean) <= tolerance
            let stronglyOverlapping = rect.verticalOverlapRatio(with: observation.rect) >= configuration.forcedOverlapRatio

            if withinTolerance || stronglyOverlapping {
                currentCluster.append(observation)
                currentSum += observation.rect.midY
                currentRect = rect.union(observation.rect)
            } else {
                clusters.append(currentCluster)
                currentCluster = [observation]
                currentSum = observation.rect.midY
                currentRect = observation.rect
            }
        }
        if !currentCluster.isEmpty { clusters.append(currentCluster) }

        return clusters.enumerated().map { index, cluster in
            let ordered = cluster.sorted { $0.rect.minX < $1.rect.minX }
            let rect = ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) }
            return DetectedRow(index: index, observations: ordered, rect: rect)
        }
    }

    // MARK: - Helpers

    func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
