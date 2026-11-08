//
//  AttemptRateLimiterTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class AttemptRateLimiterTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000)

    private func makeLimiter() -> AttemptRateLimiter {
        AttemptRateLimiter(maxAttempts: 3, window: 10, lockout: 30)
    }

    func testAttemptsUpToLimitAreAllowed() {
        var limiter = makeLimiter()
        for i in 0..<3 {
            XCTAssertFalse(limiter.record("a", now: start.addingTimeInterval(Double(i))))
        }
        XCTAssertFalse(limiter.isBlocked("a", now: start.addingTimeInterval(3)))
    }

    func testExceedingLimitBlocks() {
        var limiter = makeLimiter()
        for i in 0..<3 { limiter.record("a", now: start.addingTimeInterval(Double(i))) }
        XCTAssertTrue(limiter.record("a", now: start.addingTimeInterval(3)))
        XCTAssertTrue(limiter.isBlocked("a", now: start.addingTimeInterval(4)))
    }

    func testBlockLiftsAfterLockout() {
        var limiter = makeLimiter()
        for i in 0..<4 { limiter.record("a", now: start.addingTimeInterval(Double(i))) }
        XCTAssertTrue(limiter.isBlocked("a", now: start.addingTimeInterval(20)))
        XCTAssertFalse(limiter.isBlocked("a", now: start.addingTimeInterval(34)))
        XCTAssertFalse(limiter.record("a", now: start.addingTimeInterval(34)))
    }

    func testOldAttemptsFallOutOfWindow() {
        var limiter = makeLimiter()
        for i in 0..<3 { limiter.record("a", now: start.addingTimeInterval(Double(i))) }
        XCTAssertFalse(limiter.record("a", now: start.addingTimeInterval(60)))
    }

    func testKeysAreIndependent() {
        var limiter = makeLimiter()
        for i in 0..<4 { limiter.record("a", now: start.addingTimeInterval(Double(i))) }
        XCTAssertTrue(limiter.isBlocked("a", now: start.addingTimeInterval(5)))
        XCTAssertFalse(limiter.isBlocked("b", now: start.addingTimeInterval(5)))
    }
}
