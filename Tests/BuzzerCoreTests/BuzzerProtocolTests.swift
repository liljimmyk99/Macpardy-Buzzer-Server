//
//  BuzzerProtocolTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class BuzzerProtocolTests: XCTestCase {

    func testJoinCodeLengthAndAlphabet() {
        let allowed = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        for _ in 0..<200 {
            let code = JoinCodeGenerator.generate()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { allowed.contains($0) }, code)
        }
    }

    func testJoinMessageDecodes() throws {
        let json = Data(#"{"type":"join","version":1,"code":"AB3XYZ"}"#.utf8)
        let message = try JSONDecoder().decode(ClientMessage.self, from: json)
        guard case .join(let code, let version, let diag, let device) = message else { return XCTFail("expected join") }
        XCTAssertEqual(code, "AB3XYZ")
        XCTAssertEqual(version, 1)
        XCTAssertNil(diag)
        XCTAssertNil(device)
    }

    // MARK: - Device id (#84)

    private func decodeDevice(_ deviceJSON: String) throws -> String? {
        let json = #"{"type":"join","version":9,"code":"AB3XYZ","device":"# + deviceJSON + "}"
        let message = try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
        guard case .join(_, _, _, let device) = message else {
            XCTFail("expected join")
            throw CancellationError()
        }
        return device
    }

    func testJoinWithDeviceDecodesIt() throws {
        XCTAssertEqual(try decodeDevice(#""3f9a0c-B21""#), "3f9a0c-B21")
    }

    func testJoinWithUnusableDeviceStillDecodesWithoutOne() throws {
        let tooLong = String(repeating: "a", count: BuzzerConstants.maxDeviceIDLength + 1)
        for garbage in [#""""#, #""has space""#, #""<script>""#, #""\#(tooLong)""#, "42", "null", "{}", #""é1""#] {
            XCTAssertNil(try decodeDevice(garbage), garbage)
        }
    }

    // MARK: - Phone disconnect report (#81)

    private func decodeJoin(_ json: String) throws -> (code: String, version: Int, diag: PhoneDisconnectReport?) {
        let message = try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
        guard case .join(let code, let version, let diag, _) = message else {
            XCTFail("expected join")
            throw CancellationError()
        }
        return (code, version, diag)
    }

    func testJoinWithValidDiagDecodesIt() throws {
        let join = try decodeJoin(#"""
        {"type":"join","version":8,"code":"AB3XYZ","diag":{"cause":"watchdog","connectedMs":720000,
         "hiddenMs":38000,"hiddenAtLoss":false,"secondsSince":41,"closeCode":1006,"closeReason":"bye"}}
        """#)
        XCTAssertEqual(join.code, "AB3XYZ")
        XCTAssertEqual(join.version, 8)
        XCTAssertEqual(join.diag, PhoneDisconnectReport(
            cause: .watchdog,
            closeCode: 1006,
            closeReason: "bye",
            connectedMs: 720_000,
            hiddenMs: 38_000,
            hiddenAtLoss: false,
            secondsSince: 41
        ))
    }

    func testJoinWithoutDiagHasNone() throws {
        let join = try decodeJoin(#"{"type":"join","version":8,"code":"AB3XYZ"}"#)
        XCTAssertEqual(join.code, "AB3XYZ")
        XCTAssertNil(join.diag)
    }

    func testJoinWithGarbageDiagStillDecodes() throws {
        for garbage in [#""watchdog""#, "42", "[1,2]", "null", "{}", #"{"cause":7,"connectedMs":"long"}"#] {
            let join = try decodeJoin(#"{"type":"join","version":8,"code":"AB3XYZ","diag":"# + garbage + "}")
            XCTAssertEqual(join.code, "AB3XYZ", garbage)
            XCTAssertNil(join.diag, garbage)
        }
    }

    func testDiagClampsNumbersTruncatesStringsAndDropsUnknownCause() throws {
        let longReason = String(repeating: "x", count: 500)
        let join = try decodeJoin(#"""
        {"type":"join","version":8,"code":"AB3XYZ","diag":{"cause":"aliens","connectedMs":-5,
         "hiddenMs":1e30,"secondsSince":12.7,"closeCode":99999,"closeReason":"\#(longReason)","hiddenAtLoss":"yes"}}
        """#)
        let diag = try XCTUnwrap(join.diag)
        XCTAssertNil(diag.cause)
        XCTAssertEqual(diag.connectedMs, 0)
        XCTAssertEqual(diag.hiddenMs, PhoneDisconnectReport.maxDurationMs)
        XCTAssertEqual(diag.secondsSince, 12)
        XCTAssertEqual(diag.closeCode, 4999)
        XCTAssertEqual(diag.closeReason?.count, PhoneDisconnectReport.maxStringLength)
        XCTAssertNil(diag.hiddenAtLoss)
    }

    func testJoinWithoutVersionIsRejected() {
        let json = Data(#"{"type":"join","code":"AB3XYZ"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: json))
    }

    func testPongDecodesAndUnknownTypeThrows() throws {
        let pong = try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"pong"}"#.utf8))
        guard case .pong = pong else { return XCTFail("expected pong") }
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"nope"}"#.utf8))
        )
    }

    func testBuzzDecodes() throws {
        let buzz = try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"buzz"}"#.utf8))
        guard case .buzz = buzz else { return XCTFail("expected buzz") }
    }

    func testBuzzerStateEncoding() throws {
        let data = try ServerMessage.buzzerState(.lockedOut).jsonData()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "buzzerState")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["state"] as? String, "lockedOut")
    }

    func testJoinAcceptedEncoding() throws {
        let id = UUID()
        let team = BuzzerTeam(id: id, name: "A", color: "blue", claimed: true)
        let data = try ServerMessage.joinAccepted(teams: [team]).jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "joinAccepted")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, BuzzerConstants.protocolVersion)
        let teams = try XCTUnwrap(payload["teams"] as? [[String: Any]])
        XCTAssertEqual(teams.first?["id"] as? String, id.uuidString)
        XCTAssertEqual(teams.first?["name"] as? String, "A")
        XCTAssertEqual(teams.first?["claimed"] as? Bool, true)
    }

    func testClaimDecodes() throws {
        let id = UUID()
        let json = Data(#"{"type":"claim","teamID":"\#(id.uuidString)"}"#.utf8)
        let message = try JSONDecoder().decode(ClientMessage.self, from: json)
        guard case .claim(let teamID) = message else { return XCTFail("expected claim") }
        XCTAssertEqual(teamID, id)
    }

    func testClaimWithBadTeamIDIsRejected() {
        let json = Data(#"{"type":"claim","teamID":"nope"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: json))
    }

    func testClaimRejectedAndRemovedEncoding() throws {
        let rejected = try ServerMessage.claimRejected(reason: .taken).jsonData()
        let rejectedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: rejected) as? [String: Any])
        XCTAssertEqual(rejectedObject["type"] as? String, "claimRejected")
        XCTAssertEqual((rejectedObject["payload"] as? [String: Any])?["reason"] as? String, "taken")

        let removed = try ServerMessage.removed.jsonData()
        let removedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertEqual(removedObject["type"] as? String, "removed")
        XCTAssertNil(removedObject["payload"])
    }

    // MARK: - Response timer (#59)

    func testResponseTimerEncoding() throws {
        let id = UUID()
        let info = ResponseTimerInfo(teamID: id, remaining: 3.2499, total: 5)
        let data = try ServerMessage.responseTimer(info).jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "responseTimer")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["teamID"] as? String, id.uuidString)
        XCTAssertEqual(try XCTUnwrap(payload["remaining"] as? Double), 3.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(payload["total"] as? Double), 5, accuracy: 0.0001)
    }

    func testResponseTimerStoppedHasNoPayload() throws {
        let data = try ServerMessage.responseTimerStopped.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "responseTimerStopped")
        XCTAssertNil(object["payload"])
    }

    // MARK: - Game PIN entry and session end (#61)

    func testProtocolVersionIsTen() {
        XCTAssertEqual(BuzzerConstants.protocolVersion, 10)
    }

    // MARK: - Page events (#87)

    func testPagesFromVersionNineOnCanJoin() {
        XCTAssertFalse(BuzzerConstants.isSupported(version: 8))
        XCTAssertTrue(BuzzerConstants.isSupported(version: 9))
        XCTAssertTrue(BuzzerConstants.isSupported(version: 10))
        XCTAssertFalse(BuzzerConstants.isSupported(version: 11))
    }

    func testUIEventDecodes() throws {
        let json = Data(#"{"type":"uiEvent","event":"pageHidden","at":1762180000123}"#.utf8)
        let message = try JSONDecoder().decode(ClientMessage.self, from: json)
        guard case .uiEvent(let event, let at) = message else { return XCTFail("expected uiEvent") }
        XCTAssertEqual(event, "pageHidden")
        XCTAssertEqual(PhoneUIEvent(rawValue: event), .pageHidden)
        XCTAssertEqual(at, 1_762_180_000_123)
    }

    func testUIEventWithABadTimeStillDecodes() throws {
        let json = Data(#"{"type":"uiEvent","event":"reconnecting","at":"soon"}"#.utf8)
        let message = try JSONDecoder().decode(ClientMessage.self, from: json)
        guard case .uiEvent(let event, let at) = message else { return XCTFail("expected uiEvent") }
        XCTAssertEqual(event, "reconnecting")
        XCTAssertNil(at)
    }

    func testUnknownUIEventIsNotAPhoneEvent() throws {
        let json = Data(#"{"type":"uiEvent","event":"rm -rf"}"#.utf8)
        let message = try JSONDecoder().decode(ClientMessage.self, from: json)
        guard case .uiEvent(let event, _) = message else { return XCTFail("expected uiEvent") }
        XCTAssertNil(PhoneUIEvent(rawValue: event))
    }

    func testUIEventWithoutAnEventFailsToDecode() {
        let json = Data(#"{"type":"uiEvent"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: json))
    }

    func testJoinRejectedEncodesCodeAndReason() throws {
        let expected: [JoinRejectReason: (code: String, reason: String)] = [
            .invalidCode: ("invalidCode", "Invalid join code"),
            .rateLimited: ("rateLimited", "Too many attempts. Try again shortly."),
            .unsupportedVersion: ("unsupportedVersion", "Unsupported protocol version"),
            .roomFull: ("roomFull", "This game is full"),
        ]
        XCTAssertEqual(expected.count, JoinRejectReason.allCases.count)
        for (reason, values) in expected {
            let data = try ServerMessage.joinRejected(reason).jsonData()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "joinRejected")
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])
            XCTAssertEqual(payload["code"] as? String, values.code)
            XCTAssertEqual(payload["reason"] as? String, values.reason)
        }
    }

    func testSessionEndedHasNoPayload() throws {
        let data = try ServerMessage.sessionEnded.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "sessionEnded")
        XCTAssertNil(object["payload"])
    }

    // MARK: - Final answers (#80)

    func testSubmitAnswerDecodes() throws {
        let json = Data(#"{"type":"submitAnswer","answer":"What is Paris?"}"#.utf8)
        let message = try JSONDecoder().decode(ClientMessage.self, from: json)
        guard case .submitAnswer(let answer) = message else { return XCTFail("expected submitAnswer") }
        XCTAssertEqual(answer, "What is Paris?")
    }

    func testSubmitAnswerWithoutAnswerIsRejected() {
        let json = Data(#"{"type":"submitAnswer"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ClientMessage.self, from: json))
    }

    func testAnswerInfoEncoding() throws {
        let data = try ServerMessage.answerInfo(AnswerInfo(open: true, answer: "Paris", maxLength: 200)).jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "answerInfo")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["open"] as? Bool, true)
        XCTAssertEqual(payload["answer"] as? String, "Paris")
        XCTAssertEqual(payload["maxLength"] as? Int, 200)
    }

    func testAnswerInfoOmitsMissingAnswer() throws {
        let data = try ServerMessage.answerInfo(AnswerInfo(open: false, answer: nil, maxLength: 200)).jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["open"] as? Bool, false)
        XCTAssertNil(payload["answer"])
    }

    func testAnswerSavedRejectedAndClosedEncoding() throws {
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try ServerMessage.answerSaved(answer: "Paris").jsonData()) as? [String: Any]
        )
        XCTAssertEqual(saved["type"] as? String, "answerSaved")
        XCTAssertEqual((saved["payload"] as? [String: Any])?["answer"] as? String, "Paris")

        let rejected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try ServerMessage.answerRejected(.tooLong).jsonData()) as? [String: Any]
        )
        XCTAssertEqual(rejected["type"] as? String, "answerRejected")
        XCTAssertEqual((rejected["payload"] as? [String: Any])?["reason"] as? String, "tooLong")

        let closed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try ServerMessage.answerClosed.jsonData()) as? [String: Any]
        )
        XCTAssertEqual(closed["type"] as? String, "answerClosed")
        XCTAssertNil(closed["payload"])
    }
}
