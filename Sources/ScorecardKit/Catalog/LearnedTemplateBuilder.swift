import Foundation

/// Promotes a reviewed scan into a reusable `CourseTemplate`.
///
/// This is how the catalog grows without anyone inventing data. The seed catalog ships fifteen Georgia
/// courses with no hole-level data, because that data was not available to transcribe. After a golfer
/// scans one of those courses and confirms the card on the review screen, the printed values on that card
/// *are* authoritative — a golfer looking at the physical card is a better source than a guess — so they
/// are saved as a `.userConfirmed` template and improve every later scan of that course.
///
/// The safeguards that keep this from becoming a fabrication channel:
///
/// - Only static fields are promoted. Scores are never part of a template.
/// - A field is promoted only if it was read from the card or typed by the golfer; a value that came from
///   another template is not re-promoted, so an error cannot be laundered into a second source.
/// - A template is built only when the static data is complete enough to be useful, so a half-read card
///   cannot displace a better read later.
public enum LearnedTemplateBuilder {

    public enum BuildFailure: Error, LocalizedError, Sendable {
        case noCourseSelected
        case insufficientStaticData(missingPars: [Int])

        public var errorDescription: String? {
            switch self {
            case .noCourseSelected:
                return "Choose which course this card belongs to before saving it as a template."
            case .insufficientStaticData(let missing):
                return "Par is still missing for hole\(missing.count == 1 ? "" : "s") \(missing.map(String.init).joined(separator: ", "))."
            }
        }
    }

    /// Whether this parse could be saved as a template for `identity`.
    public static func canBuildTemplate(from scorecard: ParsedScorecard) -> Bool {
        guard scorecard.candidateCourse != nil, scorecard.holeCount > 0 else { return false }
        return scorecard.holes.allSatisfy { $0.par.hasValue && isPromotable($0.par) }
    }

    /// Builds a `.userConfirmed` template from a reviewed card.
    ///
    /// - Parameters:
    ///   - scorecard: the card as the golfer confirmed it.
    ///   - existing: the catalog entry being improved, when there is one. Its identity and version are
    ///     carried forward so the improved template replaces rather than duplicates it.
    public static func build(
        from scorecard: ParsedScorecard,
        improving existing: CourseTemplate?
    ) throws -> CourseTemplate {
        guard let identity = scorecard.candidateCourse ?? existing?.identity else {
            throw BuildFailure.noCourseSelected
        }
        let holeCount = scorecard.holeCount
        guard holeCount > 0 else { throw BuildFailure.insufficientStaticData(missingPars: []) }

        let missingPars = scorecard.holes
            .filter { !$0.par.hasValue || !isPromotable($0.par) }
            .map(\.holeNumber)
        guard missingPars.isEmpty else {
            throw BuildFailure.insufficientStaticData(missingPars: missingPars)
        }

        let pars: [Int?] = scorecard.holes.sorted { $0.holeNumber < $1.holeNumber }.map { $0.par.value }
        let handicaps: [Int?] = scorecard.holes
            .sorted { $0.holeNumber < $1.holeNumber }
            .map { isPromotable($0.handicapIndex) ? $0.handicapIndex.value : nil }

        // Only the tee that was actually on the card gets yardages. Other tees stay unknown rather than
        // being back-filled from a rating or a ratio.
        var teeSets = existing?.teeSets ?? []
        if let teeName = scorecard.candidateTee {
            let yardages: [Int?] = scorecard.holes
                .sorted { $0.holeNumber < $1.holeNumber }
                .map { isPromotable($0.yardage) ? $0.yardage.value : nil }
            if yardages.contains(where: { $0 != nil }) {
                let colorName = RowLabelLexicon.teeNames[TextNormalizer.normalizeLabel(teeName)] ?? nil
                let newTee = TeeSetTemplate(name: teeName, colorName: colorName, yardages: yardages)
                if let index = teeSets.firstIndex(where: { TextNormalizer.normalizeName($0.name) == TextNormalizer.normalizeName(teeName) }) {
                    teeSets[index] = mergeTee(existing: teeSets[index], incoming: newTee)
                } else {
                    teeSets.append(newTee)
                }
            }
        }

        let allTeesComplete = !teeSets.isEmpty && teeSets.allSatisfy(\.hasCompleteYardages)
        let handicapsComplete = !handicaps.contains(where: { $0 == nil })
        let verification: TemplateVerificationStatus = (allTeesComplete && handicapsComplete) ? .userConfirmed : .partial

        return CourseTemplate(
            identity: identity,
            holeCount: holeCount,
            pars: pars,
            handicapIndices: handicaps,
            teeSets: teeSets,
            verification: verification,
            source: "Confirmed by the golfer from a scanned scorecard on \(Self.dateFormatter.string(from: Date())).",
            templateVersion: (existing?.templateVersion ?? 0) + 1,
            latitude: existing?.latitude,
            longitude: existing?.longitude
        )
    }

    /// A field may be promoted when the golfer read it off this card, not when another template supplied it.
    ///
    /// `.solvedFromSubtotal` is excluded for a different reason than the rest: it is not untrustworthy, it
    /// is simply never course data. That provenance only ever attaches to a player's score, derived from
    /// their written OUT or IN total. A par or yardage carrying it would mean something had gone badly
    /// wrong upstream, and promoting it into a template would turn one card's arithmetic into a claim
    /// about the course itself.
    private static func isPromotable(_ field: ParsedField<Int>) -> Bool {
        switch field.provenance {
        case .ocr, .userEdited:
            return field.hasValue
        case .verifiedCourseTemplate, .inferredFromLayout, .multimodalFallback, .solvedFromSubtotal, .none:
            return false
        }
    }

    /// Keeps a known yardage over an unknown one, hole by hole.
    private static func mergeTee(existing: TeeSetTemplate, incoming: TeeSetTemplate) -> TeeSetTemplate {
        var merged = existing
        let count = max(existing.yardages.count, incoming.yardages.count)
        var yardages = [Int?](repeating: nil, count: count)
        for index in 0..<count {
            let existingValue = existing.yardages.indices.contains(index) ? existing.yardages[index] : nil
            let incomingValue = incoming.yardages.indices.contains(index) ? incoming.yardages[index] : nil
            yardages[index] = incomingValue ?? existingValue
        }
        merged.yardages = yardages
        merged.colorName = existing.colorName ?? incoming.colorName
        return merged
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
