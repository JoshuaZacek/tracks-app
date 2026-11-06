import SwiftUI

/// Settings › Regular journeys: every journey tracks adds each week, with any
/// that it couldn't find a train for last time.
struct RegularJourneysView: View {
    @State private var templates: [JourneyTemplate]?
    @State private var error: String?
    private let client = TracksClient.shared

    var body: some View {
        Form {
            if let templates {
                if templates.isEmpty {
                    ContentUnavailableView {
                        Label("No regular journeys", systemImage: "repeat")
                    } description: {
                        Text("Open a journey and choose Repeat to have tracks add it every week.")
                    }
                } else {
                    Section {
                        ForEach(templates) { template in
                            NavigationLink(value: template) {
                                RegularJourneyRow(template: template)
                            }
                            .swipeActions {
                                Button("Stop repeating", systemImage: "trash", role: .destructive) {
                                    Task { await delete(template) }
                                }
                            }
                        }
                    } footer: {
                        Text("tracks adds each one the day before it runs. Journeys already added stay if you stop repeating.")
                    }
                }
            } else if error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let error {
                Section { Label(error, systemImage: "wifi.slash").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Regular journeys")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: JourneyTemplate.self) { template in
            RegularJourneyEditView(template: template, onChange: replace, onDelete: { remove(template.id) })
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            templates = try await client.journeyTemplates()
            error = nil
        } catch {
            self.error = "Couldn't load your regular journeys: \(error.localizedDescription)"
        }
    }

    private func delete(_ template: JourneyTemplate) async {
        do {
            try await client.deleteJourneyTemplate(id: template.id)
        } catch let error as TracksError where error.httpStatus == 404 {
            // Already gone.
        } catch {
            self.error = "Couldn't stop repeating: \(error.localizedDescription)"
            return
        }
        remove(template.id)
    }

    private func replace(_ template: JourneyTemplate) {
        guard let i = templates?.firstIndex(where: { $0.id == template.id }) else { return }
        templates?[i] = template
    }

    private func remove(_ id: UUID) {
        templates?.removeAll { $0.id == id }
        // Its journeys are no longer linked to it.
        JourneySync.shared.requestRefresh()
    }
}

/// "07:42 London Bridge → Brighton", its days and settings, and any problem.
struct RegularJourneyRow: View {
    let template: JourneyTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(template.title)
                .font(.headline)
            Text(template.summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let problem = template.problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else if let next = template.nextJourney {
                Text("Next: \(RailTime.dayLabel(for: next.scheduledDeparture)) at \(RailTime.hhmm(next.scheduledDeparture))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One regular journey: its train time, days, travel time and morning summary,
/// saved as they change. Journeys already added keep their time.
struct RegularJourneyEditView: View {
    var onChange: (JourneyTemplate) -> Void = { _ in }
    var onDelete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var template: JourneyTemplate
    @State private var draft: RegularJourneyDraft
    @State private var summaryTime: String
    @State private var error: String?
    @State private var confirmingDelete = false
    private let client = TracksClient.shared

    init(template: JourneyTemplate, onChange: @escaping (JourneyTemplate) -> Void = { _ in }, onDelete: @escaping () -> Void = {}) {
        self.onChange = onChange
        self.onDelete = onDelete
        _template = State(initialValue: template)
        _draft = State(initialValue: RegularJourneyDraft(template))
        _summaryTime = State(initialValue: template.summaryTime ?? ClockTime.defaultSummaryTime(departTime: template.departTime))
    }

    var body: some View {
        Form {
            if let problem = template.problem {
                Section {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("The timetable may have changed. Pick the time of the train you catch now.")
                }
            }
            Section {
                ClockTimePicker(title: "Train at", time: $draft.departTime)
                DaysPicker(days: $draft.days)
            } header: {
                Text("\(template.from.name) → \(template.to.name)")
            } footer: {
                Text("\(Weekdays.label(draft.days)), the train nearest \(draft.departTime). Changes start with the next journey tracks adds.")
            }
            Section {
                TravelTimeRow(minutes: $draft.travelMinutes, station: template.from)
            } footer: {
                Text("For a “Leave now” alert. Only the minutes are sent to tracks, not where you are.")
            }
            Section {
                Toggle("Morning summary", isOn: Binding(
                    get: { draft.summaryTime != nil },
                    set: { draft.summaryTime = $0 ? summaryTime : nil }
                ))
                if draft.summaryTime != nil {
                    ClockTimePicker(title: "Send at", time: Binding(
                        get: { draft.summaryTime ?? summaryTime },
                        set: {
                            summaryTime = $0
                            draft.summaryTime = $0
                        }
                    ))
                }
            } footer: {
                Text("How your train's running, before you set off.")
            }
            if let error {
                Section { Label(error, systemImage: "wifi.slash").foregroundStyle(.secondary) }
            }
            Section {
                Button("Stop repeating", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .navigationTitle("Regular journey")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: draft) { await saveIfChanged() }
        .confirmationDialog("Stop repeating this journey?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Stop repeating", role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("Journeys already added stay.")
        }
    }

    /// Sends changes after a short pause, so moving the time picker sends once.
    private func saveIfChanged() async {
        guard let body = draft.changes(from: RegularJourneyDraft(template)) else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        do {
            template = try await client.updateJourneyTemplate(id: template.id, body)
            onChange(template)
            error = nil
        } catch {
            // Replaced by a newer change.
            if Task.isCancelled { return }
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        do {
            try await client.deleteJourneyTemplate(id: template.id)
        } catch let error as TracksError where error.httpStatus == 404 {
            // Already gone.
        } catch {
            self.error = "Couldn't stop repeating: \(error.localizedDescription)"
            return
        }
        onDelete()
        dismiss()
    }
}

/// A regular journey by its ID (from a journey's screen), loaded then edited.
struct RegularJourneyLoader: View {
    let id: UUID
    @State private var template: JourneyTemplate?
    @State private var error: String?

    var body: some View {
        Group {
            if let template {
                RegularJourneyEditView(template: template, onDelete: { JourneySync.shared.requestRefresh() })
            } else if let error {
                ContentUnavailableView("Couldn't load it", systemImage: "wifi.slash", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                if let found = try await TracksClient.shared.journeyTemplates().first(where: { $0.id == id }) {
                    template = found
                } else {
                    error = "This journey no longer repeats."
                    JourneySync.shared.requestRefresh()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A regular journey's settings in a sheet of their own (from a journey's screen).
struct RegularJourneySheet: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RegularJourneyLoader(id: id)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
    }
}
