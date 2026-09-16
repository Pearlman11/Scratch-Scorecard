import Foundation

/// Everything the parser saw and decided, captured for the developer inspector.
///
/// This exists to make improving accuracy on a real card tractable. When a scan of the Steel Canyon card
/// comes out wrong, the question is always *which stage* went wrong — did OCR miss the row, did the row
/// cluster into the wrong band, did the column boundaries drift, or did the matcher pick another course?
/// Guessing at that from a final result is hopeless; the report answers it directly.
public struct ParserDebugReport: Sendable {

    public struct RowSummary: Sendable, Identifiable {
        public var id: Int { index }
        public var index: Int
        public var rect: CardRect
        public var role: String
        public var roleConfidence: Double
        public var labelText: String
        public var meanOCRConfidence: Double
        public var heightUniformity: Double
        public var sectionIndex: Int?
        public var cellTexts: [String]

        public init(
            index: Int,
            rect: CardRect,
            role: String,
            roleConfidence: Double,
            labelText: String,
            meanOCRConfidence: Double,
            heightUniformity: Double,
            sectionIndex: Int?,
            cellTexts: [String]
        ) {
            self.index = index
            self.rect = rect
            self.role = role
            self.roleConfidence = roleConfidence
            self.labelText = labelText
            self.meanOCRConfidence = meanOCRConfidence
            self.heightUniformity = heightUniformity
            self.sectionIndex = sectionIndex
            self.cellTexts = cellTexts
        }
    }

    public struct ColumnSummary: Sendable, Identifiable {
        public var id: String { "\(sectionIndex)-\(label)" }
        public var sectionIndex: Int
        public var label: String
        public var minX: Double
        public var maxX: Double
        public var centerX: Double
        public var isInterpolated: Bool

        public init(sectionIndex: Int, label: String, minX: Double, maxX: Double, centerX: Double, isInterpolated: Bool) {
            self.sectionIndex = sectionIndex
            self.label = label
            self.minX = minX
            self.maxX = maxX
            self.centerX = centerX
            self.isInterpolated = isInterpolated
        }
    }

    public struct CourseCandidateSummary: Sendable, Identifiable {
        public var id: String { templateID }
        public var templateID: String
        public var displayName: String
        public var totalScore: Double
        public var nameScore: Double
        public var matchedFragment: String?
        public var parScore: Double
        public var parCompared: Int
        public var handicapScore: Double
        public var handicapCompared: Int
        public var bestTeeName: String?
        public var teeScore: Double
        public var teeCompared: Int
        public var holeCountMatches: Bool?
        public var evidenceWeight: Double

        public init(
            templateID: String,
            displayName: String,
            totalScore: Double,
            nameScore: Double,
            matchedFragment: String?,
            parScore: Double,
            parCompared: Int,
            handicapScore: Double,
            handicapCompared: Int,
            bestTeeName: String?,
            teeScore: Double,
            teeCompared: Int,
            holeCountMatches: Bool?,
            evidenceWeight: Double
        ) {
            self.templateID = templateID
            self.displayName = displayName
            self.totalScore = totalScore
            self.nameScore = nameScore
            self.matchedFragment = matchedFragment
            self.parScore = parScore
            self.parCompared = parCompared
            self.handicapScore = handicapScore
            self.handicapCompared = handicapCompared
            self.bestTeeName = bestTeeName
            self.teeScore = teeScore
            self.teeCompared = teeCompared
            self.holeCountMatches = holeCountMatches
            self.evidenceWeight = evidenceWeight
        }
    }

    /// Every observation fed to the parser, in original (pre-deskew) coordinates so boxes drawn on the
    /// photograph land where the text actually is.
    public var observations: [TextObservation]
    /// The same observations after deskew, which is the space the rows and columns live in.
    public var deskewedObservations: [TextObservation]
    public var skewDegrees: Double
    public var medianTextHeight: Double
    public var rows: [RowSummary]
    public var columns: [ColumnSummary]
    public var courseCandidates: [CourseCandidateSummary]
    public var playerRowIndices: [Int]
    public var nameFragments: [String]
    public var extractedPars: [Int?]
    public var extractedHandicaps: [Int?]
    public var extractedYardageRows: [ObservedYardageRow]
    public var appliedTemplateID: String?
    public var appliedTeeName: String?
    public var timings: [String: Double]

    public init(
        observations: [TextObservation] = [],
        deskewedObservations: [TextObservation] = [],
        skewDegrees: Double = 0,
        medianTextHeight: Double = 0,
        rows: [RowSummary] = [],
        columns: [ColumnSummary] = [],
        courseCandidates: [CourseCandidateSummary] = [],
        playerRowIndices: [Int] = [],
        nameFragments: [String] = [],
        extractedPars: [Int?] = [],
        extractedHandicaps: [Int?] = [],
        extractedYardageRows: [ObservedYardageRow] = [],
        appliedTemplateID: String? = nil,
        appliedTeeName: String? = nil,
        timings: [String: Double] = [:]
    ) {
        self.observations = observations
        self.deskewedObservations = deskewedObservations
        self.skewDegrees = skewDegrees
        self.medianTextHeight = medianTextHeight
        self.rows = rows
        self.columns = columns
        self.courseCandidates = courseCandidates
        self.playerRowIndices = playerRowIndices
        self.nameFragments = nameFragments
        self.extractedPars = extractedPars
        self.extractedHandicaps = extractedHandicaps
        self.extractedYardageRows = extractedYardageRows
        self.appliedTemplateID = appliedTemplateID
        self.appliedTeeName = appliedTeeName
        self.timings = timings
    }
}

/// Renders a role for the inspector.
public extension ScorecardRowRole {
    var debugDescription: String {
        switch self {
        case .holeHeader: return "HOLE HEADER"
        case .par: return "PAR"
        case .handicap: return "HCP"
        case .yardage(let tee): return "YARDS\(tee.map { " (\($0))" } ?? " (unnamed tee)")"
        case .playerScores(let name): return "PLAYER\(name.map { " (\($0))" } ?? "")"
        case .metadata: return "META"
        case .unknown: return "?"
        }
    }
}
