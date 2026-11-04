import OSLog
import SwiftData
import SwiftUI

/// The main screen: Live, Upcoming and Past journeys, each grouped by day.
struct JourneysView: View {
    @Query(sort: \Journey.departsAt) private var journeys: [Journey]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    /// The search button shows the search field; cancelling it hides the field again.
    @State private var filtering = false
    @State private var searching = false
    /// Past journeys can be folded away; remembered between launches. Toggled through
    /// @State, since an @AppStorage change drops withAnimation's transaction.
    @State private var pastCollapsed = UserDefaults.standard.bool(forKey: "pastCollapsed")
    @State private var addingJourney = false
    @State private var showingSettings = false
    @State private var actionError: String?
    @State private var path: [UUID] = []
    private let sync = JourneySync.shared
    private let push = PushNotifications.shared

    var body: some View {
        NavigationStack(path: $path) {
            // Re-sorted into sections every minute as journeys start and finish.
            TimelineView(.everyMinute) { timeline in
                let filtered = journeys.filter { JourneyFilter.matches($0, query: search, now: timeline.date) }
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
                        // With no day heading, the cards need a little more room under "Live".
                        sectionTitle("Live", liveDot: true, first: true, bottom: sections.liveShowsDays ? 2 : 10)
                        groups(sections.live, now: timeline.date, dayLabels: sections.liveShowsDays)
                    }
                    if !sections.upcoming.isEmpty {
                        sectionTitle("Upcoming", first: sections.live.isEmpty)
                        groups(sections.upcoming, now: timeline.date)
                    }
                    if !sections.past.isEmpty {
                        // Searching always shows matching past journeys, folded or not.
                        let showPast = !pastCollapsed || !search.isEmpty
                        sectionTitle("Past", first: sections.live.isEmpty && sections.upcoming.isEmpty,
                                     collapsed: search.isEmpty ? pastCollapsed : nil) {
                            // The list's own row insert/remove, as for Add train's departed trains.
                            withAnimation(.snappy) { pastCollapsed.toggle() }
                        }
                        if showPast {
                            groups(sections.past, now: timeline.date, dimmed: true)
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .refreshable { await sync.refresh(in: context) }
            }
            // No visible title; "Journeys" still names the screen for VoiceOver.
            .navigationTitle("Journeys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .navigationDestination(for: UUID.self) { id in
                if let journey = journeys.first(where: { $0.id == id }) {
                    JourneyDetailView(journey: journey)
                }
            }
            .modifier(FilterField(shown: filtering, text: $search, isPresented: $searching))
            .onChange(of: pastCollapsed) { _, collapsed in
                UserDefaults.standard.set(collapsed, forKey: "pastCollapsed")
            }
            .onChange(of: searching) { _, active in
                if !active {
                    filtering = false
                    search = ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Search", systemImage: "magnifyingglass") {
                        filtering = true
                        searching = true
                    }
                    .accessibilityIdentifier("search")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "ellipsis") { showingSettings = true }
                        .accessibilityIdentifier("settings")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Add train", systemImage: "plus") { addingJourney = true }
                        .buttonStyle(.glassProminent)
                }
            }
            .sheet(isPresented: $addingJourney) {
                AddJourneyView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // A tapped alert opens its journey (once the list has it).
            .onChange(of: push.journeyToOpen, initial: true) { _, id in openTappedJourney(id) }
            .onChange(of: journeys.count) { openTappedJourney(push.journeyToOpen) }
            // Tapping a Live Activity: traintracker://journey/<id>.
            .onOpenURL { url in
                guard url.scheme == "traintracker", url.host() == "journey", let id = UUID(uuidString: url.lastPathComponent) else { return }
                push.journeyToOpen = id
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

    private func openTappedJourney(_ id: UUID?) {
        guard let id else { return }
        Logger.tracks.info("Opening journey \(id) from an alert")
        guard journeys.contains(where: { $0.id == id }) else {
            // Not cached yet (e.g. saved on the server since the last refresh).
            Task { await sync.refresh(in: context) }
            return
        }
        push.journeyToOpen = nil
        addingJourney = false
        showingSettings = false
        path = [id]
    }

    private func offlineNote(_ message: String) -> some View {
        Label("Can't reach the server. Showing saved journeys.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHint(message)
    }

    /// `first`: the top section sits close under the toolbar; later ones get a gap above.
    /// `collapsed`: non-nil makes the title a button that folds the section, with a chevron.
    private func sectionTitle(_ title: String, liveDot: Bool = false, first: Bool = false, bottom: CGFloat = 2,
                              collapsed: Bool? = nil, toggle: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 10) {
            if liveDot {
                Circle().fill(.tint).frame(width: 12, height: 12)
                    .background { PulsingHalo() }
            }
            HStack(spacing: 5) {
                Text(title).font(.title2.bold())
                if let collapsed {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
            }
            if collapsed != nil { Spacer() }
        }
        .contentShape(Rectangle())
        .onTapGesture { if collapsed != nil { toggle() } }
        .accessibilityAction { if collapsed != nil { toggle() } }
        .accessibilityValue(collapsed.map { $0 ? "Collapsed" : "Expanded" } ?? "")
        .listRowInsets(EdgeInsets(top: first ? 4 : 22, leading: 20, bottom: bottom, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    /// `dimmed`: finished journeys, faded like a disabled control (still tappable).
    /// `dayLabels`: false hides the day headings (Live, when every trip is today's).
    private func groups(_ groups: [JourneyGroup], now: Date, dayLabels: Bool = true, dimmed: Bool = false) -> some View {
        ForEach(groups) { group in
            if dayLabels {
                Text(group.label)
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(group.journeys) { journey in
                JourneyCard(journey: journey, now: now)
                    .completeStyle(dimmed)
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

/// The journey filter's search field, there only while filtering.
private struct FilterField: ViewModifier {
    let shown: Bool
    @Binding var text: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if shown {
            content.searchable(text: $text, isPresented: $isPresented, prompt: "Search")
        } else {
            content
        }
    }
}

#if DEBUG // preview data is Debug-only
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
#endif
