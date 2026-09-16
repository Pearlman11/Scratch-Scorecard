import Foundation

/// The printed course data recovered from a card, before any template is consulted.
public struct ExtractedStaticData: Sendable {
    /// Hole numbers the grid covered, ascending.
    public var holeNumbers: [Int]
    /// Par per hole, index 0 == hole 1, sized to `max(holeNumbers)`.
    public var pars: [Int?]
    /// OCR confidence for each par reading, same indexing.
    public var parConfidences: [Double?]
    public var parRawText: [String?]
    /// Stroke index per hole.
    public var handicapIndices: [Int?]
    public var handicapConfidences: [Double?]
    public var handicapRawText: [String?]
    /// One entry per tee row found on the card.
    public var yardageRows: [ObservedYardageRow]
    /// Per-hole OCR confidence for each yardage row, parallel to `yardageRows`.
    public var yardageConfidences: [[Double?]]
    public var yardageRawText: [[String?]]
    /// Totals read from the OUT / IN / TOTAL columns of the par row.
    public var outPar: Int?
    public var inPar: Int?
    public var totalPar: Int?
    /// Text found outside the grid: course name, logo caption, address line.
    public var nameFragments: [String]

    public var holeCount: Int { holeNumbers.max() ?? 0 }
}

/// Pulls the printed, static half of a scorecard out of the reconstructed table.
///
/// "Static" means everything the course printed before the golfer arrived: hole numbers, par, stroke index
/// and yardages. This extractor never touches a player row, and nothing it returns may ever become a score.
/// Keeping the two extractions in separate types is the structural reason that mistake cannot happen by
/// accident.
public struct StaticCourseDataExtractor: Sendable {

    public init() {}

    public func extract(from table: DetectedTable) -> ExtractedStaticData {
        let holeNumbers = table.allHoleNumbers
        let holeCount = holeNumbers.max() ?? 0

        var pars = [Int?](repeating: nil, count: holeCount)
        var parConfidences = [Double?](repeating: nil, count: holeCount)
        var parRaw = [String?](repeating: nil, count: holeCount)
        var handicaps = [Int?](repeating: nil, count: holeCount)
        var handicapConfidences = [Double?](repeating: nil, count: holeCount)
        var handicapRaw = [String?](repeating: nil, count: holeCount)

        var outPar: Int?
        var inPar: Int?
        var totalPar: Int?

        // Yardage rows are keyed so that a tee split across two stacked sections (front nine above, back
        // nine below) is rejoined into one row rather than appearing as two half-empty tees.
        var yardageByKey: [String: (teeName: String?, values: [Int?], confidences: [Double?], raw: [String?], order: Int)] = [:]
        var yardageOrder = 0

        for section in table.sections {
            var unnamedYardageIndex = 0
            for rowIndex in section.rowIndices {
                guard table.rows.indices.contains(rowIndex) else { continue }
                let row = table.rows[rowIndex]
                guard row.role.isStaticCourseData else { continue }

                let cells = TableCellReader.holeCells(in: row, section: section)

                switch row.role {
                case .par:
                    for cell in cells {
                        guard let hole = cell.holeNumber, hole >= 1, hole <= holeCount, !cell.isEmpty else { continue }
                        guard let reading = NumericOCR.bestInteger(from: cell.text, plausibleRange: ScoreMath.plausibleParRange),
                              reading.penalty < 1.0 else { continue }
                        // Two par rows (men's and ladies') can both be present; keep the first reading.
                        if pars[hole - 1] == nil {
                            pars[hole - 1] = reading.value
                            parConfidences[hole - 1] = cell.ocrConfidence * (1 - reading.penalty * 0.5)
                            parRaw[hole - 1] = cell.text
                        }
                    }
                    for cell in TableCellReader.aggregateCells(in: row, section: section) {
                        guard !cell.isEmpty,
                              let reading = NumericOCR.bestInteger(from: cell.text, plausibleRange: 20...120),
                              reading.penalty < 1.0 else { continue }
                        switch cell.aggregateKind {
                        case .out: outPar = outPar ?? reading.value
                        case .inward: inPar = inPar ?? reading.value
                        case .total: totalPar = totalPar ?? reading.value
                        case .none: break
                        }
                    }

                case .handicap:
                    for cell in cells {
                        guard let hole = cell.holeNumber, hole >= 1, hole <= holeCount, !cell.isEmpty else { continue }
                        guard let reading = NumericOCR.bestInteger(from: cell.text, plausibleRange: ScoreMath.plausibleHandicapRange),
                              reading.penalty < 1.0 else { continue }
                        if handicaps[hole - 1] == nil {
                            handicaps[hole - 1] = reading.value
                            handicapConfidences[hole - 1] = cell.ocrConfidence * (1 - reading.penalty * 0.5)
                            handicapRaw[hole - 1] = cell.text
                        }
                    }

                case .yardage(let teeName):
                    let key: String
                    if let teeName {
                        key = TextNormalizer.normalizeLabel(teeName)
                    } else {
                        key = "__unnamed_\(unnamedYardageIndex)"
                        unnamedYardageIndex += 1
                    }
                    var entry = yardageByKey[key] ?? (
                        teeName: teeName,
                        values: [Int?](repeating: nil, count: holeCount),
                        confidences: [Double?](repeating: nil, count: holeCount),
                        raw: [String?](repeating: nil, count: holeCount),
                        order: yardageOrder
                    )
                    if yardageByKey[key] == nil { yardageOrder += 1 }
                    if entry.teeName == nil { entry.teeName = teeName }

                    for cell in cells {
                        guard let hole = cell.holeNumber, hole >= 1, hole <= holeCount, !cell.isEmpty else { continue }
                        guard let reading = NumericOCR.bestInteger(from: cell.text, plausibleRange: ScoreMath.plausibleYardageRange),
                              reading.penalty < 1.0 else { continue }
                        if entry.values[hole - 1] == nil {
                            entry.values[hole - 1] = reading.value
                            entry.confidences[hole - 1] = cell.ocrConfidence * (1 - reading.penalty * 0.5)
                            entry.raw[hole - 1] = cell.text
                        }
                    }
                    yardageByKey[key] = entry

                case .holeHeader, .playerScores, .metadata, .unknown:
                    continue
                }
            }
        }

        let orderedYardage = yardageByKey.values.sorted { $0.order < $1.order }

        return ExtractedStaticData(
            holeNumbers: holeNumbers,
            pars: pars,
            parConfidences: parConfidences,
            parRawText: parRaw,
            handicapIndices: handicaps,
            handicapConfidences: handicapConfidences,
            handicapRawText: handicapRaw,
            yardageRows: orderedYardage.map { ObservedYardageRow(teeName: $0.teeName, values: $0.values) },
            yardageConfidences: orderedYardage.map { $0.confidences },
            yardageRawText: orderedYardage.map { $0.raw },
            outPar: outPar,
            inPar: inPar,
            totalPar: totalPar,
            nameFragments: nameFragments(from: table)
        )
    }

    /// Text that is not part of the grid: the heading, a logo caption, an address line.
    ///
    /// Restricted to observations above the first hole header or left of the grid, because everything
    /// inside the grid is a number and would only add noise to name matching.
    func nameFragments(from table: DetectedTable) -> [String] {
        guard let firstSection = table.sections.first,
              let headerRowIndex = firstSection.headerRowIndex else {
            return table.rows.flatMap { $0.observations.map(\.trimmed) }.filter { isNameLike($0) }
        }
        var fragments: [String] = []
        var seen = Set<String>()
        func add(_ text: String) {
            guard isNameLike(text), seen.insert(text).inserted else { return }
            fragments.append(text)
        }
        for row in table.rows where row.index < headerRowIndex {
            row.observations.map(\.trimmed).forEach(add)
            // A heading split across observations on the same line is also offered as one string.
            add(row.observations.map(\.trimmed).joined(separator: " "))
        }
        return fragments
    }

    private func isNameLike(_ text: String) -> Bool {
        let normalized = TextNormalizer.normalizeName(text)
        guard normalized.count >= 3 else { return false }
        let letters = normalized.filter { $0.isLetter }.count
        return letters >= 3
    }
}
