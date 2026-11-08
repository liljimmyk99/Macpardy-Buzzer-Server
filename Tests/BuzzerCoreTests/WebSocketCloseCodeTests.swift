//
//  WebSocketCloseCodeTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class WebSocketCloseCodeTests: XCTestCase {

    func testCloseCodeIsReadBigEndianFromThePayload() {
        XCTAssertEqual(WebSocketCloseCode.fromPayload(Data([0x03, 0xE9])), 1001)
        XCTAssertEqual(WebSocketCloseCode.fromPayload(Data([0x03, 0xE8]) + Data("bye".utf8)), 1000)
    }

    func testShortCloseFramesHaveNoCode() {
        XCTAssertNil(WebSocketCloseCode.fromPayload(Data()))
        XCTAssertNil(WebSocketCloseCode.fromPayload(Data([0x03])))
    }

    func testCloseCodeDescriptions() {
        XCTAssertEqual(WebSocketCloseCode.describe(nil), "no status code")
        XCTAssertEqual(WebSocketCloseCode.describe(1001), "1001 going away: tab closed, reloaded or navigated away")
        XCTAssertEqual(WebSocketCloseCode.describe(4321), "code 4321")
    }
}
