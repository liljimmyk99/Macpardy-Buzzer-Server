//
//  PhoneDisconnectReportTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class PhoneDisconnectReportTests: XCTestCase {

    func testWatchdogAfterHiddenPageReadsPlainly() {
        let report = PhoneDisconnectReport(
            cause: .watchdog,
            connectedMs: 720_000,
            hiddenMs: 38_000,
            hiddenAtLoss: false,
            secondsSince: 41
        )
        XCTAssertEqual(
            report.summary,
            "previous connection lost 41s ago after 12m — the phone heard nothing from the Mac for 5s (watchdog); page was hidden for 38s (screen locked or app switched)"
        )
    }

    func testSocketCloseIncludesCodeAndReason() {
        let report = PhoneDisconnectReport(cause: .socketClose, closeCode: 1006, closeReason: "bye", hiddenMs: 0, hiddenAtLoss: false)
        XCTAssertEqual(
            report.summary,
            "previous connection lost — the socket closed (1006 abnormal closure) “bye”; page stayed visible"
        )
    }

    func testHiddenAtLossWins() {
        let report = PhoneDisconnectReport(cause: .socketError, hiddenMs: 5_000, hiddenAtLoss: true)
        XCTAssertEqual(
            report.summary,
            "previous connection lost — the socket reported an error; page was hidden when it was lost (hidden for 5s): screen locked or app switched"
        )
    }

    func testRemovedAndSessionEnded() {
        XCTAssertEqual(
            PhoneDisconnectReport(cause: .removed, secondsSince: 3).summary,
            "previous connection was removed by the host 3s ago"
        )
        XCTAssertEqual(
            PhoneDisconnectReport(cause: .sessionEnded).summary,
            "previous connection ended with the game session"
        )
    }

    func testEmptyReport() {
        XCTAssertTrue(PhoneDisconnectReport().isEmpty)
        XCTAssertFalse(PhoneDisconnectReport(hiddenAtLoss: false).isEmpty)
    }
}
