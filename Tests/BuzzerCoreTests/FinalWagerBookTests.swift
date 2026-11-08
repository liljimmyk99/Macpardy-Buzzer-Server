//
//  FinalWagerBookTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class FinalWagerBookTests: XCTestCase {

    private let rich = UUID()
    private let broke = UUID()

    private func openBook() -> FinalWagerBook {
        var book = FinalWagerBook()
        book.open(limits: [rich: 1200, broke: 0], wagers: [:])
        return book
    }

    func testRejectsWhenClosed() {
        var book = FinalWagerBook()
        XCTAssertEqual(book.submit(teamID: rich, amount: 100), .rejected(.notOpen))
    }

    func testAcceptsWagerUpToMax() {
        var book = openBook()
        XCTAssertEqual(book.submit(teamID: rich, amount: 1200), .accepted(1200))
    }

    func testRejectsAboveMaxAndNegative() {
        var book = openBook()
        XCTAssertEqual(book.submit(teamID: rich, amount: 1201), .rejected(.overMax))
        XCTAssertEqual(book.submit(teamID: rich, amount: -1), .rejected(.negative))
        XCTAssertNil(book.info(for: rich)?.wager)
    }

    func testSecondSubmitIsLockedButHostCanEdit() {
        var book = openBook()
        _ = book.submit(teamID: rich, amount: 300)
        XCTAssertEqual(book.submit(teamID: rich, amount: 400), .rejected(.locked))
        XCTAssertEqual(book.hostSet(teamID: rich, amount: 400), 400)
        XCTAssertEqual(book.info(for: rich)?.wager, 400)
    }

    func testHostSetIsClampedToMax() {
        var book = openBook()
        XCTAssertEqual(book.hostSet(teamID: rich, amount: 99_999), 1200)
    }

    func testExcludedTeamCannotWager() {
        var book = openBook()
        XCTAssertEqual(book.submit(teamID: broke, amount: 0), .rejected(.notEligible))
        XCTAssertNil(book.hostSet(teamID: broke, amount: 10))
        XCTAssertEqual(book.info(for: broke), WagerInfo(eligible: false, max: 0, wager: nil))
    }

    func testClearingAllowsNewSubmission() {
        var book = openBook()
        _ = book.submit(teamID: rich, amount: 300)
        book.hostClear(teamID: rich)
        XCTAssertEqual(book.submit(teamID: rich, amount: 500), .accepted(500))
    }

    func testReopenKeepsExistingWagersOfEligibleTeams() {
        var book = FinalWagerBook()
        book.open(limits: [rich: 1200, broke: 0], wagers: [rich: 700, broke: 50])
        XCTAssertEqual(book.info(for: rich)?.wager, 700)
        XCTAssertNil(book.info(for: broke)?.wager)
    }

    func testCloseForgetsEverything() {
        var book = openBook()
        book.close()
        XCTAssertFalse(book.isOpen)
        XCTAssertNil(book.info(for: rich))
    }

    // MARK: - Wire format

    func testSubmitWagerDecodes() throws {
        let json = Data(#"{"type":"submitWager","amount":250}"#.utf8)
        guard case .submitWager(let amount) = try JSONDecoder().decode(ClientMessage.self, from: json)
        else { return XCTFail("expected submitWager") }
        XCTAssertEqual(amount, 250)
    }

    func testWagerMessagesEncode() throws {
        func json(_ m: ServerMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any] ?? [:]
        }
        let info = try json(.wagerInfo(WagerInfo(eligible: true, max: 900, wager: nil)))
        XCTAssertEqual(info["type"] as? String, "wagerInfo")
        let payload = info["payload"] as? [String: Any]
        XCTAssertEqual(payload?["max"] as? Int, 900)
        XCTAssertEqual(payload?["eligible"] as? Bool, true)
        XCTAssertNil(payload?["wager"])

        let rejected = try json(.wagerRejected(.overMax))
        XCTAssertEqual((rejected["payload"] as? [String: Any])?["reason"] as? String, "overMax")
        let locked = try json(.wagerLocked(wager: 5))
        XCTAssertEqual((locked["payload"] as? [String: Any])?["wager"] as? Int, 5)
        XCTAssertEqual(try json(.wagerClosed)["type"] as? String, "wagerClosed")
    }
}
