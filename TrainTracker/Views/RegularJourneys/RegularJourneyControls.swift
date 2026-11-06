import SwiftUI

/// Seven day buttons, Monday first. At least one day stays on.
struct DaysPicker: View {
    @Binding var days: [Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Weekdays.all, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    toggle(day)
                } label: {
                    Text(Weekdays.initial(day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(width: 36, height: 36)
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .circle)
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Weekdays.plural(day))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("days")
    }

    private func toggle(_ day: Int) {
        if days.contains(day) {
            guard days.count > 1 else { return }
            days.removeAll { $0 == day }
        } else {
            days = Weekdays.normalized(days + [day])
        }
    }
}

/// A UK time of day ("HH:MM") on a 24-hour clock, whatever the phone's settings.
struct ClockTimePicker: View {
    let title: String
    @Binding var time: String

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { ClockTime.pickerDate(time) },
            set: { time = ClockTime.fromPicker($0) }
        ), displayedComponents: .hourAndMinute)
        .environment(\.timeZone, RailTime.zone)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }
}

/// "Time to get to the station", with a one-tap suggestion from where the
/// phone is while it's not set. `autoSuggest` suggests straight away when
/// location is already allowed (no prompt).
struct TravelTimeRow: View {
    @Binding var minutes: Int?
    let station: Station
    var autoSuggest = false
    @State private var suggesting = false
    @State private var failed = false

    var body: some View {
        Picker("Time to get to the station", selection: $minutes) {
            Text("Not set").tag(Int?.none)
            ForEach(TravelTime.options(including: minutes), id: \.self) {
                Text(TravelTime.label($0)).tag(Int?.some($0))
            }
        }
        .accessibilityIdentifier("travelTime")
        .task {
            if autoSuggest, minutes == nil, CurrentLocation.isAuthorized { await suggest() }
        }
        if minutes == nil {
            Button {
                Task { await suggest() }
            } label: {
                HStack {
                    Label(failed ? "Couldn't work it out" : "Suggest from where I am", systemImage: "location")
                    if suggesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(suggesting)
        }
    }

    private func suggest() async {
        suggesting = true
        defer { suggesting = false }
        let suggestion = await TravelTimeSuggestion.minutes(to: station)
        failed = suggestion == nil
        // Not if it was set meanwhile.
        if minutes == nil, let suggestion { minutes = suggestion }
    }
}

extension CallingPoint {
    var station: Station { Station(crs: crs, name: name, lat: lat, lon: lon) }
}
