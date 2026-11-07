import Foundation
import SwiftUI
import Testing
@testable import TrainTracker

/// Sprint 3: dividing trains, how busy, station messages. Decoding (with and
/// without the new fields), what the screens show, and a render for a look.
struct DarwinExtrasTests {
    private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle(for: ExtrasBundleToken.self).url(forResource: name, withExtension: "json"))
        return try TracksClient.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TracksClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func decodesADivisionLoadingAndStationMessages() throws {
        let journey = try fixture("journey-divides", as: ServerJourney.self)
        #expect(journey.prefs.divides == false)

        let division = try #require(journey.live.divides)
        #expect(division.atCrs == "HRH")
        #expect(division.atName == "Horsham")
        #expect(division.at == (try Date("2026-11-07T17:27:00+00:00", strategy: .iso8601)))
        #expect(division.portions.map(\.destCrs) == ["PMH", "BOG"])
        #expect(division.portions.map(\.yours) == [true, false])
        #expect(division.portions.allSatisfy { $0.note == nil })
        #expect(division.message == "This train divides at Horsham; only some coaches go to Chichester.")

        let loading = try #require(journey.live.loading)
        #expect(loading.percentage == 42)
        #expect(loading.level == .moderate)
        #expect(loading.coaches?.map(\.number) == ["A1", "B1"])
        #expect(loading.coaches?.map(\.coachClass) == ["Standard", nil])
        #expect(loading.quietestCoaches == ["B1", "A1"])

        #expect(journey.stationMessages.map(\.id) == ["190201", "190196"])
        let minor = journey.stationMessages[1]
        #expect(minor.severity == .minor)
        #expect(minor.stations == ["NOT"])
        #expect(minor.category == "Train")
        #expect(minor.link?.host == "www.nationalrail.co.uk")
        #expect(minor.updatedAt == (try Date("2026-11-07T17:44:35+00:00", strategy: .iso8601)))
        #expect(journey.stationMessages[0].url == nil)
        #expect(journey.stationMessages[0].isProminent)

        // The list summary made from it keeps the loading, for the card.
        #expect(LiveSummary(journey.live).loading == loading)
    }

    /// Servers (and responses cached) from before Sprint 3 have none of it.
    @Test func olderJourneysDecodeWithoutTheNewFields() throws {
        for name in ["journey-no-extras", "journey"] {
            let journey = try fixture(name, as: ServerJourney.self)
            #expect(journey.stationMessages.isEmpty)
            #expect(journey.live.divides == nil)
            #expect(journey.live.loading == nil)
            #expect(journey.prefs.divides == nil)
        }
        let summary = try decode(LiveSummary.self, #"{"state":"scheduled","isCancelled":false,"stale":false}"#)
        #expect(summary.loading == nil)
    }

    @Test func listSummaryCarriesLoading() throws {
        let summary = try decode(LiveSummary.self, """
        {"state":"live","expectedDeparture":"2026-11-07T16:24:00+00:00","actualDeparture":null,"expectedArrival":null,"actualArrival":null,
         "delayMinutes":0,"platform":null,"isCancelled":false,"stale":false,"checkedAt":"2026-11-07T16:05:40+00:00",
         "loading":{"percentage":88,"level":"very_busy","coaches":null,"quietestCoaches":[]}}
        """)
        #expect(summary.loading?.level == .veryBusy)
        #expect(summary.loading?.coaches == nil)
        #expect(summary.loading?.quietestText == nil)
    }

    @Test func unknownLoadingLevelsAndSeverities() throws {
        let loading = try decode(TrainLoading.self, #"{"percentage":99,"level":"rammed","coaches":null}"#)
        #expect(loading.level == .unknown)
        #expect(loading.level.text == nil)
        #expect(loading.quietestCoaches.isEmpty)
        // Not shown: the app can't say what it means.
        let summary = LiveSummary(state: .live, isCancelled: false, stale: false, loading: loading)
        #expect(BusyDisplay.loading(status: nil, summary: summary) == nil)

        let message = try decode(StationMessage.self, """
        {"id":"1","stations":["KGX"],"category":"Station","severity":"catastrophic","text":"x","url":"not a link","updatedAt":"2026-11-07T17:44:35+00:00"}
        """)
        #expect(message.severity == .normal)
        #expect(message.link == nil)
    }

    @Test func dividesPrefs() throws {
        // Devices from before Sprint 3: on.
        let device = try decode(NotificationPrefs.self, """
        {"delays":true,"platforms":true,"cancellations":true,"departure":true,"arrival":true,"delayThresholdMinutes":5,"liveActivity":true,"morningSummary":true,"leaveNow":true,"connections":true}
        """)
        #expect(device.divides)
        let off = try decode(NotificationPrefs.self, """
        {"delays":true,"platforms":true,"cancellations":true,"departure":true,"arrival":true,"delayThresholdMinutes":5,"liveActivity":true,"morningSummary":true,"leaveNow":true,"connections":true,"divides":false}
        """)
        #expect(!off.divides)
        #expect(JourneyPrefs().applied(over: device).divides)
        #expect(!JourneyPrefs(divides: false).applied(over: device).divides)
        #expect(JourneyPrefs(divides: true).applied(over: off).divides)

        // Sent to the server: the device's prefs with `divides`, and a journey's override (null follows the device).
        let sent = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        #expect(sent["divides"] as? Bool == false)
        let journey = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(JourneyPrefs(divides: false).replacingAll)) as? [String: Any])
        #expect(journey["divides"] as? Bool == false)
        let following = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(JourneyPrefs().replacingAll)) as? [String: Any])
        #expect(following["divides"] is NSNull)
    }

    // MARK: Live Activity

    /// As ActivityKit decodes it: a plain JSONDecoder.
    @Test func contentStateWithAndWithoutDivides() throws {
        let base = #""state":"live","scheduledDeparture":"2026-11-07T16:24:00+00:00","scheduledArrival":"2026-11-07T18:12:00+00:00","isCancelled":false"#
        let with = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: Data("{\(base),\"divides\":\"Divides at Horsham · front 4 coaches\"}".utf8))
        #expect(with.divides == "Divides at Horsham · front 4 coaches")
        let null = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: Data("{\(base),\"divides\":null}".utf8))
        #expect(null.divides == nil)
        let older = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: Data("{\(base)}".utf8))
        #expect(older.divides == nil)
        #expect(older.state == .live)

        // What the app encodes decodes back the same; nil is left out.
        let again = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: JSONEncoder().encode(with))
        #expect(again == with)
        #expect(!String(decoding: try JSONEncoder().encode(older), as: UTF8.self).contains("divides"))
    }

    // MARK: What the screens show

    @MainActor // the card's Tone is main-actor isolated
    @Test func levelTexts() {
        #expect(LoadingLevel.quiet.text == "Quiet")
        #expect(LoadingLevel.moderate.text == "Some seats")
        #expect(LoadingLevel.busy.text == "Busy")
        #expect(LoadingLevel.veryBusy.text == "Very busy")
        #expect([LoadingLevel.quiet, .moderate, .busy, .veryBusy].map(\.segments) == [1, 2, 3, 4])
        #expect(LoadingLevel.busy.symbol == "person.3.fill")
        #expect(LoadingLevel.quiet.tone == .normal)
        #expect(LoadingLevel.veryBusy.tone == .late)
    }

    @Test func quietestCoaches() {
        #expect(TrainLoading(percentage: 40, level: .moderate, quietestCoaches: ["7", "8"]).quietestText == "Quietest: coaches 7 and 8")
        #expect(TrainLoading(percentage: 40, level: .moderate, quietestCoaches: ["B1"]).quietestText == "Quietest: coach B1")
        #expect(TrainLoading(percentage: 40, level: .moderate).quietestText == nil)
        #expect(TrainLoading(percentage: 72, level: .busy, quietestCoaches: ["7", "8"]).accessibilityText == "Busy, 72% full. Quietest: coaches 7 and 8")
    }

    @MainActor
    @Test func cardShowsHowBusyOnlyBeforeDeparture() throws {
        let at = { (hhmm: String) in RailTime.date("2026-11-07", at: hhmm)! }
        let journey = Journey.preview(from: ("VIC", "London Victoria"), to: ("CCH", "Chichester"), date: "2026-11-07", departs: "16:24", arrives: "18:12", platform: "15")
        let busy = TrainLoading(percentage: 72, level: .busy)

        journey.live = LiveSummary(state: .live, expectedDeparture: at("16:24"), isCancelled: false, stale: false, loading: busy)
        let before = JourneyCardModel(journey: journey, now: at("16:10"))
        #expect(before.busy == .busy)
        #expect(before.busy?.text == "Busy")
        #expect(before.status == "leaves in 14 min")

        journey.live = LiveSummary(state: .live, isCancelled: false, stale: false, loading: TrainLoading(percentage: 10, level: .quiet))
        #expect(JourneyCardModel(journey: journey, now: at("16:10")).busy?.text == "Quiet")

        journey.live = LiveSummary(state: .departed, actualDeparture: at("16:25"), isCancelled: false, stale: false, loading: busy)
        #expect(JourneyCardModel(journey: journey, now: at("16:40")).busy == nil)

        journey.live = LiveSummary(state: .cancelled, isCancelled: true, stale: false, loading: busy)
        #expect(JourneyCardModel(journey: journey, now: at("16:10")).busy == nil)

        journey.live = LiveSummary(state: .live, isCancelled: false, stale: false)
        #expect(JourneyCardModel(journey: journey, now: at("16:10")).busy == nil)
    }

    @Test func busyRowHidesOnceTheTrainHasLeftMyStation() throws {
        let journey = try fixture("journey-divides", as: ServerJourney.self)
        #expect(BusyDisplay.loading(status: journey.live, summary: nil)?.level == .moderate)
        var left = journey.live
        left.service?.actualDeparture = try Date("2026-11-07T16:25:00+00:00", strategy: .iso8601)
        #expect(BusyDisplay.loading(status: left, summary: nil) == nil)
        left = journey.live
        left.state = .departed
        #expect(BusyDisplay.loading(status: left, summary: nil) == nil)
        // The full status wins over the list's summary once loaded.
        var none = journey.live
        none.loading = nil
        #expect(BusyDisplay.loading(status: none, summary: LiveSummary(journey.live))?.level == .moderate)
    }

    @Test func divisionBannerText() throws {
        let division = try #require(try fixture("journey-divides", as: ServerJourney.self).live.divides)
        #expect(division.title == "Divides at Horsham")
        #expect(division.mine.map(\.destName) == ["Portsmouth Harbour"])
        #expect(division.accessibilityText == "Divides at Horsham. This train divides at Horsham; only some coaches go to Chichester. Your part to Portsmouth Harbour. Other part to Bognor Regis.")

        let noted = TrainDivision(atCrs: "HRH", atName: "Horsham", at: .now, portions: [
            DivisionPortion(destCrs: "PMH", destName: "Portsmouth Harbour", yours: true, note: "Front 4 coaches"),
        ], message: "This train divides at Horsham. Sit in the front 4 coaches for Chichester.")
        #expect(noted.accessibilityText.hasSuffix("Your part to Portsmouth Harbour, front 4 coaches."))
    }

    @Test func stationMessageStations() throws {
        let messages = try fixture("journey-divides", as: ServerJourney.self).stationMessages
        let from = (crs: "VIC", name: "London Victoria"), to = (crs: "CCH", name: "Chichester")
        #expect(messages[0].stationsText(from: from, to: to) == "At London Victoria")
        #expect(messages[1].stationsText(from: from, to: to) == nil)
        var both = messages[0]
        both.stations = ["VIC", "CCH"]
        #expect(both.stationsText(from: from, to: to) == "At London Victoria and Chichester")
        #expect(messages[0].symbol == "exclamationmark.triangle.fill")
        #expect(!messages[1].isProminent)
    }
}

/// Renders the journey screen's new panels, a card with how busy, and the
/// Live Activity with a division, in light and dark (written to the temporary
/// directory; the path is printed).
@MainActor
struct DarwinExtrasRenderTests {
    @Test func rendersTheBannerBusyPanelAndMessages() throws {
        let journey = Journey.previewDividing()
        let status = LiveStatus.previewDividing(for: journey)
        let attributes = TrainActivityAttributes(journeyId: journey.id, headcode: "1C46", operatorName: "Southern", fromCrs: "VIC", fromName: "London Victoria", toCrs: "CCH", toName: "Chichester")
        let state = TrainActivityAttributes.ContentState(
            state: .live, scheduledDeparture: journey.departsAt, scheduledArrival: journey.arrivesAt,
            platform: .init(number: "15", confirmed: true), divides: "Divides at Horsham · front 4 coaches"
        )
        let view = HStack(alignment: .top, spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(spacing: 16) {
                    JourneyCard(journey: journey)
                    JourneyNotices(journey: journey, status: status, notes: ["Delayed by a signalling problem"], stationMessages: StationMessage.previews)
                    TrainActivityLockScreenView(attributes: attributes, state: state)
                        .background(Color(.systemBackground).opacity(0.85), in: .rect(cornerRadius: 22))
                }
                .padding(16)
                .background(Color(.systemGroupedBackground))
                .environment(\.colorScheme, scheme)
                .frame(width: 402)
            }
        }
        .tint(Color.trainTeal)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let url = URL.temporaryDirectory.appending(path: "darwin-extras.png")
        try #require(image.pngData()).write(to: url)
        print("Darwin extras render: \(url.path)")
    }
}

extension DarwinExtrasRenderTests {
    /// The Lock Screen gives a Live Activity at most 160 pt: a division (two
    /// lines when it names the coaches) must still fit, on a narrow phone too.
    @Test(arguments: [340.0, 370.0])
    func lockScreenFitsWithADivision(width: Double) throws {
        let attributes = TrainActivityAttributes(journeyId: UUID(), headcode: "1C46", operatorName: "Southern", fromCrs: "VIC", fromName: "London Victoria", toCrs: "CCH", toName: "Chichester")
        let now = Date.now
        for departed in [false, true] {
            let state = TrainActivityAttributes.ContentState(
                state: departed ? .departed : .live, scheduledDeparture: now.addingTimeInterval(departed ? -600 : 600),
                actualDeparture: departed ? now.addingTimeInterval(-600) : nil, scheduledArrival: now.addingTimeInterval(6000),
                delayMinutes: 12, platform: .init(number: "15", confirmed: true), divides: "Divides at Haywards Heath · front 4 coaches"
            )
            let renderer = ImageRenderer(content: TrainActivityLockScreenView(attributes: attributes, state: state))
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            let height = try #require(renderer.uiImage).size.height
            print("Lock Screen with a division, \(Int(width)) pt wide\(departed ? ", departed" : ""): \(height) pt")
            #expect(height <= 160)
        }
    }
}

private final class ExtrasBundleToken {}
