import SwiftData
import SwiftUI

/// The main screen: Live, Upcoming and Past journeys, each grouped by day.
struct JourneysView: View {
    @Query(sort: \Journey.departsAt) private var journeys: [Journey]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var addingJourney = false
    @State private var actionError: String?
    private let sync = JourneySync.shared

    var body: some View {
        NavigationStack {
            // Re-sorted into sections every minute as journeys start and finish.
            TimelineView(.everyMinute) { timeline in
                let filtered = journeys.filter { JourneyFilter.matches($0, query: search) }
                let statuses = Dictionary(filtered.compactMap { j in j.live.map { (j.id, $0) } }, uniquingKeysWith: { a, _ in a })
                let sections = JourneySections(journeys: filtered, statuses: statuses, now: timeline.date)
                List {
                    if let offline = sync.lastError, !journeys.isEmpty {
                        offlineNote(offline)
                    }
                    if sections.isEmpty {
                        emptyState
                    }
                    if !sections.live.isEmpty {
                        sectionTitle("Live", liveDot: true)
                        groups(sections.live, now: timeline.date)
                    }
                    if !sections.upcoming.isEmpty {
                        sectionTitle("Upcoming")
                        groups(sections.upcoming, now: timeline.date)
                    }
                    if !sections.past.isEmpty {
                        sectionTitle("Past")
                        groups(sections.past, now: timeline.date)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .refreshable { await sync.refresh(in: context) }
            }
            .navigationTitle("Journeys")
            .navigationDestination(for: UUID.self) { id in
                if let journey = journeys.first(where: { $0.id == id }) {
                    JourneyDetailView(journey: journey)
                }
            }
            .searchable(text: $search, prompt: "Station, headcode or operator")
            .searchToolbarBehavior(.minimize)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Add journey", systemImage: "plus") { addingJourney = true }
                        .buttonStyle(.glassProminent)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            .sheet(isPresented: $addingJourney) {
                AddJourneyView()
            }
            .alert("Couldn't update the journey", isPresented: .constant(actionError != nil)) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            // The server holds the journeys: refresh on opening, on returning to the
            // app, and when the server says the list could next change on its own.
            .task { await sync.refresh(in: context) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await sync.refresh(in: context) } }
            }
            .task(id: sync.nextRefresh) {
                guard let next = sync.nextRefresh else { return }
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                guard !Task.isCancelled, scenePhase == .active else { return }
                await sync.refresh(in: context)
            }
        }
    }

    private func offlineNote(_ message: String) -> some View {
        Label("Can't reach the server. Showing saved journeys.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHint(message)
    }

    private func sectionTitle(_ title: String, liveDot: Bool = false) -> some View {
        HStack(spacing: 10) {
            if liveDot {
                Circle().fill(.tint).frame(width: 12, height: 12)
            }
            Text(title).font(.title2.bold())
        }
        .listRowInsets(EdgeInsets(top: 22, leading: 20, bottom: 2, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func groups(_ groups: [JourneyGroup], now: Date) -> some View {
        ForEach(groups) { group in
            Text(group.label)
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.journeys) { journey in
                JourneyCard(journey: journey, now: now)
                    // Tapping opens the journey; a hidden link keeps the card free of a disclosure chevron.
                    .background {
                        NavigationLink(value: journey.id) { EmptyView() }
                            .opacity(0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await sync.delete(journey, in: context) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        let archived = journey.archivedAt != nil
                        Button(archived ? "Restore" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
                            Task {
                                do {
                                    try await sync.setArchived(!archived, for: journey, in: context)
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                        }
                        .tint(.indigo)
                    }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if search.isEmpty {
                ContentUnavailableView {
                    Label("No journeys yet", systemImage: "tram")
                } description: {
                    Text("Add a train from any station's timetable to follow it here.")
                } actions: {
                    Button("Add a journey") { addingJourney = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

#Preview {
    let container = try! ModelContainer(for: Journey.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let today = RailTime.ymd(.now)
    let tomorrow = RailTime.ymd(.now.addingTimeInterval(86400))
    let soon = RailTime.hhmm(.now.addingTimeInterval(20 * 60))
    let later = RailTime.hhmm(.now.addingTimeInterval(4 * 3600))
    for j in [
        Journey.preview(from: ("YRK", "York"), to: ("KGX", "London King's Cross"), date: today, departs: soon, platform: "3"),
        Journey.preview(from: ("KGX", "London King's Cross"), to: ("YRK", "York"), date: today, departs: later, platform: "8"),
        Journey.preview(from: ("MAN", "Manchester Piccadilly"), to: ("LDS", "Leeds"), date: tomorrow, departs: "07:15"),
    ] {
        container.mainContext.insert(j)
    }
    return JourneysView().modelContainer(container)
}
