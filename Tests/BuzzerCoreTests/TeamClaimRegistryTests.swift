//
//  TeamClaimRegistryTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class TeamClaimRegistryTests: XCTestCase {

    private let teamA = UUID()
    private let teamB = UUID()
    private let phone1 = UUID()
    private let phone2 = UUID()
    private var valid: Set<UUID> { [teamA, teamB] }

    func testClaimFreeTeam() {
        var registry = TeamClaimRegistry()
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid), .claimed)
        XCTAssertTrue(registry.isClaimed(teamA))
        XCTAssertEqual(registry.claimedTeamIDs, [teamA])
    }

    func testSecondPhoneIsBlockedFromClaimedTeam() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone2, validTeamIDs: valid), .taken)
        XCTAssertEqual(registry.sessionID(for: teamA), phone1)
    }

    func testSamePhoneClaimingAgainIsHarmless() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid), .alreadyHeld)
    }

    func testUnknownTeamIsInvalid() {
        var registry = TeamClaimRegistry()
        XCTAssertEqual(registry.claim(teamID: UUID(), sessionID: phone1, validTeamIDs: valid), .invalidTeam)
        XCTAssertTrue(registry.claimedTeamIDs.isEmpty)
    }

    func testPhoneHoldsOneTeamAtATime() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        XCTAssertEqual(registry.claim(teamID: teamB, sessionID: phone1, validTeamIDs: valid), .claimed)
        XCTAssertFalse(registry.isClaimed(teamA))
        XCTAssertTrue(registry.isClaimed(teamB))
    }

    func testReleaseFreesSlotForRejoin() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        XCTAssertEqual(registry.release(sessionID: phone1), teamA)
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone2, validTeamIDs: valid), .claimed)
    }

    func testSweepFreesClaimsOfDeadSessions() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        _ = registry.claim(teamID: teamB, sessionID: phone2, validTeamIDs: valid)
        let freed = registry.sweep(liveSessionIDs: [phone2])
        XCTAssertEqual(freed, [teamA])
        XCTAssertFalse(registry.isClaimed(teamA))
        XCTAssertTrue(registry.isClaimed(teamB))
    }

    func testRemoveFreesTeamAndReturnsHolder() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        XCTAssertEqual(registry.remove(teamID: teamA), phone1)
        XCTAssertFalse(registry.isClaimed(teamA))
        XCTAssertNil(registry.remove(teamID: teamA))
    }

    func testPruneDropsClaimsOnDeletedTeams() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        _ = registry.claim(teamID: teamB, sessionID: phone2, validTeamIDs: valid)
        XCTAssertEqual(registry.prune(validTeamIDs: [teamB]), [phone1])
        XCTAssertEqual(registry.claimedTeamIDs, [teamB])
    }

    // MARK: - Device ids (#84)

    private let phoneA = "device-a"
    private let phoneB = "device-b"

    func testSameDeviceTakesItsTeamBackFromAnOlderSession() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        XCTAssertEqual(
            registry.claim(teamID: teamA, sessionID: phone2, deviceID: phoneA, validTeamIDs: valid),
            .reclaimed(fromSessionID: phone1)
        )
        XCTAssertEqual(registry.sessionID(for: teamA), phone2)
        XCTAssertNil(registry.teamID(for: phone1))
    }

    func testOtherDeviceOrNoDeviceCannotTakeAHeldTeam() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone2, deviceID: phoneB, validTeamIDs: valid), .taken)
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone2, validTeamIDs: valid), .taken)
        XCTAssertEqual(registry.sessionID(for: teamA), phone1)
    }

    func testPhoneWithoutDeviceIsNeverTakenOver() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, validTeamIDs: valid)
        XCTAssertEqual(registry.claim(teamID: teamA, sessionID: phone2, deviceID: phoneA, validTeamIDs: valid), .taken)
    }

    func testDeviceGetsItsLastTeamRestoredAfterItsSessionEnds() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamB, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        registry.release(sessionID: phone1)
        XCTAssertEqual(registry.teamToRestore(forDevice: phoneA, validTeamIDs: valid), teamB)
        XCTAssertNil(registry.teamToRestore(forDevice: phoneB, validTeamIDs: valid))
    }

    func testRestoreIsOfferedWhileTheSameDeviceStillHoldsTheTeam() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        XCTAssertEqual(registry.teamToRestore(forDevice: phoneA, validTeamIDs: valid), teamA)
    }

    func testNoRestoreWhenAnotherPhoneTookTheTeam() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        registry.release(sessionID: phone1)
        _ = registry.claim(teamID: teamA, sessionID: phone2, deviceID: phoneB, validTeamIDs: valid)
        XCTAssertNil(registry.teamToRestore(forDevice: phoneA, validTeamIDs: valid))
    }

    func testNoRestoreForADeletedTeam() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        registry.release(sessionID: phone1)
        XCTAssertNil(registry.teamToRestore(forDevice: phoneA, validTeamIDs: [teamB]))
    }

    func testHostRemovalForgetsTheDevicesTeam() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        registry.remove(teamID: teamA)
        XCTAssertNil(registry.teamToRestore(forDevice: phoneA, validTeamIDs: valid))
    }

    func testSwitchingTeamsUpdatesTheTeamToRestore() {
        var registry = TeamClaimRegistry()
        _ = registry.claim(teamID: teamA, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        _ = registry.claim(teamID: teamB, sessionID: phone1, deviceID: phoneA, validTeamIDs: valid)
        XCTAssertEqual(registry.teamToRestore(forDevice: phoneA, validTeamIDs: valid), teamB)
    }
}
