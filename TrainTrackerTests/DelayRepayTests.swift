import Foundation
import Testing
@testable import TrainTracker

/// Sprint 4: Delay Repay claims and sharing a journey. Decoding (with and
/// without the new fields), the claim card's text and estimate, what the
/// journey cache keeps, and the requests sent.
struct DelayRepayTests {
    private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle(for: DelayRepayBundleToken.self).url(forResource: name, withExtension: "json"))
        return try TracksClient.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TracksClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func date(_ iso: String) throws -> Date { try Date(iso, strategy: .iso8601) }

    private let band30 = DelayRepayBand(minMinutes: 30, maxMinutes: 59, singlePercent: 50, returnPercent: 25)

    private func claim(delay: Int? = 34, cancelled: Bool = false, band: DelayRepayBand?, claimed: Bool = false) -> DelayRepayClaim {
        DelayRepayClaim(
            operator: Operator(code: "GR", name: "LNER"), scheme: "DR30", minimumDelayMinutes: 30,
            delayMinutes: delay, cancelled: cancelled, band: band,
            actualArrival: cancelled ? nil : try? date("2026-11-03T12:01:00+00:00"),
            claimUrl: URL(string: "https://www.lner.co.uk/")!,
            ticketPricePence: nil, ticketType: nil, estimatePence: nil, claimed: claimed, claimedAt: nil
        )
    }

    // MARK: Decoding

    @Test func decodesAClaimAndAShare() throws {
        let journey = try fixture("journey-claim", as: ServerJourney.self)
        let claim = try #require(journey.claim)
        #expect(claim.operator.name == "LNER")
        #expect(claim.scheme == "DR30")
        #expect(claim.minimumDelayMinutes == 30)
        #expect(claim.delayMinutes == 34)
        #expect(!claim.cancelled)
        #expect(claim.band == band30)
        #expect(claim.actualArrival == (try date("2026-11-03T12:01:00+00:00")))
        #expect(claim.claimUrl.absoluteString == "https://www.lner.co.uk/")
        #expect(claim.ticketPricePence == nil)
        #expect(claim.ticketType == nil)
        #expect(!claim.claimed)

        let share = try #require(journey.share)
        #expect(share.url.absoluteString == "https://tracks-api.joshuazacek.com/s/Ym6MmcFMbytrGvSl2tOwBg")
        #expect(share.expiresAt == (try date("2026-11-03T17:27:00+00:00")))
    }

    /// Servers (and journeys cached) from before Sprint 4 have neither.
    @Test func olderJourneysDecodeWithoutClaimOrShare() throws {
        for name in ["journey", "journey-divides", "journey-no-extras"] {
            let journey = try fixture(name, as: ServerJourney.self)
            #expect(journey.claim == nil)
            #expect(journey.share == nil)
            #expect(journey.prefs.delayRepay == nil)
        }
        let prefs = try decode(NotificationPrefs.self, #"{"delays":true,"platforms":true,"cancellations":true,"departure":true,"arrival":true,"delayThresholdMinutes":5,"liveActivity":true}"#)
        #expect(prefs.delayRepay)
    }

    @Test func decodesATicketTypeAndUnknownOnes() throws {
        #expect(try decode(TicketType.self, #""single""#) == .single)
        #expect(try decode(TicketType.self, #""return""#) == .return)
        #expect(try decode(TicketType.self, #""season""#) == .unknown)
    }

    // MARK: The claim card

    @Test func summarisesTheClaim() {
        #expect(claim(band: band30).summary == "34 min late · LNER pays 50% of a single fare")
        let twoHours = DelayRepayBand(minMinutes: 120, maxMinutes: nil, singlePercent: 100, returnPercent: 100)
        #expect(claim(delay: 125, band: twoHours).summary == "125 min late · LNER pays 100% of a return fare")
        #expect(claim(delay: nil, cancelled: true, band: nil).summary == "Cancelled · claim from LNER for how late you got there, or a refund if you didn't travel")
    }

    @Test func estimatesThePayoutAsTheServerDoes() {
        let c = claim(band: band30)
        #expect(c.estimatePence(price: 1999, type: .single) == 999)
        #expect(c.estimatePence(price: 4000, type: .return) == 1000)
        #expect(c.estimatePence(price: nil, type: .single) == nil)
        #expect(c.estimatePence(price: 4000, type: nil) == nil)
        #expect(claim(delay: nil, cancelled: true, band: nil).estimatePence(price: 4000, type: .single) == nil)
        let twoHours = claim(delay: 130, band: DelayRepayBand(minMinutes: 120, maxMinutes: nil, singlePercent: 100, returnPercent: 100))
        #expect(twoHours.estimatePence(price: 4000, type: .return) == 4000)
    }

    @Test func readsAndWritesPounds() {
        #expect(Pence.parse("45.20") == 4520)
        #expect(Pence.parse("£45.2") == 4520)
        #expect(Pence.parse(" 45 ") == 4500)
        #expect(Pence.parse("0.5") == 50)
        #expect(Pence.parse("45,20") == 4520)
        #expect(Pence.parse("") == nil)
        #expect(Pence.parse("abc") == nil)
        #expect(Pence.parse("-3") == nil)
        #expect(Pence.parse("1.234") == nil)
        #expect(Pence.text(4520) == "45.20")
        #expect(Pence.format(4520) == "£45.20")
        #expect(Pence.format(5) == "£0.05")
    }

    @Test func copiesTheDetailsAClaimFormAsksFor() throws {
        let server = try fixture("journey-claim", as: ServerJourney.self)
        let journey = Journey(server)
        let text = try #require(journey.claim).details(for: journey)
        #expect(text == """
        Date: Tuesday 3 November 2026
        From: London Kings Cross (KGX)
        To: York (YRK)
        Booked departure: 09:33
        Booked arrival: 11:27
        Actual arrival: 12:01 (34 min late)
        Train: 1N04, LNER
        """)
        let cancelled = claim(delay: nil, cancelled: true, band: nil).details(for: journey)
        #expect(cancelled.contains("Actual arrival: cancelled"))
    }

    // MARK: The journey cache

    @Test func journeyKeepsTheClaimAndShareAndHidesAClaimedCard() throws {
        let server = try fixture("journey-claim", as: ServerJourney.self)
        let journey = Journey(server)
        #expect(journey.claim?.delayMinutes == 34)
        #expect(journey.share?.url.lastPathComponent == "Ym6MmcFMbytrGvSl2tOwBg")
        #expect(journey.showsClaimCard)

        var claimed = server
        claimed.claim?.claimed = true
        claimed.share = nil
        journey.update(from: claimed)
        #expect(!journey.showsClaimCard)
        #expect(journey.share == nil)

        let plain = try fixture("journey", as: ServerJourney.self)
        let other = Journey(plain)
        #expect(!other.showsClaimCard)
    }

    @Test func canShareUntilArrivedOrSixHoursAfterTheScheduledArrival() throws {
        let journey = Journey(try fixture("journey-claim", as: ServerJourney.self))
        let arrival = journey.arrivesAt
        #expect(journey.canShare(now: arrival.addingTimeInterval(6 * 3600 - 60)))
        #expect(!journey.canShare(now: arrival.addingTimeInterval(6 * 3600)))
        journey.live?.state = .arrived
        #expect(!journey.canShare(now: arrival))
        journey.live?.state = .departed
        journey.archivedAt = .now
        #expect(!journey.canShare(now: arrival))
    }

    // MARK: Requests

    @Test func encodesClaimUpdates() throws {
        func json(_ body: UpdateJourneyRequest) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return String(decoding: try encoder.encode(body), as: UTF8.self)
        }
        #expect(try json(UpdateJourneyRequest(claim: ClaimUpdate(ticketPricePence: .value(4520), ticketType: .value(.single)))) ==
            #"{"claim":{"ticketPricePence":4520,"ticketType":"single"}}"#)
        #expect(try json(UpdateJourneyRequest(claim: ClaimUpdate(ticketPricePence: .null))) == #"{"claim":{"ticketPricePence":null}}"#)
        #expect(try json(UpdateJourneyRequest(claim: ClaimUpdate(claimed: true))) == #"{"claim":{"claimed":true}}"#)
    }

    @Test func journeyPrefsCarryTheDelayRepayAlert() {
        var prefs = JourneyPrefs()
        #expect(prefs.applied(over: .defaults).delayRepay)
        prefs.delayRepay = false
        #expect(!prefs.applied(over: .defaults).delayRepay)
        if case .value(false)? = prefs.replacingAll.delayRepay {} else { Issue.record("replacingAll should send delayRepay") }
    }
}

private final class DelayRepayBundleToken {}
