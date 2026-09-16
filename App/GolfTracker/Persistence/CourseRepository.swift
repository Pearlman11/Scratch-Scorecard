import Foundation
import SwiftData
import ScorecardKit

/// Owns the course catalog in the database: seeding it, keeping learned templates, and marking courses
/// played.
@MainActor
final class CourseRepository {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Seeding

    /// Ensures every seeded Georgia course exists, without clobbering anything the golfer has changed.
    ///
    /// Runs on every launch so a catalog addition in a later build appears for existing users. Only fields
    /// the app owns are refreshed; resolved coordinates and learned templates are left alone, because those
    /// were earned at runtime and the seed has nothing better to offer.
    func seedCatalogIfNeeded() throws {
        let existing = try context.fetch(FetchDescriptor<Course>())
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.catalogID, $0) })

        for template in GeorgiaCourseCatalog.templates {
            if let course = byID[template.id] {
                course.name = template.identity.name
                course.layoutName = template.identity.layoutName
                course.facilityName = template.identity.facilityName
                course.city = template.identity.city
                course.state = template.identity.state
                // Never downgrade a hole count learned from a scan back to the seed's "unknown".
                if template.isHoleCountKnown { course.holeCount = template.holeCount }
            } else {
                let course = Course(
                    catalogID: template.id,
                    name: template.identity.name,
                    layoutName: template.identity.layoutName,
                    facilityName: template.identity.facilityName,
                    city: template.identity.city,
                    state: template.identity.state,
                    holeCount: template.holeCount
                )
                context.insert(course)
                byID[template.id] = course
            }
        }
        try context.save()
    }

    // MARK: - Fetching

    func allCourses() throws -> [Course] {
        try context.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\.name)]))
    }

    func course(withCatalogID id: String) throws -> Course? {
        var descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.catalogID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Every template the matcher should consider: the seed catalog, with any locally learned template
    /// substituted in for the course it improves.
    ///
    /// Learned templates replace rather than accompany their seed entry, so a course can never appear twice
    /// in the candidate list and split its own evidence.
    func templatesForMatching() throws -> [CourseTemplate] {
        let stored = try context.fetch(FetchDescriptor<StoredCourseTemplate>())
        var learned: [String: CourseTemplate] = [:]
        for record in stored {
            guard let template = try? record.decoded() else { continue }
            learned[template.id] = template
        }
        var result = GeorgiaCourseCatalog.templates.map { learned[$0.id] ?? $0 }
        // A learned template for a course that is no longer seeded still participates.
        let seededIDs = Set(GeorgiaCourseCatalog.templates.map(\.id))
        result.append(contentsOf: learned.values.filter { !seededIDs.contains($0.id) })
        return result
    }

    func template(forCatalogID id: String) throws -> CourseTemplate? {
        try templatesForMatching().first { $0.id == id }
    }

    // MARK: - Learned templates

    /// Saves a template built from a confirmed scan, replacing any earlier one for the same course.
    func saveLearnedTemplate(_ template: CourseTemplate) throws {
        let course = try self.course(withCatalogID: template.id)
        let id = template.id
        var descriptor = FetchDescriptor<StoredCourseTemplate>(predicate: #Predicate { $0.catalogID == id })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            try existing.update(with: template)
        } else {
            let record = try StoredCourseTemplate(template: template, course: course)
            context.insert(record)
            course?.storedTemplate = record
        }
        if let course, template.isHoleCountKnown {
            course.holeCount = template.holeCount
        }
        try context.save()
    }

    // MARK: - Played state

    /// Marks a course played without creating a round.
    ///
    /// Scratching the map is a statement about the golfer's history, not about a card they have. Recording
    /// it as a visit rather than an empty round keeps the rounds list honest.
    func markPlayedManually(_ course: Course) throws {
        guard course.manuallyMarkedPlayedAt == nil else { return }
        course.manuallyMarkedPlayedAt = Date()
        context.insert(CourseVisit(courseCatalogID: course.catalogID, source: .manualScratch))
        try context.save()
    }

    /// Undoes a manual scratch. A course with saved rounds stays played — the rounds are the evidence.
    func clearManualPlayedMark(_ course: Course) throws {
        course.manuallyMarkedPlayedAt = nil
        let id = course.catalogID
        let visits = try context.fetch(FetchDescriptor<CourseVisit>(
            predicate: #Predicate { $0.courseCatalogID == id && $0.sourceRaw == "manualScratch" }
        ))
        visits.forEach(context.delete)
        try context.save()
    }

    func recordVisitForSavedRound(_ course: Course) throws {
        context.insert(CourseVisit(courseCatalogID: course.catalogID, source: .savedRound))
        try context.save()
    }

    // MARK: - Coordinates

    func updateCoordinates(for course: Course, latitude: Double, longitude: Double) throws {
        // Reject anything outside Georgia: a geocode that lands on a same-named course in another state
        // would put a pin the golfer cannot explain on a map that is meant to be Georgia-only.
        guard GeorgiaCourseCatalog.isWithinGeorgia(latitude: latitude, longitude: longitude) else { return }
        course.latitude = latitude
        course.longitude = longitude
        try context.save()
    }
}
