//
//  BuzzerRoomTests.swift
//  BuzzerCoreTests
//
//  The room's rules with fake phones and a test clock (#101): no network, no sleeps.
//

import Foundation
import XCTest
@testable import BuzzerCore

final class BuzzerRoomTests: XCTestCase {

    private let pin = "ABC123"
    private let red = BuzzerTeam(id: UUID(), name: "Red", color: "#FF0000", claimed: false)
    private let blue = BuzzerTeam(id: UUID(), name: "Blue", color: "#0000FF", claimed: false)

    private var scheduler: TestScheduler!
    private var logger: RecordingBuzzerLogger!
    private var room: BuzzerRoom!

    override func setUp() async throws {
        scheduler = TestScheduler()
        logger = RecordingBuzzerLogger()
        room = BuzzerRoom(joinCode: pin, logger: logger, scheduler: scheduler, randomIndex: { _ in 0 })
        await room.updateTeams([red, blue])
    }

    // MARK: - Helpers

    /// A phone that connected and sent `join`.
    private func joinedPhone(
        remoteKey: String = "192.168.1.10",
        device: String? = nil,
        code: String? = nil,
        version: Int = BuzzerConstants.protocolVersion
    ) async -> FakeConnection {
        let phone = FakeConnection(remoteKey: remoteKey)
        await room.connect(phone)
        await room.receive(.join(code: code ?? pin, version: version, diag: nil, device: device), from: phone.id)
        return phone
    }

    /// A joined phone holding `team`.
    private func phone(holding team: BuzzerTeam, remoteKey: String = "192.168.1.10", device: String? = nil) async -> FakeConnection {
        let phone = await joinedPhone(remoteKey: remoteKey, device: device)
        await room.receive(.claim(teamID: team.id), from: phone.id)
        return phone
    }

    private func teams(claimed: Set<UUID> = []) -> [BuzzerTeam] {
        [red, blue].map { BuzzerTeam(id: $0.id, name: $0.name, color: $0.color, claimed: claimed.contains($0.id)) }
    }

    private func buzzerStates(_ phone: FakeConnection) -> [BuzzerPhoneState] {
        phone.messages.compactMap { if case .buzzerState(let state) = $0 { state } else { nil } }
    }

    // MARK: - Join

    func testRightPINIsAcceptedWithTheTeams() async {
        let phone = await joinedPhone()

        XCTAssertEqual(phone.messages, [.joinAccepted(teams: teams())])
        XCTAssertFalse(phone.isClosed)
        let connected = await room.isConnected(phone.id)
        XCTAssertTrue(connected)
        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.filter { if case .connectedCount = $0 { true } else { false } }, [
            .connectedCount(0),   // socket open, not joined
            .connectedCount(1),   // joined
        ])
    }

    func testWrongPINIsRejectedAndTheConnectionCloses() async {
        let phone = await joinedPhone(code: "WRONG1")

        XCTAssertEqual(phone.sent, [.init(message: .joinRejected(.invalidCode), closeAfterSending: true)])
        let connected = await room.isConnected(phone.id)
        XCTAssertFalse(connected)
        XCTAssertTrue(logger.lines.contains { $0.message.contains("join rejected (invalidCode)") })
    }

    func testOldPageVersionIsRejected() async {
        let phone = await joinedPhone(version: BuzzerConstants.minimumProtocolVersion - 1)

        XCTAssertEqual(phone.sent, [.init(message: .joinRejected(.unsupportedVersion), closeAfterSending: true)])
        let connected = await room.isConnected(phone.id)
        XCTAssertFalse(connected)
    }

    func testOldestSupportedPageVersionStillJoins() async {
        let phone = await joinedPhone(version: BuzzerConstants.minimumProtocolVersion)
        XCTAssertEqual(phone.messages, [.joinAccepted(teams: teams())])
    }

    func testTooManyWrongPINsBlockTheAddressUntilTheLockoutEnds() async {
        for _ in 0..<BuzzerConstants.maxCodeAttempts {
            let phone = await joinedPhone(code: "WRONG1")
            XCTAssertEqual(phone.messages, [.joinRejected(.invalidCode)])
        }
        let limited = await joinedPhone(code: "WRONG1")
        XCTAssertEqual(limited.messages, [.joinRejected(.rateLimited)])

        // Even the right PIN is refused while blocked…
        let blocked = await joinedPhone()
        XCTAssertEqual(blocked.messages, [.joinRejected(.rateLimited)])
        // …but another address isn't affected.
        let neighbour = await joinedPhone(remoteKey: "192.168.1.11")
        XCTAssertEqual(neighbour.messages, [.joinAccepted(teams: teams())])

        await scheduler.advance(by: BuzzerConstants.rateLimitLockout + 1)
        let later = await joinedPhone()
        XCTAssertEqual(later.messages, [.joinAccepted(teams: teams())])
    }

    func testMessagesBeforeJoinAreIgnored() async {
        let phone = FakeConnection()
        await room.connect(phone)
        await room.receive(.claim(teamID: red.id), from: phone.id)
        await room.receive(.buzz, from: phone.id)

        XCTAssertEqual(phone.messages, [])
    }

    func testUndecodableTextIsIgnoredAndLogged() async {
        let phone = await joinedPhone()
        phone.clear()

        await room.receive(text: Data("{\"type\":\"nope\"}".utf8), from: phone.id)

        XCTAssertEqual(phone.messages, [])
        let connected = await room.isConnected(phone.id)
        XCTAssertTrue(connected)
        XCTAssertTrue(logger.lines.contains { $0.level == .warning && $0.message.hasPrefix("Ignored an undecodable message") })
    }

    func testJSONTextIsDecoded() async {
        let phone = FakeConnection()
        await room.connect(phone)
        let join = "{\"type\":\"join\",\"code\":\"\(pin)\",\"version\":\(BuzzerConstants.protocolVersion)}"

        await room.receive(text: Data(join.utf8), from: phone.id)

        XCTAssertEqual(phone.messages, [.joinAccepted(teams: teams())])
    }

    // MARK: - Claims

    func testClaimingAFreeTeam() async {
        let phone = await joinedPhone()
        phone.clear()

        await room.receive(.claim(teamID: red.id), from: phone.id)

        XCTAssertEqual(phone.messages, [
            .claimAccepted(teamID: red.id),
            .buzzerState(.waiting),
            .teams(teams(claimed: [red.id])),
        ])
        let events = await room.stopAndCollectEvents()
        XCTAssertTrue(events.contains(.claimedTeams([red.id])))
    }

    func testATeamHeldByAnotherPhoneIsRefused() async {
        _ = await phone(holding: red)
        let second = await joinedPhone(remoteKey: "192.168.1.11")
        second.clear()

        await room.receive(.claim(teamID: red.id), from: second.id)

        XCTAssertEqual(second.messages, [
            .teams(teams(claimed: [red.id])),
            .claimRejected(reason: .taken),
        ])
    }

    func testAnUnknownTeamIsRefused() async {
        let phone = await joinedPhone()
        phone.clear()

        await room.receive(.claim(teamID: UUID()), from: phone.id)

        XCTAssertEqual(phone.messages.last, .claimRejected(reason: .invalidTeam))
    }

    func testClaimsAreRateLimitedPerAddress() async {
        let phone = await joinedPhone()
        for _ in 0..<BuzzerConstants.maxClaimAttempts {
            await room.receive(.claim(teamID: red.id), from: phone.id)
        }
        phone.clear()

        await room.receive(.claim(teamID: blue.id), from: phone.id)

        XCTAssertEqual(phone.messages, [.claimRejected(reason: .rateLimited)])
    }

    func testDisconnectFreesTheTeam() async {
        let phone = await phone(holding: red)
        let watcher = await joinedPhone(remoteKey: "192.168.1.11")
        watcher.clear()

        await room.disconnect(phone.id, reason: .connectionEnded)

        XCTAssertEqual(watcher.messages, [.teams(teams())])
        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.last { if case .claimedTeams = $0 { true } else { false } }, .claimedTeams([]))
    }

    func testRejoiningDeviceGetsItsTeamBack() async {
        let first = await phone(holding: red, device: "tab-1")
        await room.disconnect(first.id, reason: .connectionEnded)

        let second = await joinedPhone(device: "tab-1")

        XCTAssertEqual(second.messages.prefix(2), [
            .joinAccepted(teams: teams()),
            .claimAccepted(teamID: red.id),
        ])
        XCTAssertTrue(logger.lines.contains { $0.message.hasPrefix("Team restored on rejoin") })
    }

    func testRejoiningDeviceTakesItsTeamFromItsOlderConnection() async {
        let old = await phone(holding: red, device: "tab-1")

        let new = await joinedPhone(device: "tab-1")

        XCTAssertTrue(new.messages.contains(.claimAccepted(teamID: red.id)))
        XCTAssertEqual(old.closeReason, .replacedByNewConnection)
        let oldConnected = await room.isConnected(old.id)
        XCTAssertFalse(oldConnected)
    }

    func testAnotherDeviceDoesNotGetTheTeamRestored() async {
        let first = await phone(holding: red, device: "tab-1")
        await room.disconnect(first.id, reason: .connectionEnded)
        _ = await phone(holding: red, remoteKey: "192.168.1.11", device: "tab-2")

        let back = await joinedPhone(device: "tab-1")

        // Silent: the phone just picks a team again.
        XCTAssertEqual(back.messages, [.joinAccepted(teams: teams(claimed: [red.id]))])
    }

    func testRemovedPhoneIsToldAndItsTeamIsFreed() async {
        let phone = await phone(holding: red, device: "tab-1")
        phone.clear()

        await room.removePhone(forTeam: red.id)

        XCTAssertEqual(phone.sent, [.init(message: .removed, closeAfterSending: true)])
        // The host removed it, so rejoining doesn't bring the team back.
        let back = await joinedPhone(device: "tab-1")
        XCTAssertEqual(back.messages, [.joinAccepted(teams: teams())])
    }

    func testRenamedTeamIsSentToPhonesAndUsedInLogs() async {
        let phone = await phone(holding: red)
        phone.clear()
        let renamed = BuzzerTeam(id: red.id, name: "Crimson", color: red.color, claimed: false)

        await room.updateTeams([renamed, blue])

        XCTAssertEqual(phone.messages, [.teams([
            BuzzerTeam(id: red.id, name: "Crimson", color: red.color, claimed: true),
            BuzzerTeam(id: blue.id, name: "Blue", color: blue.color, claimed: false),
        ])])
        await room.receive(.buzz, from: phone.id)
        XCTAssertEqual(logger.lines.last?.team, "Crimson")
    }

    func testRemovedTeamLosesItsClaim() async {
        _ = await phone(holding: red)

        await room.updateTeams([blue])

        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.last { if case .claimedTeams = $0 { true } else { false } }, .claimedTeams([]))
    }

    // MARK: - Heartbeat

    func testJoinedPhonesArePingedOnTheHeartbeat() async {
        await room.start()
        let phone = await joinedPhone()
        phone.clear()

        await scheduler.advance(by: BuzzerConstants.pingInterval)

        XCTAssertEqual(phone.messages, [.ping])
    }

    func testPhoneThatStopsAnsweringIsEvictedAndItsTeamFreed() async {
        await room.start()
        let phone = await phone(holding: red)

        await scheduler.advance(by: BuzzerConstants.heartbeatTTL + BuzzerConstants.pingInterval)

        guard case .heartbeatTimeout = phone.closeReason else {
            return XCTFail("Expected a heartbeat timeout, got \(String(describing: phone.closeReason))")
        }
        let connected = await room.isConnected(phone.id)
        XCTAssertFalse(connected)
        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.last { if case .claimedTeams = $0 { true } else { false } }, .claimedTeams([]))
    }

    func testPongsKeepAPhoneConnected() async {
        await room.start()
        let phone = await joinedPhone()

        for second in 1...Int(BuzzerConstants.heartbeatTTL * 2) {
            await scheduler.advance(by: 1)
            // Alternate the message and the WebSocket frame.
            if second.isMultiple(of: 2) {
                await room.receive(.pong, from: phone.id)
            } else {
                await room.receivedPong(from: phone.id)
            }
        }

        XCTAssertFalse(phone.isClosed)
        let connected = await room.isConnected(phone.id)
        XCTAssertTrue(connected)
    }

    func testSocketThatNeverJoinsIsClosed() async {
        await room.start()
        let phone = FakeConnection()
        await room.connect(phone)

        await scheduler.advance(by: BuzzerConstants.joinTTL + BuzzerConstants.pingInterval)

        guard case .neverJoined = phone.closeReason else {
            return XCTFail("Expected neverJoined, got \(String(describing: phone.closeReason))")
        }
        XCTAssertEqual(phone.messages, [])
    }

    func testNoHeartbeatBeforeStart() async {
        _ = await joinedPhone()
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - Buzzing

    func testBuzzBeforeTheBuzzersAreArmedIsTooEarly() async {
        let phone = await phone(holding: red)
        phone.clear()

        await room.receive(.buzz, from: phone.id)

        XCTAssertEqual(phone.messages, [.buzzerState(.tooEarly)])
    }

    func testFirstBuzzWinsAfterTheTieWindow() async {
        let redPhone = await phone(holding: red)
        let bluePhone = await phone(holding: blue, remoteKey: "192.168.1.11")
        await room.setBuzzerMode(.armed)

        await room.receive(.buzz, from: redPhone.id)
        XCTAssertEqual(buzzerStates(redPhone).last, .pressed)

        await scheduler.advance(by: BuzzerConstants.tieWindow)

        XCTAssertEqual(buzzerStates(redPhone).last, .first)
        XCTAssertEqual(buzzerStates(bluePhone).last, .waiting)
        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.last { if case .firstBuzz = $0 { true } else { false } }, .firstBuzz(red.id))
    }

    func testTieGoesToTheLowerScore() async {
        let redPhone = await phone(holding: red)
        let bluePhone = await phone(holding: blue, remoteKey: "192.168.1.11")
        await room.updateScores([red.id: 800, blue.id: 200])
        await room.setBuzzerMode(.armed)

        await room.receive(.buzz, from: redPhone.id)
        await scheduler.advance(by: BuzzerConstants.tieWindow / 2)
        await room.receive(.buzz, from: bluePhone.id)
        await scheduler.advance(by: BuzzerConstants.tieWindow)

        XCTAssertEqual(buzzerStates(bluePhone).last, .first)
        XCTAssertEqual(buzzerStates(redPhone).last, .waiting)
        XCTAssertTrue(logger.lines.contains { $0.message.contains("tie between 'Red', 'Blue' broken") })
    }

    func testBuzzAfterTheTieWindowDoesNotCount() async {
        let redPhone = await phone(holding: red)
        let bluePhone = await phone(holding: blue, remoteKey: "192.168.1.11")
        await room.updateScores([red.id: 800, blue.id: 200])
        await room.setBuzzerMode(.armed)

        await room.receive(.buzz, from: redPhone.id)
        await scheduler.advance(by: BuzzerConstants.tieWindow)
        await room.receive(.buzz, from: bluePhone.id)

        XCTAssertEqual(buzzerStates(redPhone).last, .first)
    }

    func testChangingModeCancelsTheTieWindow() async {
        let redPhone = await phone(holding: red)
        await room.setBuzzerMode(.armed)
        await room.receive(.buzz, from: redPhone.id)

        await room.setBuzzerMode(.disabled)
        await scheduler.advance(by: BuzzerConstants.tieWindow)

        XCTAssertEqual(buzzerStates(redPhone).last, .waiting)
        XCTAssertEqual(scheduler.pendingCount, 0)
        let events = await room.stopAndCollectEvents()
        XCTAssertFalse(events.contains(.firstBuzz(red.id)))
    }

    func testWrongAnswerLocksTheTeamOutAndRearmsTheOthers() async {
        let redPhone = await phone(holding: red)
        let bluePhone = await phone(holding: blue, remoteKey: "192.168.1.11")
        await room.setBuzzerMode(.armed)
        await room.receive(.buzz, from: redPhone.id)
        await scheduler.advance(by: BuzzerConstants.tieWindow)

        await room.markWrong(teamID: red.id)

        XCTAssertEqual(buzzerStates(redPhone).last, .lockedOut)
        XCTAssertEqual(buzzerStates(bluePhone).last, .armed)

        await room.markCorrect()
        XCTAssertEqual(buzzerStates(bluePhone).last, .waiting)
    }

    // MARK: - Response timer

    func testResponseTimerIsBroadcastAndStopped() async {
        let phone = await joinedPhone()
        phone.clear()

        await room.setResponseTimer(teamID: red.id, seconds: 10)
        await room.setResponseTimer(teamID: nil, seconds: 0)
        await room.setResponseTimer(teamID: nil, seconds: 0)

        XCTAssertEqual(phone.messages, [
            .responseTimer(ResponseTimerInfo(teamID: red.id, remaining: 10, total: 10)),
            .responseTimerStopped,
        ])
    }

    func testPhoneClaimingMidCountdownGetsTheTimeLeft() async {
        await room.setResponseTimer(teamID: red.id, seconds: 10)
        await scheduler.advance(by: 4)

        let phone = await phone(holding: blue)

        XCTAssertTrue(phone.messages.contains(.responseTimer(ResponseTimerInfo(teamID: red.id, remaining: 6, total: 10))))
    }

    // MARK: - Final wagers

    func testWagerFlow() async {
        let phone = await phone(holding: red)
        phone.clear()

        await room.openWagering(limits: [red.id: 1000, blue.id: 0], wagers: [:])
        XCTAssertEqual(phone.messages, [.wagerInfo(WagerInfo(eligible: true, max: 1000, wager: nil))])

        await room.receive(.submitWager(amount: 2000), from: phone.id)
        XCTAssertEqual(phone.lastMessage, .wagerRejected(.overMax))

        await room.receive(.submitWager(amount: 600), from: phone.id)
        XCTAssertEqual(phone.lastMessage, .wagerLocked(wager: 600))

        await room.receive(.submitWager(amount: 700), from: phone.id)
        XCTAssertEqual(phone.lastMessage, .wagerRejected(.locked))

        await room.setWager(teamID: red.id, amount: 5000)
        XCTAssertEqual(phone.lastMessage, .wagerLocked(wager: 1000))

        await room.closeWagering()
        XCTAssertEqual(phone.lastMessage, .wagerClosed)

        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.filter { if case .wager = $0 { true } else { false } }, [
            .wager(WagerSubmission(teamID: red.id, amount: 600)),
        ])
    }

    func testIneligibleTeamIsToldItCannotWager() async {
        let phone = await phone(holding: blue)
        phone.clear()

        await room.openWagering(limits: [red.id: 1000, blue.id: -200], wagers: [:])
        await room.receive(.submitWager(amount: 0), from: phone.id)

        XCTAssertEqual(phone.messages, [
            .wagerInfo(WagerInfo(eligible: false, max: 0, wager: nil)),
            .wagerRejected(.notEligible),
        ])
    }

    func testPhoneClaimingDuringWageringGetsItsWagerScreen() async {
        await room.openWagering(limits: [red.id: 1000], wagers: [red.id: 300])

        let phone = await phone(holding: red)

        XCTAssertTrue(phone.messages.contains(.wagerInfo(WagerInfo(eligible: true, max: 1000, wager: 300))))
    }

    // MARK: - Final answers

    func testAnswerFlowNeverLogsTheAnswer() async {
        let phone = await phone(holding: red)
        phone.clear()

        await room.setAnswering(.open, answers: [:])
        XCTAssertEqual(phone.lastMessage, .answerInfo(AnswerInfo(open: true, answer: nil, maxLength: FinalAnswerBook.maxLength)))

        await room.receive(.submitAnswer(answer: "  What is Paris?\n"), from: phone.id)
        XCTAssertEqual(phone.lastMessage, .answerSaved(answer: "What is Paris?"))

        await room.receive(.submitAnswer(answer: "   "), from: phone.id)
        XCTAssertEqual(phone.lastMessage, .answerRejected(.empty))

        await room.setAnswering(.locked, answers: [red.id: "What is Paris?"])
        XCTAssertEqual(phone.lastMessage, .answerInfo(AnswerInfo(open: false, answer: "What is Paris?", maxLength: FinalAnswerBook.maxLength)))

        await room.receive(.submitAnswer(answer: "What is Rome?"), from: phone.id)
        XCTAssertEqual(phone.lastMessage, .answerRejected(.notOpen))

        await room.setAnswering(.closed, answers: [:])
        XCTAssertEqual(phone.lastMessage, .answerClosed)

        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.filter { if case .answer = $0 { true } else { false } }, [
            .answer(AnswerSubmission(teamID: red.id, answer: "What is Paris?")),
        ])
        XCTAssertFalse(logger.lines.contains { $0.message.contains("Paris") || $0.message.contains("Rome") })
        XCTAssertTrue(logger.lines.contains { $0.message.contains("submitAnswer (length 17)") })
    }

    func testClosingAnsweringThatWasNeverOpenSendsNothing() async {
        let phone = await phone(holding: red)
        phone.clear()

        await room.setAnswering(.closed, answers: [:])

        XCTAssertEqual(phone.messages, [])
    }

    // MARK: - Page events

    func testKnownPageEventsAreLoggedAndUnknownOnesDropped() async {
        let phone = await joinedPhone()

        await room.receive(.uiEvent(event: "pageHidden", at: nil), from: phone.id)
        await room.receive(.uiEvent(event: "somethingElse", at: nil), from: phone.id)

        let phoneLines = logger.lines.filter { $0.kind == .phone }.map(\.message)
        XCTAssertTrue(phoneLines.contains { $0.hasSuffix(": page hidden") })
        XCTAssertFalse(phoneLines.contains { $0.contains("somethingElse") })
        XCTAssertEqual(phone.messages, [.joinAccepted(teams: teams())])
    }

    func testPageEventsAreRateLimitedPerPhone() async {
        let phone = await joinedPhone()

        for _ in 0..<(BuzzerConstants.maxUIEvents + 5) {
            await room.receive(.uiEvent(event: "pageVisible", at: nil), from: phone.id)
        }

        let logged = logger.lines.filter { $0.message.hasSuffix("page visible") }
        XCTAssertEqual(logged.count, BuzzerConstants.maxUIEvents)
    }

    func testJoinWithADisconnectReportLogsIt() async {
        let phone = FakeConnection()
        await room.connect(phone)
        let report = PhoneDisconnectReport(cause: .watchdog, closeCode: 1006)

        await room.receive(.join(code: pin, version: BuzzerConstants.protocolVersion, diag: report, device: nil), from: phone.id)

        XCTAssertTrue(logger.lines.contains { $0.level == .notice && $0.message.hasPrefix("Phone report (192.168.1.10 #") })
    }

    // MARK: - Stop

    func testStopEndsTheSessionForJoinedPhonesAndClosesTheRest() async {
        await room.start()
        let joined = await phone(holding: red)
        joined.clear()
        let waiting = FakeConnection(remoteKey: "192.168.1.11")
        await room.connect(waiting)

        let closed = await room.stop()

        XCTAssertEqual(closed, 2)
        XCTAssertEqual(joined.sent, [.init(message: .sessionEnded, closeAfterSending: true)])
        XCTAssertEqual(waiting.messages, [])
        XCTAssertEqual(waiting.closeReason, .serverStopped)
        XCTAssertEqual(scheduler.pendingCount, 0)
        let joinedConnected = await room.isConnected(joined.id)
        XCTAssertFalse(joinedConnected)
    }

    func testStopFinishesTheEventStream() async {
        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events, [.claimedTeams([])])
    }

    func testConnectionsAfterStopAreClosed() async {
        await room.stop()
        let late = FakeConnection()

        await room.connect(late)

        XCTAssertEqual(late.closeReason, .serverStopped)
        let connected = await room.isConnected(late.id)
        XCTAssertFalse(connected)
    }

    func testFailureIsReported() async {
        await room.reportFailure("Port in use")
        let events = await room.stopAndCollectEvents()
        XCTAssertEqual(events.last, .failed("Port in use"))
    }
}
