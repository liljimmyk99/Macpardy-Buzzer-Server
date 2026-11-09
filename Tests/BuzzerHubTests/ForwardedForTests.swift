//
//  ForwardedForTests.swift
//  BuzzerHubTests
//

import XCTest
@testable import BuzzerHub

final class ForwardedForTests: XCTestCase {

    func testIgnoredUnlessTrusted() {
        XCTAssertEqual(ForwardedFor.clientAddress(header: "198.51.100.7", peer: "172.18.0.2", trust: false), "172.18.0.2")
    }

    func testUsesTheEntryTheProxyAdded() {
        XCTAssertEqual(ForwardedFor.clientAddress(header: "198.51.100.7", peer: "172.18.0.2", trust: true), "198.51.100.7")
        // The client can send its own header; only the last entry is the proxy's.
        XCTAssertEqual(ForwardedFor.clientAddress(header: "1.2.3.4, 198.51.100.7", peer: "172.18.0.2", trust: true), "198.51.100.7")
        XCTAssertEqual(ForwardedFor.clientAddress(header: "2001:db8::1", peer: "172.18.0.2", trust: true), "2001:db8::1")
    }

    func testFallsBackToThePeerForMissingOrOddHeaders() {
        XCTAssertEqual(ForwardedFor.clientAddress(header: nil, peer: "172.18.0.2", trust: true), "172.18.0.2")
        XCTAssertEqual(ForwardedFor.clientAddress(header: "", peer: "172.18.0.2", trust: true), "172.18.0.2")
        XCTAssertEqual(ForwardedFor.clientAddress(header: "1.2.3.4, ", peer: "172.18.0.2", trust: true), "172.18.0.2")
        XCTAssertEqual(ForwardedFor.clientAddress(header: "evil\nlog line", peer: "172.18.0.2", trust: true), "172.18.0.2")
        XCTAssertEqual(ForwardedFor.clientAddress(header: String(repeating: "1", count: 100), peer: "172.18.0.2", trust: true), "172.18.0.2")
    }
}
