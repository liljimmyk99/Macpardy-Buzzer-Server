//
//  HostProtocolTests.swift
//  BuzzerHostProtocolTests
//
//  The host protocol's JSON (#103): every message round-trips, and the wire
//  shape the docs describe holds.
//

import BuzzerCore
import Foundation
import XCTest
@testable import BuzzerHostProtocol

final class HostProtocolTests: XCTestCase {

    private let teamA = UUID()
    private let teamB = UUID()

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testEveryCommandRoundTrips() throws {
        let commands: [HostCommand] = [
            .hello(HostHello(token: "secret", version: 1, resumeToken: "r", client: "0.6.0")),
            .hello(HostHello(token: "secret")),
            .pong,
            .closeRoom,
            .updateTeams([BuzzerTeam(id: teamA, name: "Red", color: "#FF0000", claimed: false)]),
            .updateScores([teamA: 400, teamB: -200]),
            .setBuzzerMode(.armed),
            .setBuzzerMode(.disabled),
            .setBuzzerMode(.unavailable),
            .markWrong(teamID: teamA),
            .markCorrect,
            .setResponseTimer(teamID: teamA, seconds: 5),
            .setResponseTimer(teamID: nil, seconds: 0),
            .openWagering(limits: [teamA: 1000], wagers: [teamB: 200]),
            .closeWagering,
            .setWager(teamID: teamA, amount: 300),
            .setWager(teamID: teamA, amount: nil),
            .setAnswering(.open, answers: [teamA: "What is Swift?"]),
            .setAnswering(.locked, answers: [:]),
            .setAnswering(.closed, answers: [:]),
            .removePhone(teamID: teamB),
            .broadcastPhase("board"),
        ]
        for command in commands {
            try roundTrip(command)
        }
    }

    func testEveryEventRoundTrips() throws {
        let events: [HostEvent] = [
            .roomOpened(RoomOpened(code: "ABC234", resumeToken: "t", resumed: false, gracePeriod: 45, publicURL: "https://x.duckdns.org")),
            .roomClosed(reason: "hostClosed"),
            .error(HostError(.unsupportedVersion, message: "no", minimumVersion: 1, maximumVersion: 1)),
            .error(HostError(.badToken, message: "bad")),
            .ping,
            .claimedTeams([teamA, teamB]),
            .claimedTeams([]),
            .firstBuzz(teamA),
            .firstBuzz(nil),
            .wager(WagerSubmission(teamID: teamA, amount: 500)),
            .answer(AnswerSubmission(teamID: teamB, answer: "Who is Ada?")),
            .connectedCount(3),
        ]
        for event in events {
            try roundTrip(event)
        }
    }

    func testHelloWireShape() throws {
        let json = try object(HostCommand.hello(HostHello(token: "secret", version: 1, resumeToken: "r")))
        XCTAssertEqual(json["type"] as? String, "hello")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["token"] as? String, "secret")
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["resumeToken"] as? String, "r")
    }

    func testMapsAreKeyedByTeamUUIDString() throws {
        let json = try object(HostCommand.updateScores([teamA: 400]))
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let scores = try XCTUnwrap(payload["scores"] as? [String: Int])
        XCTAssertEqual(scores, [teamA.uuidString: 400])
    }

    func testCommandWithoutPayloadOmitsIt() throws {
        let json = try object(HostCommand.markCorrect)
        XCTAssertEqual(json.keys.sorted(), ["type"])
    }

    func testUnknownTypeAndBadMapKeysDoNotDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(HostCommand.self, from: Data(#"{"type":"launchRockets"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(HostCommand.self, from: Data(#"{"type":"updateScores","payload":{"scores":{"nope":1}}}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(HostCommand.self, from: Data(#"{"type":"setBuzzerMode","payload":{"mode":"party"}}"#.utf8)))
    }

    func testRoomEventsMapBothWays() {
        let events: [BuzzerRoomEvent] = [
            .claimedTeams([teamA]), .firstBuzz(nil), .firstBuzz(teamB),
            .wager(WagerSubmission(teamID: teamA, amount: 1)),
            .answer(AnswerSubmission(teamID: teamA, answer: "x")),
            .connectedCount(2),
        ]
        for event in events {
            XCTAssertEqual(HostEvent(event)?.roomEvent, event)
        }
        XCTAssertNil(HostEvent(.failed("listener died")))
    }

    func testLogDescriptionsNeverContainSecretsOrAnswers() {
        let hello = HostCommand.hello(HostHello(token: "super-secret-token", resumeToken: "resume-secret"))
        XCTAssertFalse(hello.logDescription.contains("secret"))
        let answering = HostCommand.setAnswering(.open, answers: [teamA: "What is Swift?"])
        XCTAssertFalse(answering.logDescription.contains("Swift"))
        let answer = HostEvent.answer(AnswerSubmission(teamID: teamA, answer: "What is Swift?"))
        XCTAssertFalse(answer.logDescription.contains("Swift"))
        let opened = HostEvent.roomOpened(RoomOpened(code: "ABC234", resumeToken: "resume-secret", resumed: true, gracePeriod: 45))
        XCTAssertFalse(opened.logDescription.contains("secret"))
    }

    func testVersionSupport() {
        XCTAssertTrue(BuzzerHostConstants.isSupported(version: BuzzerHostConstants.hostProtocolVersion))
        XCTAssertFalse(BuzzerHostConstants.isSupported(version: BuzzerHostConstants.hostProtocolVersion + 1))
        XCTAssertFalse(BuzzerHostConstants.isSupported(version: 0))
    }

    func testOnlyBadMessageIsNotFatal() {
        XCTAssertEqual(HostError.Code.allCases.filter { !$0.isFatal }, [.badMessage])
    }
}
