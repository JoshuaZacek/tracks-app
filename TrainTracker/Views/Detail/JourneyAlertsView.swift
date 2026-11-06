import SwiftData
import SwiftUI

/// One journey's alerts, Live Activity and stop alarm: each alert setting
/// follows the device's (Settings) unless changed here.
struct JourneyAlertsView: View {
    let journey: Journey
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var prefs: JourneyPrefs
    @State private var device: NotificationPrefs?
    @State private var error: String?
    /// Minutes before arrival the stop alarm goes off (kept on the phone).
    @State private var alarmLead: Int
    @State private var askingForAlarms = false
    /// Minutes to get to the station (for "Leave now"); saved on the journey.
    @State private var travelMinutes: Int?
    private let activities = LiveActivities.shared
    private let alarms = StopAlarm.shared

    init(journey: Journey) {
        self.journey = journey
        _prefs = State(initialValue: journey.prefs ?? JourneyPrefs())
        _alarmLead = State(initialValue: StopAlarm.shared.leadMinutes(for: journey.id))
        _travelMinutes = State(initialValue: journey.travelMinutes)
    }

    var body: some View {
        NavigationStack {
            Form {
                liveActivitySection
                leaveSection
                stopAlarmSection
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
            .task(id: travelMinutes) { await saveTravelMinutes() }
            .onChange(of: scenePhase) { _, phase in
                // Back from the Settings app: alarms may have been allowed.
                if phase == .active { alarms.refreshAuthorization() }
            }
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
                Text("Live Activities are turned off for tracks in iPhone Settings.")
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

    // MARK: Leaving for the station

    private var leaveSection: some View {
        Section {
            TravelTimeRow(minutes: $travelMinutes, station: journey.from.station)
            if travelMinutes != nil {
                choice("Leave now", \.leaveNow, default: device?.leaveNow)
            }
            // Only regular journeys have a summary time.
            if journey.templateId != nil {
                choice("Morning summary", \.morningSummary, default: device?.morningSummary)
            }
        } header: {
            Text("Getting there")
        } footer: {
            if let travelMinutes, prefs.applied(over: device ?? .defaults).leaveNow {
                Text("An alert \(travelMinutes + 2) minutes before the train leaves, later if it's running late. Only the minutes are sent to tracks, not where you are.")
            } else {
                Text("Set it for a “Leave now” alert. Only the minutes are sent to tracks, not where you are.")
            }
        }
    }

    private func saveTravelMinutes() async {
        guard travelMinutes != journey.travelMinutes else { return }
        // A pause, so stepping through the picker sends once.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            try await JourneySync.shared.setTravelMinutes(travelMinutes, for: journey, in: context)
            error = nil
        } catch {
            if Task.isCancelled { return }
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Stop alarm

    private var stopAlarmSection: some View {
        Section {
            Toggle("Wake me before my stop", isOn: Binding(get: { prefs.stopAlarm == true }, set: setStopAlarm))
                .disabled(askingForAlarms || isOver)
                .accessibilityIdentifier("stopAlarm")
            if prefs.stopAlarm == true {
                Picker("Alarm", selection: Binding(get: { alarmLead }, set: setAlarmLead)) {
                    ForEach(StopAlarm.leadOptions, id: \.self) { Text("\($0) min before").tag($0) }
                }
            }
            if alarms.isDenied {
                Button("Open iPhone Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: {
            Text("Stop alarm")
        } footer: {
            if alarms.isDenied {
                Text("Alarms are turned off for tracks. Allow them in Settings to be woken before \(journey.to.name).")
            } else if prefs.stopAlarm == true, let fire = alarms.fireDate(for: journey.id), fire > .now {
                Text("Goes off at \(RailTime.hhmm(fire)), and moves if the train's times change.")
            } else {
                Text("An alarm goes off before the train reaches \(journey.to.name), even on silent, and moves if the train's times change.")
            }
        }
    }

    /// Finished trains have nothing to wake anyone for.
    private var isOver: Bool {
        if journey.archivedAt != nil { return true }
        if let state = journey.live?.state, [.arrived, .cancelled].contains(state) { return true }
        return false
    }

    /// Turning it on asks for alarms first; if they're not allowed it stays off.
    private func setStopAlarm(_ on: Bool) {
        guard on else {
            prefs.stopAlarm = nil // absent is off
            return
        }
        Task {
            askingForAlarms = true
            defer { askingForAlarms = false }
            if await alarms.requestAuthorization() {
                prefs.stopAlarm = true
            }
        }
    }

    private func setAlarmLead(_ minutes: Int) {
        alarmLead = minutes
        Task { await alarms.setLeadMinutes(minutes, for: journey) }
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
            // Off means off, even if the server didn't hear about it yet.
            if prefs.stopAlarm != true { alarms.cancel(journeyID: journey.id) }
        }
    }
}
