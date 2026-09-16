import SwiftUI
import SwiftData
import ScorecardKit

@main
struct GolfTrackerApp: App {

    /// One shared store for the whole app.
    ///
    /// Built eagerly and failing loudly: a store that cannot open is not something the app can work around,
    /// and silently falling back to in-memory would lose the golfer's rounds without telling them.
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: Schema(GolfTrackerSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            fatalError("Could not open the Golf Tracker database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}

/// The three primary areas. Scan opens first because it is the main action.
struct RootView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: Tab = .scan
    @State private var didSeed = false

    enum Tab: Hashable {
        case scan, map, rounds
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanView()
                .tabItem { Label("Scan", systemImage: "doc.text.viewfinder") }
                .tag(Tab.scan)

            GeorgiaMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)

            RoundsView()
                .tabItem { Label("Rounds", systemImage: "list.clipboard") }
                .tag(Tab.rounds)
        }
        .task {
            guard !didSeed else { return }
            didSeed = true
            let courseRepository = CourseRepository(context: modelContext)
            try? courseRepository.seedCatalogIfNeeded()
            // Sweep up any image left behind by a scan that was never saved.
            try? await RoundRepository(context: modelContext).cleanUpOrphanedImages()
        }
    }
}
