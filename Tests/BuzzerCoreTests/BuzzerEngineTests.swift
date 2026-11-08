//
//  BuzzerEngineTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class BuzzerEngineTests: XCTestCase {

    private let teamA = UUID()
    private let teamB = UUID()
    private let teamC = UUID()
    private var all: Set<UUID> { [teamA, teamB, teamC] }

    private func buzz(_ team: UUID, score: Int = 0) -> Buzz {
        Buzz(teamID: team, receivedAt: Date(), score: score)
    }

    private func armedEngine() -> BuzzerEngine {
        var engine = BuzzerEngine()
        engine.apply(.armed)
        return engine
    }

    func testBuzzWhileDisabledIsTooEarly() {
        var engine = BuzzerEngine()
        XCTAssertEqual(engine.buzz(buzz(teamA)), .tooEarly)
        XCTAssertEqual(engine.phoneState(for: teamA), .waiting)
    }

    func testDailyDoubleCannotBePressed() {
        var engine = BuzzerEngine()
        engine.apply(.unavailable)
        XCTAssertEqual(engine.buzz(buzz(teamA)), .ignored)
        XCTAssertEqual(engine.phoneState(for: teamA), .unavailable)
    }

    func testFirstBuzzOpensWindowAndWinsWhenAlone() {
        var engine = armedEngine()
        XCTAssertEqual(engine.buzz(buzz(teamA)), .windowStarted)
        XCTAssertEqual(engine.phoneState(for: teamA), .pressed)
        XCTAssertEqual(engine.phoneState(for: teamB), .armed)

        XCTAssertEqual(engine.closeWindow()?.teamID, teamA)
        XCTAssertEqual(engine.firstBuzzTeamID, teamA)
        XCTAssertEqual(engine.phoneState(for: teamA), .first)
        XCTAssertEqual(engine.phoneState(for: teamB), .waiting)
    }

    func testBuzzesInsideWindowGoThroughTieResolver() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA, score: 800))
        XCTAssertEqual(engine.buzz(buzz(teamB, score: 200)), .addedToWindow)
        XCTAssertEqual(engine.closeWindow()?.teamID, teamB)
    }

    func testBuzzAfterWindowIsIgnored() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA))
        engine.closeWindow()
        XCTAssertEqual(engine.buzz(buzz(teamB)), .ignored)
        XCTAssertEqual(engine.firstBuzzTeamID, teamA)
    }

    func testDuplicateBuzzFromSameTeamIsIgnored() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA))
        XCTAssertEqual(engine.buzz(buzz(teamA)), .ignored)
    }

    func testWrongAnswerLocksTeamOutAndRearmsOthers() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA))
        engine.closeWindow()

        engine.markWrong(teamID: teamA, eligibleTeamIDs: all)

        XCTAssertNil(engine.firstBuzzTeamID)
        XCTAssertEqual(engine.phoneState(for: teamA), .lockedOut)
        XCTAssertEqual(engine.phoneState(for: teamB), .armed)
        XCTAssertEqual(engine.buzz(buzz(teamA)), .ignored)
        XCTAssertEqual(engine.buzz(buzz(teamB)), .windowStarted)
    }

    func testStaysDisabledWhenEveryTeamIsLockedOut() {
        var engine = armedEngine()
        for team in [teamA, teamB] {
            _ = engine.buzz(buzz(team))
            engine.closeWindow()
            engine.markWrong(teamID: team, eligibleTeamIDs: [teamA, teamB])
        }
        XCTAssertEqual(engine.phase, .disabled(pressable: true))
    }

    func testWrongForAnotherTeamKeepsCurrentAnswerer() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA))
        engine.closeWindow()
        engine.markWrong(teamID: teamB, eligibleTeamIDs: all)
        XCTAssertEqual(engine.firstBuzzTeamID, teamA)
        XCTAssertEqual(engine.phoneState(for: teamB), .lockedOut)
    }

    func testCorrectAnswerDisablesBuzzers() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA))
        engine.closeWindow()
        engine.markCorrect()
        XCTAssertNil(engine.firstBuzzTeamID)
        XCTAssertEqual(engine.buzz(buzz(teamB)), .tooEarly)
    }

    func testModeChangeClearsLockoutsAndBuzzes() {
        var engine = armedEngine()
        _ = engine.buzz(buzz(teamA))
        engine.closeWindow()
        engine.markWrong(teamID: teamA, eligibleTeamIDs: all)

        engine.apply(.disabled)
        engine.apply(.armed)

        XCTAssertEqual(engine.phoneState(for: teamA), .armed)
        XCTAssertEqual(engine.buzz(buzz(teamA)), .windowStarted)
    }
}
