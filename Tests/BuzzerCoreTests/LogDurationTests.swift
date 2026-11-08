//
//  LogDurationTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class LogDurationTests: XCTestCase {

    func testDurationFormatting() {
        XCTAssertEqual(LogDuration.format(0), "0s")
        XCTAssertEqual(LogDuration.format(41), "41s")
        XCTAssertEqual(LogDuration.format(720), "12m")
        XCTAssertEqual(LogDuration.format(723), "12m 3s")
        XCTAssertEqual(LogDuration.format(3_900), "1h 5m")
        XCTAssertEqual(LogDuration.format(7_200), "2h")
        XCTAssertEqual(LogDuration.seconds(6.14), "6.1s")
        XCTAssertEqual(LogDuration.seconds(90), "1m 30s")
    }
}
