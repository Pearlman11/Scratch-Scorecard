import SwiftUI
import SwiftData
import MapKit
import ScorecardKit

/// The Georgia course map: a scratch-off travel map for golf.
struct GeorgiaMapView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Course.name) private var courses: [Course]

    @State private var selectedCourse: Course?
    @State private var resolver = CourseLocationResolver()
    @State private var isResolving = false
    @State private var cameraPosition: MapCameraPosition = .region(Self.georgiaRegion)

    /// Centred on Georgia and spanning the whole state: the catalog is Georgia-only, so opening anywhere
    /// else would just make the golfer pan back.
    private static let georgiaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 32.90, longitude: -83.40),
        span: MKCoordinateSpan(latitudeDelta: 5.0, longitudeDelta: 5.0)
    )

    private var mappableCourses: [Course] {
        courses.filter(\.hasCoordinates)
    }

    private var playedCount: Int {
        courses.filter(\.isPlayed).count
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(position: $cameraPosition) {
                    ForEach(mappableCourses) { course in
                        Annotation(
                            course.displayName,
                            coordinate: CLLocationCoordinate2D(
                                latitude: course.latitude ?? 0,
                                longitude: course.longitude ?? 0
                            ),
                            anchor: .bottom
                        ) {
                            CourseMarker(course: course) { selectedCourse = course }
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .ignoresSafeArea(edges: .bottom)

                progressBanner
            }
            .navigationTitle("Georgia")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedCourse) { course in
                CourseDetailSheet(course: course)
            }
            .task { await resolveMissingCoordinates() }
        }
    }

    private var progressBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(Theme.accent)
            Text("\(playedCount) of \(courses.count) courses played")
                .font(.subheadline.weight(.medium))
            if isResolving {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, Theme.cardPadding)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    /// Fills in any coordinates not yet resolved, then persists them.
    private func resolveMissingCoordinates() async {
        let pending = courses.filter { !$0.hasCoordinates }
        guard !pending.isEmpty else { return }
        isResolving = true
        defer { isResolving = false }

        let requests = pending.map { (catalogID: $0.catalogID, name: $0.name, city: $0.city) }
        let resolutions = await resolver.resolveAll(requests)

        let repository = CourseRepository(context: modelContext)
        for resolution in resolutions {
            guard let course = courses.first(where: { $0.catalogID == resolution.catalogID }) else { continue }
            try? repository.updateCoordinates(
                for: course,
                latitude: resolution.latitude,
                longitude: resolution.longitude
            )
        }
    }
}

/// A map pin whose appearance says whether the course has been played.
///
/// Played and unplayed differ in shape and fill, not only colour, so the state is legible to anyone whose
/// colour vision would not separate a green pin from a grey one.
private struct CourseMarker: View {
    let course: Course
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(course.isPlayed ? Theme.accent : Color(.systemGray3))
                    .frame(width: 30, height: 30)
                    .shadow(radius: 2, y: 1)
                Image(systemName: course.isPlayed ? "flag.fill" : "questionmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .topTrailing) {
                if course.rounds.count > 1 {
                    Text("\(course.rounds.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.7)))
                        .offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(course.displayName)
        .accessibilityValue(
            course.isPlayed
                ? "played, \(course.rounds.count) round\(course.rounds.count == 1 ? "" : "s") saved"
                : "not played yet"
        )
    }
}
