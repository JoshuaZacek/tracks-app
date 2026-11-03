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
        app.launchArguments = ["-uiTesting"]
        app.launch()

        XCTAssertTrue(app.staticTexts["No journeys yet"].waitForExistence(timeout: 5))
        app.buttons["Add journey"].firstMatch.tap()

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
        attachScreenshot(of: app, named: "Add journey: departures")
        departure.tap()

        // The sheet closes and the journey appears.
        let card = app.descendants(matching: .any).matching(identifier: "journeyCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.label.contains("from York to London Kings Cross"), card.label)
        attachScreenshot(of: app, named: "Journeys after adding")

        // Archive it: it moves to Past.
        card.swipeRight()
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["Past"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Upcoming"].exists || app.staticTexts["Live"].exists)
    }

    @MainActor
    func testSeededJourneysShowAllSections() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedJourneys"]
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
        app.launchArguments = ["-uiTesting", "-seedJourneys"]
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
        app.launchArguments = ["-uiTesting"]
        app.launch()

        app.buttons["Add journey"].firstMatch.tap()
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
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
