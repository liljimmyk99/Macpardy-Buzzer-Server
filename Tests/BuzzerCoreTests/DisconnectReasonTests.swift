//
//  DisconnectReasonTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class DisconnectReasonTests: XCTestCase {

    func testEveryReasonHasADistinctDescription() {
        let reasons: [DisconnectReason] = [
            .phoneClosed(code: 1001),
            .phoneClosed(code: nil),
            .connectionEnded,
            .networkError("Connection reset by peer (POSIX 54)"),
            .heartbeatTimeout(sinceLastPong: 6.1),
            .neverJoined(after: 5.4),
            .invalidFrame,
            .oversizedMessage,
            .joinRejected(.invalidCode),
            .removedByHost,
            .serverStopped,
            .replacedByNewConnection,
        ]
        let descriptions = reasons.map(\.description)
        XCTAssertEqual(Set(descriptions).count, reasons.count)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
    }

    func testDescriptionsCarryTheirDetails() {
        XCTAssertEqual(
            DisconnectReason.phoneClosed(code: 1001).description,
            "phone closed the connection (1001 going away: tab closed, reloaded or navigated away)"
        )
        XCTAssertTrue(DisconnectReason.heartbeatTimeout(sinceLastPong: 6.14).description.hasPrefix("no pong for 6.1s"))
        XCTAssertEqual(DisconnectReason.networkError("boom").description, "network error: boom")
        XCTAssertEqual(DisconnectReason.joinRejected(.rateLimited).description, "join rejected (rateLimited)")
        XCTAssertEqual(DisconnectReason.removedByHost.description, "removed by the host")
        XCTAssertEqual(DisconnectReason.serverStopped.description, "the buzzer server stopped")
    }

    func testExpectedEndingsAreInfoAndProblemsAreWarnings() {
        XCTAssertEqual(DisconnectReason.removedByHost.logLevel, .info)
        XCTAssertEqual(DisconnectReason.serverStopped.logLevel, .info)
        XCTAssertEqual(DisconnectReason.replacedByNewConnection.logLevel, .info)
        XCTAssertEqual(DisconnectReason.phoneClosed(code: 1001).logLevel, .info)
        XCTAssertEqual(DisconnectReason.phoneClosed(code: nil).logLevel, .warning)
        XCTAssertEqual(DisconnectReason.heartbeatTimeout(sinceLastPong: 6).logLevel, .warning)
        XCTAssertEqual(DisconnectReason.networkError("x").logLevel, .warning)
    }
}
