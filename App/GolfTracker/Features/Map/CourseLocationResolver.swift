import Foundation
import MapKit
import ScorecardKit

/// Resolves a seeded course's coordinates at runtime and caches them.
///
/// Coordinates are not shipped in the catalog because writing them from memory is exactly the kind of
/// fabricated data this app refuses elsewhere. `MKLocalSearch` knows where these courses are; the app asks
/// once per course, checks the answer lands inside Georgia, and stores it.
actor CourseLocationResolver {

    /// Courses already attempted this session, so a course that cannot be found is not retried on every
    /// appearance of the map.
    private var attempted = Set<String>()

    struct Resolution {
        let catalogID: String
        let latitude: Double
        let longitude: Double
    }

    /// Looks up one course. Returns `nil` when nothing credible was found.
    func resolve(catalogID: String, name: String, city: String) async -> Resolution? {
        guard !attempted.contains(catalogID) else { return nil }
        attempted.insert(catalogID)

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(name), \(city), Georgia"
        request.resultTypes = [.pointOfInterest, .address]
        // Bias the search to Georgia so a same-named course elsewhere does not win on relevance alone.
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 32.65, longitude: -83.25),
            span: MKCoordinateSpan(latitudeDelta: 5.2, longitudeDelta: 5.4)
        )

        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }

        for item in response.mapItems {
            let coordinate = item.placemark.coordinate
            guard GeorgiaCourseCatalog.isWithinGeorgia(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ) else { continue }
            // A result whose name bears no resemblance to the course is the wrong place, however close it
            // is — Apple will happily return the nearest town when it cannot find the course itself.
            if let resultName = item.name,
               FuzzyText.similarity(resultName, name) < 0.5,
               FuzzyText.similarity(resultName, city) < 0.9 {
                continue
            }
            return Resolution(
                catalogID: catalogID,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
        return nil
    }

    /// Resolves several courses, one at a time.
    ///
    /// Serial rather than concurrent on purpose: `MKLocalSearch` throttles aggressively, and firing fifteen
    /// requests at once reliably gets most of them rejected.
    func resolveAll(_ courses: [(catalogID: String, name: String, city: String)]) async -> [Resolution] {
        var results: [Resolution] = []
        for course in courses {
            if let resolution = await resolve(catalogID: course.catalogID, name: course.name, city: course.city) {
                results.append(resolution)
            }
        }
        return results
    }
}
