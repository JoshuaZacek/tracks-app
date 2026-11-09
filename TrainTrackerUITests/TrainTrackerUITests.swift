//
//  TrainTrackerUITests.swift
//  TrainTrackerUITests
//
//  Drives the real app against the backend running on this Mac (`npm run dev`
//  in UK-Train-Tracker-Project). `-uiTesting` gives the app an empty in-memory
//  store so saved journeys are untouched.
//

import CoreLocation
import XCTest

final class TrainTrackerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddJourneyFromTheTimetable() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting"]
        app.launch()

        XCTAssertTrue(app.staticTexts["No journeys yet"].waitForExistence(timeout: 15)) // first launch after install is slow
        app.buttons["Add train"].firstMatch.tap()

        // Choose York, by typing its name.
        app.buttons["fromStation"].tap()
        app.searchFields.firstMatch.typeText("york")
        let york = app.buttons["station-YRK"]
        XCTAssertTrue(york.waitForExistence(timeout: 10))
        york.tap()

        // Choose London Kings Cross, by CRS code.
        app.buttons["toStation"].tap()
        app.searchFields.firstMatch.typeText("kgx")
        let kingsCross = app.buttons["station-KGX"]
        XCTAssertTrue(kingsCross.waitForExistence(timeout: 10))
        kingsCross.tap()

        // Save the first train listed.
        let departure = app.buttons.matching(identifier: "departure").firstMatch
        XCTAssertTrue(departure.waitForExistence(timeout: 15))
        attachScreenshot(of: app, named: "Add train: departures")
        departure.tap()

        // The confirmation offers to repeat it; Done closes the sheet and the journey appears.
        XCTAssertTrue(app.buttons["repeatJourney"].waitForExistence(timeout: 15))
        attachScreenshot(of: app, named: "Add train: added")
        app.buttons["addedDone"].tap()
        let card = app.descendants(matching: .any).matching(identifier: "journeyCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.label.contains("from York to London Kings Cross"), card.label)
        attachScreenshot(of: app, named: "Journeys after adding")
    }

    @MainActor
    func testSeededJourneysShowAllSections() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting", "-seedJourneys"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Upcoming"].waitForExistence(timeout: 30))
        // Whether a Live section exists depends on the time of day (none at 2 a.m.);
        // Live sorting is covered by JourneySectionsTests with fixed times.
        // Past sits at the bottom of the list.
        let past = app.staticTexts["Past"]
        for _ in 0..<8 where !past.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(past.exists)
        attachScreenshot(of: app, named: "Past section")
    }

    /// Real trains: needs some running (daytime). Opens the journey that's under way
    /// and checks the train is shown between stops.
    @MainActor
    func testLiveJourneyOpensWithTheTrainOnTheMap() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting", "-seedJourneys"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Live"].waitForExistence(timeout: 30), "no trains running right now?")
        sleep(3) // let live summaries arrive
        attachScreenshot(of: app, named: "Journeys with live data")

        app.descendants(matching: .any).matching(identifier: "journeyCard").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trainIndicator"].waitForExistence(timeout: 20))
        sleep(3) // map tiles
        attachScreenshot(of: app, named: "Journey detail")
        app.swipeUp()
        attachScreenshot(of: app, named: "Journey detail: stops")
    }

    /// Simulates being at King's Cross, allowing location if asked.
    @MainActor
    func testNearbyStationsListedWithoutSearching() throws {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 51.5320, longitude: -0.1233))
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting"]
        app.launch()

        app.buttons["Add train"].firstMatch.tap()
        app.buttons["fromStation"].tap()
        let kingsCross = app.buttons["station-KGX"]
        if !kingsCross.waitForExistence(timeout: 3) {
            // Location not allowed yet: ask, and accept the system prompt.
            app.buttons["Find stations near me"].tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssertTrue(kingsCross.waitForExistence(timeout: 15))
        attachScreenshot(of: app, named: "Nearby stations")
        kingsCross.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "departure").firstMatch.waitForExistence(timeout: 15))
    }

    /// Kept in the test results (Xcode's Report navigator), pass or fail.
    /// Turns notifications on from Settings (accepting the system prompt), then
    /// taps an alert shaped like the server's and expects its journey to open.
    @MainActor
    func testAlertOpensItsJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting", "-seedJourneys", "-allowNotificationPrompt", "-debugAlert"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "journeyCard").firstMatch.waitForExistence(timeout: 30))

        app.buttons["settings"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let enable = app.buttons["enableNotifications"]
        if enable.waitForExistence(timeout: 5) {
            enable.tap()
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssertTrue(app.switches["Delays"].waitForExistence(timeout: 10))
        sleep(1)
        attachScreenshot(of: app, named: "Settings")
        app.buttons["Done"].tap()

        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Test alert'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "no alert shown")
        banner.tap()
        XCTAssertTrue(app.buttons["journeyAlerts"].waitForExistence(timeout: 15), "the journey didn't open")
        attachScreenshot(of: app, named: "Opened from an alert")
    }

    /// Starts a Live Activity from a running journey's alerts sheet.
    @MainActor
    func testStartingALiveActivity() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting", "-seedJourneys"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Live"].waitForExistence(timeout: 30), "no trains running right now?")
        app.descendants(matching: .any).matching(identifier: "journeyCard").firstMatch.tap()

        app.buttons["journeyAlerts"].tap()
        let start = app.buttons["startLiveActivity"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "Journey alerts")
        start.tap()
        XCTAssertTrue(app.buttons["End Live Activity"].waitForExistence(timeout: 10))
        sleep(15) // let the push token reach the server
        attachScreenshot(of: app, named: "Live Activity started")
        app.buttons["Done"].tap()
    }

    /// UI tests use the development server on this Mac (`npm run dev` in
    /// ~/Desktop/tracks-server), never the deployed one.
    /// `-sampleClaim` puts a sample Delay Repay claim on finished journeys. Opens the
    /// finished one: the claim card, then "Claimed" hides it. The share button is
    /// on every journey that hasn't finished.
    @MainActor
    func testClaimCardOnAFinishedJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting", "-seedJourneys", "-sampleClaim"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Upcoming"].waitForExistence(timeout: 30))
        sleep(2) // the sample claims arrive with the first refresh
        // Past sits at the bottom of the (lazy) list.
        let past = app.staticTexts["Past"]
        for _ in 0..<8 where !past.isHittable { app.swipeUp() }
        XCTAssertTrue(past.exists)
        // The finished journey's card says there's a claim (VoiceOver reads the card as one).
        let claimable = NSPredicate(format: "identifier == 'journeyCard' AND label CONTAINS 'Delay Repay'")
        let card = app.descendants(matching: .any).matching(claimable).firstMatch
        if (past.value as? String) == "Collapsed" { past.tap() } // Past may be folded away
        for _ in 0..<4 where !card.exists { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let claimCard = app.descendants(matching: .any)["claimCard"].firstMatch
        XCTAssertTrue(claimCard.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["You may be able to claim"].exists)
        XCTAssertTrue(app.buttons["copyClaimDetails"].exists)
        XCTAssertTrue(app.links["openClaimForm"].exists || app.buttons["openClaimForm"].exists)
        attachScreenshot(of: app, named: "Claim card")

        let toggle = app.switches["claimedToggle"].firstMatch
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() // the switch itself, not its label
        XCTAssertTrue(app.staticTexts["Claimed"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "Claimed")
    }

    @MainActor
    func testShareButtonOnAnUpcomingJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.localServer + ["-uiTesting", "-seedJourneys"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Upcoming"].waitForExistence(timeout: 30))
        app.descendants(matching: .any).matching(identifier: "journeyCard").firstMatch.tap()
        let share = app.buttons["shareJourney"]
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        share.tap()
        // The share sheet, once the server has made the link.
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "Share sheet")
    }

    private static let localServer = ["-tracksBaseURL", "http://localhost:3000"]

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
