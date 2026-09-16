import Foundation

/// Builds synthetic OCR output with realistic scorecard geometry.
///
/// Tests need cards, and running Vision over a stored JPEG in a unit test is slow, platform-bound and — the
/// real problem — not controllable: there is no way to ask a recognizer for "this card, but with hole 16's
/// yardage misread as `33B`". This builder produces observations with the same spatial structure a real
/// card produces, and lets a test dictate exactly which cells are damaged.
///
/// It also backs the debug screen's self-test, so the whole pipeline can be exercised on-device before a
/// camera is ever pointed at anything.
public enum ScorecardFixtureBuilder {

    /// How the card arranges its holes.
    public enum Layout: Sendable {
        /// `1…9 OUT 10…18 IN TOT` on one horizontal band. The most common 18-hole card.
        case singleBand
        /// Front nine in one table, back nine in a second table below it.
        case stackedNines
    }

    /// One row of the card.
    public struct Row: Sendable {
        public var label: String?
        /// Cell text keyed by hole number. A hole with no entry produces no observation, which is how a
        /// blank cell is represented.
        public var cellsByHole: [Int: String]
        public var out: String?
        public var inward: String?
        public var total: String?
        /// OCR confidence applied to every observation in the row.
        public var confidence: Double
        /// Glyph height relative to the row's nominal height. Handwriting varies; print does not.
        public var heightScale: Double
        /// Per-cell height jitter as a fraction, applied deterministically. Non-zero for handwriting.
        public var heightJitter: Double

        public init(
            label: String? = nil,
            cellsByHole: [Int: String] = [:],
            out: String? = nil,
            inward: String? = nil,
            total: String? = nil,
            confidence: Double = 0.95,
            heightScale: Double = 1.0,
            heightJitter: Double = 0
        ) {
            self.label = label
            self.cellsByHole = cellsByHole
            self.out = out
            self.inward = inward
            self.total = total
            self.confidence = confidence
            self.heightScale = heightScale
            self.heightJitter = heightJitter
        }

        /// A printed row of integers.
        public static func printed(label: String?, values: [Int?], startingHole: Int = 1, confidence: Double = 0.95) -> Row {
            var cells: [Int: String] = [:]
            for (offset, value) in values.enumerated() {
                guard let value else { continue }
                cells[startingHole + offset] = String(value)
            }
            return Row(label: label, cellsByHole: cells, confidence: confidence, heightScale: 1.0, heightJitter: 0)
        }

        /// A handwritten row: lower confidence and uneven glyph heights, like the real thing.
        public static func handwritten(label: String?, values: [Int?], startingHole: Int = 1, confidence: Double = 0.55) -> Row {
            var cells: [Int: String] = [:]
            for (offset, value) in values.enumerated() {
                guard let value else { continue }
                cells[startingHole + offset] = String(value)
            }
            return Row(label: label, cellsByHole: cells, confidence: confidence, heightScale: 1.15, heightJitter: 0.28)
        }
    }

    /// A whole card.
    public struct Card: Sendable {
        /// Lines printed above the grid: course name, city, a logo caption.
        public var titleLines: [String]
        public var holeNumbers: [Int]
        /// The hole header row's own text, keyed by hole. Defaults to the hole numbers themselves.
        public var headerCells: [Int: String]?
        public var headerLabel: String?
        public var rows: [Row]
        public var layout: Layout
        /// Page rotation in degrees, applied to every box. Cards are rarely photographed square.
        public var skewDegrees: Double

        public init(
            titleLines: [String] = [],
            holeNumbers: [Int],
            headerCells: [Int: String]? = nil,
            headerLabel: String? = "HOLE",
            rows: [Row] = [],
            layout: Layout = .singleBand,
            skewDegrees: Double = 0
        ) {
            self.titleLines = titleLines
            self.holeNumbers = holeNumbers
            self.headerCells = headerCells
            self.headerLabel = headerLabel
            self.rows = rows
            self.layout = layout
            self.skewDegrees = skewDegrees
        }
    }

    // MARK: - Geometry

    private static let gutterMinX = 0.020
    private static let gridMinX = 0.170
    private static let gridMaxX = 0.980
    private static let firstRowY = 0.140
    private static let rowPitch = 0.062
    private static let nominalTextHeight = 0.026

    /// Renders a card into OCR observations.
    public static func build(_ card: Card) -> [TextObservation] {
        var observations: [TextObservation] = []

        switch card.layout {
        case .singleBand:
            observations = buildBand(
                card: card,
                holes: card.holeNumbers,
                rows: card.rows,
                topY: firstRowY,
                includesTitle: true,
                includesOut: true,
                includesIn: card.holeNumbers.contains(18),
                includesTotal: true
            )

        case .stackedNines:
            let front = card.holeNumbers.filter { $0 <= 9 }
            let back = card.holeNumbers.filter { $0 > 9 }
            observations = buildBand(
                card: card,
                holes: front,
                rows: card.rows.map { restrict($0, to: front, keepOut: true, keepIn: false, keepTotal: false) },
                topY: firstRowY,
                includesTitle: true,
                includesOut: true,
                includesIn: false,
                includesTotal: false
            )
            guard !back.isEmpty else { break }
            let backTop = firstRowY + rowPitch * Double(card.rows.count + 2)
            observations += buildBand(
                card: card,
                holes: back,
                rows: card.rows.map { restrict($0, to: back, keepOut: false, keepIn: true, keepTotal: true) },
                topY: backTop,
                includesTitle: false,
                includesOut: false,
                includesIn: true,
                includesTotal: true
            )
        }

        guard card.skewDegrees != 0 else { return observations }
        let radians = card.skewDegrees * .pi / 180
        return observations.map { $0.rotated(by: radians, around: (x: 0.5, y: 0.5)) }
    }

    private static func restrict(_ row: Row, to holes: [Int], keepOut: Bool, keepIn: Bool, keepTotal: Bool) -> Row {
        var copy = row
        copy.cellsByHole = row.cellsByHole.filter { holes.contains($0.key) }
        copy.out = keepOut ? row.out : nil
        copy.inward = keepIn ? row.inward : nil
        copy.total = keepTotal ? row.total : nil
        return copy
    }

    private static func buildBand(
        card: Card,
        holes: [Int],
        rows: [Row],
        topY: Double,
        includesTitle: Bool,
        includesOut: Bool,
        includesIn: Bool,
        includesTotal: Bool
    ) -> [TextObservation] {
        guard !holes.isEmpty else { return [] }
        var observations: [TextObservation] = []

        // Column layout: hole columns, with OUT inserted after hole 9 and IN/TOT at the end, exactly as a
        // printed card orders them.
        var slots: [(kind: Slot, hole: Int?)] = []
        for hole in holes.sorted() {
            slots.append((.hole, hole))
            if hole == 9 && includesOut { slots.append((.out, nil)) }
        }
        if includesIn { slots.append((.inward, nil)) }
        if includesTotal { slots.append((.total, nil)) }

        let slotWidth = (gridMaxX - gridMinX) / Double(slots.count)

        func center(ofSlotAt index: Int) -> Double {
            gridMinX + slotWidth * (Double(index) + 0.5)
        }

        if includesTitle {
            for (index, line) in card.titleLines.enumerated() {
                let y = topY - rowPitch * Double(card.titleLines.count - index) - 0.012
                observations.append(TextObservation(
                    text: line,
                    rect: CardRect(
                        x: gridMinX,
                        y: max(0.001, y),
                        width: min(0.55, 0.022 * Double(line.count)),
                        height: nominalTextHeight * 1.4
                    ),
                    confidence: 0.88,
                    pass: .languageCorrected
                ))
            }
        }

        // Hole header row.
        if let headerLabel = card.headerLabel {
            observations.append(labelObservation(headerLabel, y: topY, confidence: 0.94))
        }
        for (index, slot) in slots.enumerated() {
            let text: String
            switch slot.kind {
            case .hole:
                guard let hole = slot.hole else { continue }
                if let override = card.headerCells?[hole] {
                    // An explicit empty string means the header cell was unreadable and produced nothing.
                    if override.isEmpty { continue }
                    text = override
                } else {
                    text = String(hole)
                }
            case .out: text = "OUT"
            case .inward: text = "IN"
            case .total: text = "TOT"
            }
            observations.append(cellObservation(
                text,
                centerX: center(ofSlotAt: index),
                centerY: topY,
                confidence: 0.94,
                heightScale: 1.0
            ))
        }

        // Data rows.
        for (rowIndex, row) in rows.enumerated() {
            let y = topY + rowPitch * Double(rowIndex + 1)
            if let label = row.label, !label.isEmpty {
                observations.append(labelObservation(label, y: y, confidence: row.confidence))
            }
            for (index, slot) in slots.enumerated() {
                let text: String?
                switch slot.kind {
                case .hole: text = slot.hole.flatMap { row.cellsByHole[$0] }
                case .out: text = row.out
                case .inward: text = row.inward
                case .total: text = row.total
                }
                guard let text, !text.isEmpty else { continue }
                // Deterministic jitter so a test that fails is reproducible.
                let jitter = row.heightJitter == 0
                    ? 0
                    : row.heightJitter * (Double((index * 37 + rowIndex * 11) % 7) / 6.0 - 0.5) * 2
                observations.append(cellObservation(
                    text,
                    centerX: center(ofSlotAt: index),
                    centerY: y,
                    confidence: row.confidence,
                    heightScale: row.heightScale * (1 + jitter)
                ))
            }
        }
        return observations
    }

    private enum Slot { case hole, out, inward, total }

    private static func labelObservation(_ text: String, y: Double, confidence: Double) -> TextObservation {
        let width = min(gridMinX - gutterMinX - 0.008, 0.017 * Double(max(2, text.count)))
        return TextObservation(
            text: text,
            rect: CardRect(
                x: gutterMinX,
                y: y - nominalTextHeight / 2,
                width: width,
                height: nominalTextHeight
            ),
            confidence: confidence,
            pass: .languageCorrected
        )
    }

    private static func cellObservation(
        _ text: String,
        centerX: Double,
        centerY: Double,
        confidence: Double,
        heightScale: Double
    ) -> TextObservation {
        let height = nominalTextHeight * heightScale
        let width = 0.011 * Double(max(1, text.count)) + 0.006
        return TextObservation(
            text: text,
            rect: CardRect(
                x: centerX - width / 2,
                y: centerY - height / 2,
                width: width,
                height: height
            ),
            confidence: confidence,
            pass: text.allSatisfy { $0.isNumber } ? .numeric : .languageCorrected
        )
    }

    // MARK: - Ready-made cards

    /// A clean, undamaged Steel Canyon card with one golfer's scores from the White tees.
    ///
    /// - Parameter scores: score per hole, index 0 == hole 1. `nil` leaves the cell blank.
    public static func steelCanyonCard(
        scores: [Int?],
        playerName: String? = "J. PEARLMAN",
        layout: Layout = .singleBand,
        skewDegrees: Double = 0
    ) -> Card {
        let template = SteelCanyonTemplate.template
        let black = SteelCanyonTemplate.blackYardages
        let white = SteelCanyonTemplate.whiteYardages
        let red = SteelCanyonTemplate.redYardages

        return Card(
            titleLines: ["STEEL CANYON GOLF CLUB", "SANDY SPRINGS, GEORGIA"],
            holeNumbers: Array(1...18),
            rows: [
                Row.printed(label: "BLACK", values: black.map { Optional($0) })
                    .withTotals(out: 2021, inward: 1821, total: 3842),
                Row.printed(label: "WHITE", values: white.map { Optional($0) })
                    .withTotals(out: 1811, inward: 1586, total: 3397),
                Row.printed(label: "RED", values: red.map { Optional($0) })
                    .withTotals(out: 1484, inward: 1350, total: 2834),
                Row.printed(label: "PAR", values: template.pars)
                    .withTotals(out: 31, inward: 30, total: 61),
                Row.printed(label: "HCP", values: template.handicapIndices),
                Row.handwritten(label: playerName, values: scores)
            ],
            layout: layout,
            skewDegrees: skewDegrees
        )
    }
}

public extension ScorecardFixtureBuilder.Row {
    /// Adds OUT / IN / TOTAL cells to a row.
    func withTotals(out: Int?, inward: Int?, total: Int?) -> Self {
        var copy = self
        copy.out = out.map(String.init)
        copy.inward = inward.map(String.init)
        copy.total = total.map(String.init)
        return copy
    }

    /// Replaces one hole's cell text, simulating a specific misread.
    func corruptingHole(_ holeNumber: Int, to text: String) -> Self {
        var copy = self
        copy.cellsByHole[holeNumber] = text
        return copy
    }

    /// Removes one hole's cell entirely, simulating a value OCR never saw.
    func droppingHole(_ holeNumber: Int) -> Self {
        var copy = self
        copy.cellsByHole.removeValue(forKey: holeNumber)
        return copy
    }
}
