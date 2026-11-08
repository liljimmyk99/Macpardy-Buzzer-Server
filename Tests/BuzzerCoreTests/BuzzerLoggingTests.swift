//
//  BuzzerLoggingTests.swift
//  BuzzerCoreTests
//

import Foundation
import Synchronization
import XCTest
@testable import BuzzerCore

/// Records every line, for checking what package code logged.
final class RecordingBuzzerLogger: BuzzerLogging {

    struct Line: Equatable {
        let level: BuzzerLogLevel
        let message: String
        let kind: BuzzerLogKind
        let team: String?
        let remote: String?
    }

    private let storage = Mutex<[Line]>([])

    var lines: [Line] { storage.withLock { $0 } }

    func log(_ level: BuzzerLogLevel, _ message: String, kind: BuzzerLogKind, team: String?, remote: String?) {
        storage.withLock { $0.append(Line(level: level, message: message, kind: kind, team: team, remote: remote)) }
    }
}

final class BuzzerLoggingTests: XCTestCase {

    private struct Labelled: Equatable, BuzzerLogDescribable {
        let text: String
        var logDescription: String { text }
    }

    func testLevelHelpersLogPlainLinesWithTeamAndRemote() {
        let logger = RecordingBuzzerLogger()
        logger.info("Phone joined", team: "Blue", remote: "192.168.1.5")
        logger.warning("Heartbeat timeout")
        XCTAssertEqual(logger.lines, [
            .init(level: .info, message: "Phone joined", kind: .plain, team: "Blue", remote: "192.168.1.5"),
            .init(level: .warning, message: "Heartbeat timeout", kind: .plain, team: nil, remote: nil),
        ])
    }

    func testVerboseHelpersAreDebugWithTheirKind() {
        let logger = RecordingBuzzerLogger()
        logger.state("tie window closed")
        logger.phone("buzz", team: "Red", remote: "10.0.0.2")
        XCTAssertEqual(logger.lines.map(\.level), [.debug, .debug])
        XCTAssertEqual(logger.lines.map(\.kind), [.state, .phone])
        XCTAssertEqual(logger.lines.last?.remote, "10.0.0.2")
    }

    func testChangeDescribesBothValuesAndTheReason() {
        let logger = RecordingBuzzerLogger()
        logger.change("BuzzerEngine.phase", from: "armed", to: "windowOpen", reason: "first buzz", team: "Red")
        logger.change("Room.connectedCount", from: 2, to: 3)
        logger.change("Room.answering", from: Labelled?.none, to: Labelled(text: "Team 2 'Blue'"))
        XCTAssertEqual(logger.lines.map(\.message), [
            "BuzzerEngine.phase: 'armed' → 'windowOpen' (first buzz)",
            "Room.connectedCount: 2 → 3",
            "Room.answering: none → Team 2 'Blue'",
        ])
        XCTAssertEqual(logger.lines.first?.team, "Red")
        XCTAssertTrue(logger.lines.allSatisfy { $0.kind == .state && $0.level == .debug })
    }

    func testChangeToTheSameValueLogsNothing() {
        let logger = RecordingBuzzerLogger()
        logger.change("Room.connectedCount", from: 2, to: 2)
        XCTAssertTrue(logger.lines.isEmpty)
    }

    func testKindPrefixesMatchTheAppsVerboseLog() {
        XCTAssertEqual(BuzzerLogKind.plain.prefix, "")
        XCTAssertEqual(BuzzerLogKind.state.prefix, "state: ")
        XCTAssertEqual(BuzzerLogKind.phone.prefix, "phone: ")
    }

    func testLevelsAreOrderedBySeverity() {
        XCTAssertEqual(BuzzerLogLevel.allCases.sorted(), [.debug, .info, .notice, .warning, .error])
    }
}
