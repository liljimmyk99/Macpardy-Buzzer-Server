//
//  BuzzerWebPageTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerWebPage

final class BuzzerWebPageTests: XCTestCase {

    func testPageIsBundled() throws {
        let html = try XCTUnwrap(BuzzerWebPage.html)
        let text = try XCTUnwrap(String(data: html, encoding: .utf8))
        XCTAssertTrue(text.contains("<html"))
    }

    /// Behind an HTTPS reverse proxy the page must open `wss://` on the page's
    /// own host and port (#103).
    func testPageBuildsTheWebSocketURLFromTheLocation() throws {
        let text = try XCTUnwrap(BuzzerWebPage.html.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(text.contains(#"location.protocol === "https:" ? "wss:" : "ws:""#))
        XCTAssertTrue(text.contains("${location.host}/ws"))
    }
}
