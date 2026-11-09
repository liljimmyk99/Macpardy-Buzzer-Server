//
//  BuzzerHubTests.swift
//  BuzzerHubTests
//
//  The self-hosted server's rooms (#103) with fake connections and a test
//  clock: host auth and versions, PIN routing, limits, rate limits, and the
//  host grace period with resume.
//

import BuzzerCore
import BuzzerHostProtocol
import Foundation
import Synchronization
import XCTest
@testable import BuzzerHub

final class BuzzerHubTests: XCTestCase {

    private let token = "correct-horse-battery-staple"
    private let red = BuzzerTeam(id: UUID(), name: "Red", color: "#FF0000", claimed: false)
    private let blue = BuzzerTeam(id: UUID(), name: "Blue", color: "#0000FF", claimed: false)

    private var scheduler: TestScheduler!
    private var logger: RecordingLogger!
    private var hub: BuzzerHub!
    /// PINs handed out in order; then random ones.
    private var codes: CodeQueue!

    override func setUp() async throws {
        scheduler = TestScheduler()
        logger = RecordingLogger()
        codes = CodeQueue(["AAAAAA", "BBBBBB", "CCCCCC", "DDDDDD"])
        await makeHub()
    }

    override func tearDown() async throws {
        await hub.stop()
    }

    private func makeHub(_ configure: (inout ServerConfiguration) -> Void = { _ in }) async {
        var configuration = ServerConfiguration(hostToken: token)
        configuration.gracePeriod = 45
        configure(&configuration)
        let codes = codes!
        hub = BuzzerHub(
            configuration: configuration,
            logger: logger,
            scheduler: scheduler,
            makeJoinCode: { codes.next() },
            randomIndex: { _ in 0 }
        )
        await hub.start()
    }

    // MARK: - Helpers

    private func send(_ command: HostCommand, from host: FakeHostConnection) async throws {
        await hub.hostReceived(text: try JSONEncoder().encode(command), from: host.id)
    }

    /// A Mac that connected and sent `hello`.
    private func connectHost(
        token: String? = nil,
        version: Int = BuzzerHostConstants.hostProtocolVersion,
        resumeToken: String? = nil,
        remoteKey: String = "203.0.113.5"
    ) async throws -> FakeHostConnection {
        let host = FakeHostConnection(remoteKey: remoteKey)
        await hub.hostConnected(host)
        try await send(.hello(HostHello(token: token ?? self.token, version: version, resumeToken: resumeToken, client: "test")), from: host)
        return host
    }

    /// A Mac with an open room and both teams pushed.
    private func openRoom(remoteKey: String = "203.0.113.5") async throws -> (FakeHostConnection, RoomOpened) {
        let host = try await connectHost(remoteKey: remoteKey)
        let opened = try XCTUnwrap(host.roomOpened)
        try await send(.updateTeams([red, blue]), from: host)
        return (host, opened)
    }

    private func joinMessage(_ code: String, version: Int = BuzzerConstants.protocolVersion) -> Data {
        Data(#"{"type":"join","code":"\#(code)","version":\#(version)}"#.utf8)
    }

    /// A phone that connected and sent `join` with `code`.
    private func joinPhone(_ code: String, remoteKey: String = "198.51.100.7", version: Int = BuzzerConstants.protocolVersion) async -> FakeConnection {
        let phone = FakeConnection(remoteKey: remoteKey)
        await hub.phoneConnected(phone)
        await hub.phoneReceived(text: joinMessage(code, version: version), from: phone.id)
        return phone
    }

    private func claim(_ team: BuzzerTeam, by phone: FakeConnection) async {
        await hub.phoneReceived(text: Data(#"{"type":"claim","teamID":"\#(team.id.uuidString)"}"#.utf8), from: phone.id)
    }

    private func buzzerStates(_ phone: FakeConnection) -> [BuzzerPhoneState] {
        phone.messages.compactMap { if case .buzzerState(let state) = $0 { state } else { nil } }
    }

    private func joinRejection(_ phone: FakeConnection) -> JoinRejectReason? {
        phone.messages.lazy.compactMap { if case .joinRejected(let reason) = $0 { reason } else { nil } }.first
    }

    // MARK: - Host authentication and versions

    func testHelloOpensARoomWithAPINAndResumeToken() async throws {
        let host = try await connectHost()

        let opened = try XCTUnwrap(host.roomOpened)
        XCTAssertEqual(opened.code, "AAAAAA")
        XCTAssertFalse(opened.resumed)
        XCTAssertFalse(opened.resumeToken.isEmpty)
        XCTAssertEqual(opened.gracePeriod, 45)
        XCTAssertEqual(opened.hostProtocolVersion, BuzzerHostConstants.hostProtocolVersion)
        XCTAssertFalse(host.isClosed)
        let rooms = await hub.roomCount
        XCTAssertEqual(rooms, 1)
    }

    func testWrongTokenIsRejectedAndClosed() async throws {
        let host = try await connectHost(token: "correct-horse-battery-stapl")

        XCTAssertEqual(host.errorCode, .badToken)
        XCTAssertNil(host.roomOpened)
        XCTAssertTrue(host.isClosed)
        let rooms = await hub.roomCount
        XCTAssertEqual(rooms, 0)
    }

    func testEmptyTokenIsRejected() async throws {
        let host = try await connectHost(token: "")
        XCTAssertEqual(host.errorCode, .badToken)
    }

    func testRepeatedWrongTokensLockOutTheAddressEvenWithTheRightToken() async throws {
        for _ in 0..<BuzzerHostConstants.maxTokenAttempts {
            let host = try await connectHost(token: "wrong-token-wrong-token")
            XCTAssertEqual(host.errorCode, .badToken)
        }
        let limited = try await connectHost(token: "wrong-token-wrong-token")
        XCTAssertEqual(limited.errorCode, .rateLimited)

        let blocked = try await connectHost()
        XCTAssertEqual(blocked.errorCode, .rateLimited)
        XCTAssertNil(blocked.roomOpened)

        let elsewhere = try await connectHost(remoteKey: "192.0.2.99")
        XCTAssertNotNil(elsewhere.roomOpened, "another address isn't affected")

        await scheduler.advance(by: BuzzerHostConstants.tokenLockout + 1)
        let later = try await connectHost()
        XCTAssertNotNil(later.roomOpened, "the lockout ends")
    }

    func testUnsupportedHostVersionIsRejectedWithTheSupportedRange() async throws {
        let host = try await connectHost(version: BuzzerHostConstants.hostProtocolVersion + 1)

        guard case .error(let error) = try XCTUnwrap(host.sent.last) else { return XCTFail("expected an error") }
        XCTAssertEqual(error.code, .unsupportedVersion)
        XCTAssertEqual(error.minimumVersion, BuzzerHostConstants.minimumHostProtocolVersion)
        XCTAssertEqual(error.maximumVersion, BuzzerHostConstants.hostProtocolVersion)
        XCTAssertTrue(host.isClosed)
    }

    func testCommandBeforeHelloIsRejected() async throws {
        let host = FakeHostConnection()
        await hub.hostConnected(host)
        try await send(.markCorrect, from: host)

        XCTAssertEqual(host.errorCode, .helloRequired)
        XCTAssertTrue(host.isClosed)
    }

    func testUndecodableFirstMessageIsRejected() async {
        let host = FakeHostConnection()
        await hub.hostConnected(host)
        await hub.hostReceived(text: Data("not json".utf8), from: host.id)
        XCTAssertEqual(host.errorCode, .helloRequired)
        XCTAssertTrue(host.isClosed)
    }

    func testUndecodableMessageAfterHelloIsIgnored() async throws {
        let (host, _) = try await openRoom()
        await hub.hostReceived(text: Data(#"{"type":"launchRockets"}"#.utf8), from: host.id)
        XCTAssertEqual(host.errorCode, .badMessage)
        XCTAssertFalse(host.isClosed)
    }

    func testSecondHelloOnTheSameConnectionIsRejected() async throws {
        let (host, _) = try await openRoom()
        try await send(.hello(HostHello(token: token)), from: host)
        XCTAssertEqual(host.errorCode, .helloRequired)
        XCTAssertTrue(host.isClosed)
    }

    func testHostThatNeverSaysHelloIsClosed() async {
        let host = FakeHostConnection()
        await hub.hostConnected(host)
        await scheduler.advance(by: BuzzerHostConstants.helloTimeout + 1)
        XCTAssertEqual(host.errorCode, .helloRequired)
        XCTAssertTrue(host.isClosed)
    }

    func testTheHostTokenIsNeverLogged() async throws {
        _ = try await connectHost()
        _ = try await connectHost(token: "a-wrong-token-that-is-long")
        for line in logger.lines {
            XCTAssertFalse(line.contains(token), line)
            XCTAssertFalse(line.contains("a-wrong-token-that-is-long"), line)
        }
    }

    // MARK: - Rooms and limits

    func testPINsAreUniqueAcrossRooms() async throws {
        codes.replace(with: ["AAAAAA", "AAAAAA", "AAAAAA", "BBBBBB"])
        let first = try await connectHost()
        let second = try await connectHost()
        XCTAssertEqual(first.roomOpened?.code, "AAAAAA")
        XCTAssertEqual(second.roomOpened?.code, "BBBBBB")
        XCTAssertNotEqual(first.roomOpened?.resumeToken, second.roomOpened?.resumeToken)
    }

    func testServerFullBeyondMaxRooms() async throws {
        await hub.stop()
        await makeHub { $0.maxRooms = 2 }
        _ = try await connectHost()
        _ = try await connectHost()
        let third = try await connectHost()
        XCTAssertEqual(third.errorCode, .serverFull)
        XCTAssertTrue(third.isClosed)
    }

    func testClosingARoomFreesItsSlot() async throws {
        await hub.stop()
        await makeHub { $0.maxRooms = 1 }
        let (host, _) = try await openRoom()
        try await send(.closeRoom, from: host)
        let next = try await connectHost()
        XCTAssertNotNil(next.roomOpened)
    }

    // MARK: - Phone routing

    func testPhoneJoinIsRoutedToTheRoomItsPINNames() async throws {
        let (_, roomA) = try await openRoom()
        let hostB = try await connectHost()
        let roomB = try XCTUnwrap(hostB.roomOpened)
        let green = BuzzerTeam(id: UUID(), name: "Green", color: "#00FF00", claimed: false)
        try await send(.updateTeams([green]), from: hostB)

        let phoneA = await joinPhone(roomA.code)
        let phoneB = await joinPhone(roomB.code, remoteKey: "198.51.100.8")

        XCTAssertEqual(phoneA.messages.first, .joinAccepted(teams: [red, blue]))
        XCTAssertEqual(phoneB.messages.first, .joinAccepted(teams: [green]))
        let connected = await hub.isPhoneConnected(phoneB.id)
        XCTAssertTrue(connected)
    }

    func testWrongPINGetsTheSameRejectionAsTheBuiltInServer() async throws {
        _ = try await openRoom()
        let phone = await joinPhone("ZZZZZZ")
        XCTAssertEqual(phone.sent, [.init(message: .joinRejected(.invalidCode), closeAfterSending: true)])
        let connected = await hub.isPhoneConnected(phone.id)
        XCTAssertFalse(connected)
    }

    func testOldPageVersionIsRejected() async throws {
        let (_, opened) = try await openRoom()
        let phone = await joinPhone(opened.code, version: BuzzerConstants.minimumProtocolVersion - 1)
        XCTAssertEqual(joinRejection(phone), .unsupportedVersion)
    }

    func testWrongPINsAreRateLimitedPerAddressAcrossTheWholeServer() async throws {
        let (_, roomA) = try await openRoom()
        let hostB = try await connectHost()
        let roomB = try XCTUnwrap(hostB.roomOpened)

        // Guesses spread over "rooms" still count against one address.
        for index in 0..<BuzzerConstants.maxCodeAttempts {
            let phone = await joinPhone(index.isMultiple(of: 2) ? "ZZZZZZ" : "YYYYYY")
            XCTAssertEqual(joinRejection(phone), .invalidCode)
        }
        let limited = await joinPhone("XXXXXX")
        XCTAssertEqual(joinRejection(limited), .rateLimited)
        let rightPIN = await joinPhone(roomA.code)
        XCTAssertEqual(joinRejection(rightPIN), .rateLimited, "a blocked address can't join any room")
        let otherRoom = await joinPhone(roomB.code)
        XCTAssertEqual(joinRejection(otherRoom), .rateLimited)

        let otherPhone = await joinPhone(roomA.code, remoteKey: "198.51.100.200")
        XCTAssertNil(joinRejection(otherPhone), "other addresses (other forwarded IPs) aren't affected")

        await scheduler.advance(by: BuzzerConstants.rateLimitLockout + 1)
        let later = await joinPhone(roomA.code)
        XCTAssertNil(joinRejection(later))
    }

    func testRoomFullRejectsPhonesBeyondTheLimit() async throws {
        await hub.stop()
        await makeHub { $0.maxPhonesPerRoom = 2 }
        let (_, opened) = try await openRoom()
        let first = await joinPhone(opened.code, remoteKey: "198.51.100.1")
        let second = await joinPhone(opened.code, remoteKey: "198.51.100.2")
        let third = await joinPhone(opened.code, remoteKey: "198.51.100.3")
        XCTAssertNil(joinRejection(first))
        XCTAssertNil(joinRejection(second))
        XCTAssertEqual(joinRejection(third), .roomFull)

        // A phone leaving makes room.
        await hub.phoneDisconnected(first.id, reason: .connectionEnded)
        let fourth = await joinPhone(opened.code, remoteKey: "198.51.100.4")
        XCTAssertNil(joinRejection(fourth))
    }

    func testPhonesThatNeverJoinAreClosed() async {
        let phone = FakeConnection(remoteKey: "198.51.100.7")
        await hub.phoneConnected(phone)
        await scheduler.advance(by: BuzzerConstants.joinTTL + 1.5)
        XCTAssertTrue(phone.isClosed)
        let connected = await hub.isPhoneConnected(phone.id)
        XCTAssertFalse(connected)
    }

    func testPendingPhonesAreLimited() async {
        await hub.stop()
        await makeHub { $0.maxPendingPhones = 2 }
        let phones = (0..<3).map { _ in FakeConnection() }
        var accepted: [Bool] = []
        for phone in phones {
            accepted.append(await hub.phoneConnected(phone))
        }
        XCTAssertEqual(accepted, [true, true, false])
        XCTAssertEqual(phones[2].closeReason, .serverBusy)
    }

    // MARK: - Commands and events

    func testHostCommandsReachPhonesAndRoomEventsReachTheHost() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await claim(red, by: phone)
        await eventually("claimedTeams") { host.events.contains(.claimedTeams([red.id])) }

        try await send(.setBuzzerMode(.armed), from: host)
        XCTAssertEqual(buzzerStates(phone).last, .armed)
        await hub.phoneReceived(text: Data(#"{"type":"buzz"}"#.utf8), from: phone.id)
        await scheduler.advance(by: BuzzerConstants.tieWindow + 0.01)
        await eventually("firstBuzz") { host.events.contains(.firstBuzz(red.id)) }
        XCTAssertEqual(buzzerStates(phone).last, .first)

        try await send(.broadcastPhase("board"), from: host)
        XCTAssertTrue(phone.messages.contains(.state(phase: "board")))

        try await send(.removePhone(teamID: red.id), from: host)
        XCTAssertTrue(phone.messages.contains(.removed))
        let connected = await hub.isPhoneConnected(phone.id)
        XCTAssertFalse(connected)
    }

    func testHostIsPinged() async throws {
        let (host, _) = try await openRoom()
        await scheduler.advance(by: BuzzerHostConstants.pingInterval + 1)
        XCTAssertTrue(host.sent.contains(.ping))
    }

    func testHostThatAnswersPingsStays() async throws {
        let (host, _) = try await openRoom()
        for _ in 0..<10 {
            await scheduler.advance(by: BuzzerHostConstants.pingInterval)
            try await send(.pong, from: host)
        }
        XCTAssertFalse(host.isClosed)
    }

    func testCloseRoomEndsTheSessionForPhones() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)

        try await send(.closeRoom, from: host)

        XCTAssertTrue(phone.sent.contains(.init(message: .sessionEnded, closeAfterSending: true)))
        XCTAssertTrue(host.events.contains(.roomClosed(reason: "hostClosed")))
        XCTAssertTrue(host.isClosed)
        let late = await joinPhone(opened.code, remoteKey: "198.51.100.50")
        XCTAssertEqual(joinRejection(late), .invalidCode)
    }

    func testStopClosesEveryRoom() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await hub.stop()
        XCTAssertTrue(host.events.contains(.roomClosed(reason: "serverStopping")))
        XCTAssertTrue(phone.sent.contains(.init(message: .sessionEnded, closeAfterSending: true)))
        let rooms = await hub.roomCount
        XCTAssertEqual(rooms, 0)
    }

    // MARK: - Grace period and resume

    func testHostDropPausesPhonesAndResumeBringsThemBack() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await claim(red, by: phone)
        try await send(.setBuzzerMode(.armed), from: host)

        await hub.hostDisconnected(host.id)
        XCTAssertEqual(buzzerStates(phone).last, .unavailable, "phones see the buzzer as unavailable")
        await hub.phoneReceived(text: Data(#"{"type":"buzz"}"#.utf8), from: phone.id)
        XCTAssertEqual(buzzerStates(phone).last, .unavailable, "buzzes are ignored while the host is away")

        await scheduler.advance(by: 20)
        let back = try await connectHost(resumeToken: opened.resumeToken)
        let resumed = try XCTUnwrap(back.roomOpened)
        XCTAssertTrue(resumed.resumed)
        XCTAssertEqual(resumed.code, opened.code, "the room keeps its PIN")
        XCTAssertEqual(resumed.resumeToken, opened.resumeToken)
        XCTAssertEqual(buzzerStates(phone).last, .armed)

        // Commands from the new connection reach the room.
        try await send(.setBuzzerMode(.disabled), from: back)
        XCTAssertEqual(buzzerStates(phone).last, .waiting)
    }

    func testReturningHostGetsTheLatestStateAndWhatHappenedBeforeRoomOpened() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await claim(red, by: phone)
        try await send(.openWagering(limits: [red.id: 1000], wagers: [:]), from: host)
        await eventually("claim reaches the host") { host.events.contains(.claimedTeams([red.id])) }

        await hub.hostDisconnected(host.id)
        await hub.phoneReceived(text: Data(#"{"type":"submitWager","amount":600}"#.utf8), from: phone.id)
        XCTAssertTrue(phone.messages.contains(.wagerLocked(wager: 600)))
        // Let the wager event reach the hub before the host comes back.
        try await Task.sleep(for: .milliseconds(50))

        let back = try await connectHost(resumeToken: opened.resumeToken)
        let events = back.events
        let openedIndex = try XCTUnwrap(events.firstIndex { if case .roomOpened = $0 { true } else { false } })
        let wagerIndex = try XCTUnwrap(events.firstIndex(of: .wager(WagerSubmission(teamID: red.id, amount: 600))))
        XCTAssertLessThan(wagerIndex, openedIndex, "catch-up comes before roomOpened")
        XCTAssertTrue(events[..<openedIndex].contains(.claimedTeams([red.id])))
        XCTAssertTrue(events[..<openedIndex].contains(.connectedCount(1)))
    }

    func testGracePeriodExpiryEndsTheSessionAndRemovesTheRoom() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await hub.hostDisconnected(host.id)

        await scheduler.advance(by: 44)
        XCTAssertFalse(phone.isClosed, "kept during the grace period")

        await scheduler.advance(by: 2)
        XCTAssertTrue(phone.sent.contains(.init(message: .sessionEnded, closeAfterSending: true)))
        let rooms = await hub.roomCount
        XCTAssertEqual(rooms, 0)

        let late = try await connectHost(resumeToken: opened.resumeToken)
        XCTAssertEqual(late.errorCode, .roomNotFound)
        let latePhone = await joinPhone(opened.code, remoteKey: "198.51.100.60")
        XCTAssertEqual(joinRejection(latePhone), .invalidCode)
    }

    func testResumeWithinTheGracePeriodCancelsTheExpiry() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await hub.hostDisconnected(host.id)
        await scheduler.advance(by: 30)
        let back = try await connectHost(resumeToken: opened.resumeToken)

        // Keep the host and the phone answering so nothing else times out.
        for _ in 0..<12 {
            await scheduler.advance(by: 5)
            try await send(.pong, from: back)
            await hub.phonePong(from: phone.id)
        }
        let rooms = await hub.roomCount
        XCTAssertEqual(rooms, 1)
        XCTAssertFalse(phone.sent.contains(.init(message: .sessionEnded, closeAfterSending: true)))
    }

    func testSecondDropStartsAFreshGracePeriod() async throws {
        let (host, opened) = try await openRoom()
        await hub.hostDisconnected(host.id)
        await scheduler.advance(by: 40)
        let back = try await connectHost(resumeToken: opened.resumeToken)
        await hub.hostDisconnected(back.id)
        await scheduler.advance(by: 40)   // 80s since the first drop, 40 since the second
        var rooms = await hub.roomCount
        XCTAssertEqual(rooms, 1)
        await scheduler.advance(by: 6)
        rooms = await hub.roomCount
        XCTAssertEqual(rooms, 0)
    }

    func testHostThatStopsAnsweringPingsIsTreatedAsGone() async throws {
        let (host, opened) = try await openRoom()
        let phone = await joinPhone(opened.code)
        await claim(red, by: phone)
        try await send(.setBuzzerMode(.armed), from: host)

        await scheduler.advance(by: BuzzerHostConstants.hostTTL + 2)
        XCTAssertTrue(host.isClosed)
        XCTAssertEqual(buzzerStates(phone).last, .unavailable)

        let back = try await connectHost(resumeToken: opened.resumeToken)
        XCTAssertEqual(back.roomOpened?.resumed, true)
    }

    func testResumeTakesTheRoomFromAHalfOpenConnection() async throws {
        let (old, opened) = try await openRoom()
        let back = try await connectHost(resumeToken: opened.resumeToken)
        XCTAssertEqual(back.roomOpened?.resumed, true)
        XCTAssertTrue(old.isClosed)

        // The old connection's late close doesn't start a grace period.
        await hub.hostDisconnected(old.id)
        await scheduler.advance(by: 46)
        try await send(.pong, from: back)
        let rooms = await hub.roomCount
        XCTAssertEqual(rooms, 1)
    }

    func testWrongResumeTokenIsRoomNotFound() async throws {
        _ = try await openRoom()
        let host = try await connectHost(resumeToken: "not-a-real-token")
        XCTAssertEqual(host.errorCode, .roomNotFound)
        XCTAssertTrue(host.isClosed)
    }

    func testResumeStillNeedsTheHostToken() async throws {
        let (host, opened) = try await openRoom()
        await hub.hostDisconnected(host.id)
        let thief = try await connectHost(token: "wrong-token-wrong-token", resumeToken: opened.resumeToken)
        XCTAssertEqual(thief.errorCode, .badToken)
        XCTAssertNil(thief.roomOpened)
    }
}

/// Game PINs for the hub to hand out, in order.
private final class CodeQueue: Sendable {
    private let codes: Mutex<[String]>

    init(_ codes: [String]) {
        self.codes = Mutex(codes)
    }

    func next() -> String {
        codes.withLock { $0.isEmpty ? JoinCodeGenerator.generate() : $0.removeFirst() }
    }

    func replace(with codes: [String]) {
        self.codes.withLock { $0 = codes }
    }
}
