import SwiftData
import SwiftUI

/// One journey's alerts and Live Activity: each setting follows the device's
/// (Settings) unless changed here.
struct JourneyAlertsView: View {
    let journey: Journey
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var prefs: JourneyPrefs
    @State private var device: NotificationPrefs?
    @State private var error: String?
    private let activities = LiveActivities.shared

    init(journey: Journey) {
        self.journey = journey
        _prefs = State(initialValue: journey.prefs ?? JourneyPrefs())
    }

    var body: some View {
        NavigationStack {
            Form {
                liveActivitySection
                Section {
                    choice("Platform", \.platforms, default: device?.platforms)
                    choice("Delays", \.delays, default: device?.delays)
                    if prefs.applied(over: device ?? .defaults).delays {
                        threshold
                    }
                    choice("Cancellations", \.cancellations, default: device?.cancellations)
                    choice("Departure", \.departure, default: device?.departure)
                    choice("Arrival", \.arrival, default: device?.arrival)
                } header: {
                    Text("Alert me about")
                } footer: {
                    Text("“Default” follows Settings, so changing it there changes this journey too.")
                }
                if let error {
                    Section { Label(error, systemImage: "wifi.slash").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("\(journey.from.crs) → \(journey.to.crs) alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task { device = try? await TracksClient.shared.device().prefs }
            .task(id: prefs) { await saveIfChanged() }
        }
    }

    // MARK: Live Activity

    private var liveActivitySection: some View {
        Section {
            if activities.isRunning(for: journey.id) {
                Button("End Live Activity", systemImage: "stop.circle") {
                    Task { await activities.stop(journeyID: journey.id) }
                }
            } else if canStartNow {
                Button("Start Live Activity", systemImage: "play.circle") {
                    do {
                        try activities.start(for: journey)
                        error = nil
                    } catch {
                        self.error = "Couldn't start the Live Activity: \(error.localizedDescription)"
                    }
                }
                .disabled(!activities.areEnabled)
                .accessibilityIdentifier("startLiveActivity")
            }
            choice("Start automatically", \.liveActivity, default: device?.liveActivity)
        } header: {
            Text("Live Activity")
        } footer: {
            if !activities.areEnabled {
                Text("Live Activities are turned off for TrainTracker in iPhone Settings.")
            } else {
                Text("Automatically starts 30 minutes before the train leaves.")
            }
        }
    }

    /// Not for trains that have finished or are days away.
    private var canStartNow: Bool {
        guard journey.archivedAt == nil else { return false }
        if let state = journey.live?.state, [.arrived, .cancelled].contains(state) { return false }
        return journey.departsAt.timeIntervalSinceNow < 12 * 3600 && journey.arrivesAt > .now.addingTimeInterval(-3600)
    }

    // MARK: Rows

    /// Default (what Settings says), On or Off.
    private func choice(_ title: String, _ key: WritableKeyPath<JourneyPrefs, Bool?>, default deviceValue: Bool?) -> some View {
        Picker(title, selection: Binding(get: { prefs[keyPath: key] }, set: { prefs[keyPath: key] = $0 })) {
            Text("Default (\(deviceValue.map { $0 ? "On" : "Off" } ?? "…"))").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }

    private var threshold: some View {
        let options = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]
        return Picker("When late by", selection: $prefs.delayThresholdMinutes) {
            Text("Default (\(device.map { "\($0.delayThresholdMinutes) min" } ?? "…"))").tag(Int?.none)
            ForEach(options, id: \.self) { Text("\($0) min").tag(Int?.some($0)) }
        }
    }

    private func saveIfChanged() async {
        guard prefs != (journey.prefs ?? JourneyPrefs()) else { return }
        do {
            try await JourneySync.shared.setPrefs(prefs, for: journey, in: context)
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
