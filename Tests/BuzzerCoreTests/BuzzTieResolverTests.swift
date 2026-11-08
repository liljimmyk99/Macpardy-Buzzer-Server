//
//  BuzzTieResolverTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class BuzzTieResolverTests: XCTestCase {

    private let now = Date()

    private func buzz(score: Int) -> Buzz {
        Buzz(teamID: UUID(), receivedAt: now, score: score)
    }

    func testNoBuzzesHasNoWinner() {
        XCTAssertNil(BuzzTieResolver.winner(of: []))
    }

    func testSingleBuzzWins() {
        let only = buzz(score: 500)
        XCTAssertEqual(BuzzTieResolver.winner(of: [only]), only)
    }

    func testLowestScoreWins() {
        let low = buzz(score: -200)
        let winner = BuzzTieResolver.winner(of: [buzz(score: 400), low, buzz(score: 0)])
        XCTAssertEqual(winner, low)
    }

    func testEqualScoresUseInjectedRandomness() {
        let first = buzz(score: 100)
        let second = buzz(score: 100)
        let loser = buzz(score: 900)
        let buzzes = [first, loser, second]

        XCTAssertEqual(BuzzTieResolver.winner(of: buzzes, randomIndex: { _ in 0 }), first)
        XCTAssertEqual(BuzzTieResolver.winner(of: buzzes, randomIndex: { $0 - 1 }), second)
    }
}
