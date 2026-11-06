import SwiftData
import SwiftUI
import UserNotifications

/// Alerts and Live Activities for every journey, and deleting the user's data.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var prefs: NotificationPrefs?
    /// What the server last confirmed, so only real changes are sent.
    @State private var savedPrefs: NotificationPrefs?
    @State private var pushEnabledOnServer: Bool?
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var deleting = false
    /// Opened from a "couldn't find your train" alert.
    @State private var showingRegularJourneys = false
    private let push = PushNotifications.shared
    private let client = TracksClient.shared

    var body: some View {
        NavigationStack {
            Form {
                permissionSection
                if let binding = Binding($prefs) {
                    alertsSection(binding)
                    regularJourneysSection(binding)
                    liveActivitySection(binding)
                } else {
                    if error == nil {
                        Section { ProgressView().frame(maxWidth: .infinity) }
                    }
                    regularJourneysLink
                }
                if let error {
                    Section {
                        Label(error, systemImage: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                dataSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showingRegularJourneys) { RegularJourneysView() }
            .onChange(of: push.regularJourneysToOpen, initial: true) { _, open in
                guard open else { return }
                push.regularJourneysToOpen = false
                showingRegularJourneys = true
            }
            .task { await load() }
            .task(id: prefs) { await saveIfChanged() }
            .onChange(of: scenePhase) { _, phase in
                // Back from the system Settings app: permission may have changed.
                if phase == .active { Task { await push.refreshAuthorization() } }
            }
            .confirmationDialog("Delete your data?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete journeys and settings", role: .destructive) {
                    Task { await deleteEverything() }
                }
            } message: {
                Text("Removes your saved journeys and alert settings from this iPhone and from the tracks server. This can't be undone.")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var permissionSection: some View {
        switch push.authorization {
        case .notDetermined:
            Section {
                Button("Turn on notifications", systemImage: "bell.badge") {
                    Task { await push.requestAuthorization() }
                }
                .accessibilityIdentifier("enableNotifications")
            } footer: {
                Text("Get alerts about platforms, delays and cancellations for the trains you've saved.")
            }
        case .denied:
            Section {
                Button("Open iPhone Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("Notifications are off")
            } footer: {
                Text("Allow notifications for tracks in Settings to get alerts.")
            }
        default:
            if pushEnabledOnServer == false {
                Section {
                    Label("The tracks server isn't sending notifications yet.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func alertsSection(_ prefs: Binding<NotificationPrefs>) -> some View {
        Section {
            Toggle("Platform", isOn: prefs.platforms)
            Toggle("Delays", isOn: prefs.delays)
            if prefs.wrappedValue.delays {
                Stepper(value: prefs.delayThresholdMinutes, in: NotificationPrefs.thresholdRange, step: 1) {
                    LabeledContent("When late by", value: "\(prefs.wrappedValue.delayThresholdMinutes) min")
                }
                .accessibilityIdentifier("delayThreshold")
            }
            Toggle("Cancellations", isOn: prefs.cancellations)
            Toggle("Departure", isOn: prefs.departure)
            Toggle("Arrival", isOn: prefs.arrival)
        } header: {
            Text("Alert me about")
        } footer: {
            Text("For every journey, unless you change it on the journey. Platform alerts come when the platform is announced or changes; arrival alerts 10 minutes before and on arriving.")
        }
        .disabled(!push.authorization.allowsAlerts && push.authorization != .notDetermined)
    }

    private func regularJourneysSection(_ prefs: Binding<NotificationPrefs>) -> some View {
        Section {
            NavigationLink { RegularJourneysView() } label: {
                Label("Regular journeys", systemImage: "repeat")
            }
            .accessibilityIdentifier("regularJourneys")
            Group {
                Toggle("Morning summary", isOn: prefs.morningSummary)
                Toggle("Leave now", isOn: prefs.leaveNow)
            }
            .disabled(!push.authorization.allowsAlerts && push.authorization != .notDetermined)
        } header: {
            Text("Commuting")
        } footer: {
            Text("Morning summary: how a regular journey's train is running, at the time you choose on it. Leave now: when to set off, for journeys with a time to get to the station.")
        }
    }

    /// Before the settings load (or if they can't), the list is still reachable.
    private var regularJourneysLink: some View {
        Section {
            NavigationLink { RegularJourneysView() } label: {
                Label("Regular journeys", systemImage: "repeat")
            }
        }
    }

    private func liveActivitySection(_ prefs: Binding<NotificationPrefs>) -> some View {
        Section {
            Toggle("Start automatically", isOn: prefs.liveActivity)
        } header: {
            Text("Live Activities")
        } footer: {
            if LiveActivities.shared.areEnabled {
                Text("Shows your train on the Lock Screen and in the Dynamic Island from 30 minutes before it leaves.")
            } else {
                Text("Live Activities are turned off for tracks in iPhone Settings.")
            }
        }
    }

    private var dataSection: some View {
        Section {
            Button("Delete my data", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(deleting)
        } footer: {
            Text("Your journeys are kept on the tracks server so it can follow your trains and alert you. Nothing identifies you, only this install.")
        }
    }

    // MARK: Loading and saving

    private func load() async {
        await push.refreshAuthorization()
        do {
            let device = try await client.device()
            savedPrefs = device.prefs
            prefs = device.prefs
            error = nil
        } catch {
            self.error = "Couldn't load your settings: \(error.localizedDescription)"
        }
        pushEnabledOnServer = try? await client.status().push?.enabled
    }

    /// Sends changes after a short pause, so stepping the threshold sends once.
    private func saveIfChanged() async {
        guard let prefs, prefs != savedPrefs else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        do {
            let device = try await client.updateDevice(UpdateDeviceRequest(prefs: prefs))
            savedPrefs = device.prefs
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func deleteEverything() async {
        deleting = true
        defer { deleting = false }
        do {
            try await client.deleteDevice()
            await LiveActivities.shared.endAll()
            JourneySync.shared.removeAll(in: context)
            dismiss()
        } catch {
            self.error = "Couldn't delete your data: \(error.localizedDescription)"
        }
    }
}
