//
//  TrainTrackerApp.swift
//  TrainTracker
//
//  Created by Joshua Zacek on 11/2/26.
//

import SwiftData
import SwiftUI

@main
struct TrainTrackerApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            JourneysView()
                // Register this install with the tracks server (once) and keep its details current.
                .task {
                    // Watch Live Activities (push-to-start and push tokens) from the start.
                    LiveActivities.shared.start()
                    await TracksClient.shared.prepareDevice()
                    await PushNotifications.shared.prepare()
                    // Fetch (or revalidate) place names now so nearest-town labels work offline later.
                    _ = await PlacesStore.shared.placeIndex()
                }
            #if DEBUG
                .task {
                    // `-seedJourneys`: fill the list with real trains for testing (see DebugSeed).
                    if DebugSeed.requested { await DebugSeed.run(into: JourneyStore.context) }
                }
            #endif
        }
        .modelContainer(JourneyStore.container)
    }
}

/// The app's SwiftData store of saved journeys.
@MainActor
enum JourneyStore {
    static let container: ModelContainer = {
        // UI tests (`-uiTesting`) get an empty in-memory store, leaving real journeys alone.
        let inMemory = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        do {
            // "journeys-v2": calling points moved to the tracks server's shape (ISO times), so the
            // store from the PoC-era build, which only ever held test data, is left behind.
            return try ModelContainer(for: Journey.self, configurations: ModelConfiguration("journeys-v2", isStoredInMemoryOnly: inMemory))
        } catch {
            fatalError("Couldn't open the journey store: \(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }
}
