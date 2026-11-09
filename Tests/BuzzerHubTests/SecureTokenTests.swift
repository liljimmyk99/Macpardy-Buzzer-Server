//
//  SecureTokenTests.swift
//  BuzzerHubTests
//

import XCTest
@testable import BuzzerHub

final class SecureTokenTests: XCTestCase {

    func testGeneratedTokensAreHexAndDistinct() {
        let tokens = (0..<50).map { _ in SecureToken.generate() }
        XCTAssertEqual(Set(tokens).count, 50)
        for token in tokens {
            XCTAssertEqual(token.count, 48)
            XCTAssertTrue(token.allSatisfy(\.isHexDigit))
        }
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(SecureToken.constantTimeEquals("abcdef", "abcdef"))
        XCTAssertTrue(SecureToken.constantTimeEquals("", ""))
        XCTAssertFalse(SecureToken.constantTimeEquals("abcdef", "abcdeg"))
        XCTAssertFalse(SecureToken.constantTimeEquals("abcdef", "abcde"))
        XCTAssertFalse(SecureToken.constantTimeEquals("abcde", "abcdef"))
        XCTAssertFalse(SecureToken.constantTimeEquals("", "a"))
        // A prefix padded with what the comparison pads with must still differ.
        XCTAssertFalse(SecureToken.constantTimeEquals("abc", "abc\u{0}"))
    }
}
