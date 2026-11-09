//
//  BuzzerWebServerTests.swift
//  BuzzerServerNIOTests
//
//  The self-hosted server over real sockets on localhost (#103): routes, the
//  host and phone WebSockets, X-Forwarded-For and the message size limit.
//

import BuzzerCore
import BuzzerHub
import Foundation
import XCTest
@testable import BuzzerServerNIO

final class BuzzerWebServerTests: XCTestCase {

    private let token = "server-test-token-0123456789"
    private var hub: BuzzerHub!
    private var serverTask: Task<Void, Error>!
    private var port = 0
    private var sockets: [TestWebSocket] = []

    private func startServer(trustForwardedFor: Bool = false) async throws {
        var configuration = ServerConfiguration(hostToken: token)
        configuration.port = 0
        configuration.bindAddress = "127.0.0.1"
        configuration.trustForwardedFor = trustForwardedFor
        let hub = BuzzerHub(configuration: configuration)
        self.hub = hub
        let server = BuzzerWebServer(configuration: configuration, hub: hub, logger: NoBuzzerLogging())
        let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
        serverTask = Task { try await server.run(onListening: { continuation.yield($0) }) }
        for await bound in ports {
            port = bound
            break
        }
    }

    override func tearDown() async throws {
        sockets.forEach { $0.cancel() }
        await hub?.stop()
        serverTask?.cancel()
    }

    private func connect(_ path: String, headers: [String: String] = [:]) async throws -> TestWebSocket {
        let socket = try await TestWebSocket.connect(port: port, path: path, headers: headers)
        sockets.append(socket)
        return socket
    }

    private func openRoom() async throws -> (host: TestWebSocket, code: String) {
        let host = try await connect("/host")
        XCTAssertTrue(host.upgraded)
        host.send(#"{"type":"hello","payload":{"token":"\#(token)","version":1}}"#)
        let opened = await host.waitForMessage(ofType: "roomOpened")
        let payload = try XCTUnwrap(opened?["payload"] as? [String: Any])
        return (host, try XCTUnwrap(payload["code"] as? String))
    }

    // MARK: - HTTP

    func testServesThePageHealthAndNotFound() async throws {
        try await startServer()

        let page = try await httpRequest(port: port, "GET /?code=ABC234 HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(page.lowercased().contains("content-type: text/html"))
        XCTAssertTrue(page.contains("PROTOCOL_VERSION"))

        let health = try await httpRequest(port: port, "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(health.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(health.hasSuffix("ok\n"))

        let missing = try await httpRequest(port: port, "GET /secrets HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(missing.hasPrefix("HTTP/1.1 404"))

        let post = try await httpRequest(port: port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 405"))
    }

    func testHealthCheckCommand() async throws {
        try await startServer()
        let healthy = await HealthCheck.run(port: port)
        XCTAssertTrue(healthy)
        let nobody = await HealthCheck.run(port: 1)
        XCTAssertFalse(nobody)
    }

    func testUnknownWebSocketPathIsNotUpgraded() async throws {
        try await startServer()
        let socket = try await connect("/nope")
        XCTAssertFalse(socket.upgraded)
    }

    // MARK: - WebSockets

    func testHostOpensARoomAndAPhoneJoinsAndClaims() async throws {
        try await startServer()
        let (host, code) = try await openRoom()
        let teamID = UUID().uuidString
        host.send(##"{"type":"updateTeams","payload":{"teams":[{"id":"\##(teamID)","name":"Red","color":"#FF0000","claimed":false}]}}"##)

        let phone = try await connect("/ws", headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Version/18.0 Mobile/15E148 Safari/604.1"])
        phone.send(#"{"type":"join","code":"\#(code)","version":10}"#)
        _ = await phone.waitForMessage(ofType: "joinAccepted")
        phone.send(#"{"type":"claim","teamID":"\#(teamID)"}"#)
        _ = await phone.waitForMessage(ofType: "claimAccepted")
        // The first `claimedTeams` is the empty one from `updateTeams`.
        await host.wait("the claim") { host.texts.contains { $0.contains(#""claimedTeams""#) && $0.contains(teamID) } }
    }

    func testWrongHostTokenIsRefusedAndClosed() async throws {
        try await startServer()
        let host = try await connect("/host")
        host.send(#"{"type":"hello","payload":{"token":"wrong-wrong-wrong-wrong","version":1}}"#)
        let error = await host.waitForMessage(ofType: "error")
        XCTAssertEqual((error?["payload"] as? [String: Any])?["code"] as? String, "badToken")
        await host.wait("close") { host.isClosed }
    }

    func testOversizedPhoneMessageClosesTheConnection() async throws {
        try await startServer()
        let phone = try await connect("/ws")
        phone.send(String(repeating: "x", count: WebSocketFrameParser.maxPayload + 1))
        await phone.wait("close") { phone.isClosed }
    }

    // MARK: - X-Forwarded-For

    func testWrongPINLimitKeysOnTheForwardedAddressWhenTrusted() async throws {
        try await startServer(trustForwardedFor: true)
        let (_, code) = try await openRoom()

        for _ in 0...BuzzerConstants.maxCodeAttempts {
            let guesser = try await connect("/ws", headers: ["X-Forwarded-For": "198.51.100.9"])
            guesser.send(#"{"type":"join","code":"ZZZZZZ","version":10}"#)
            _ = await guesser.waitForMessage(ofType: "joinRejected")
        }
        let blocked = try await connect("/ws", headers: ["X-Forwarded-For": "198.51.100.9"])
        blocked.send(#"{"type":"join","code":"\#(code)","version":10}"#)
        let rejected = await blocked.waitForMessage(ofType: "joinRejected")
        XCTAssertEqual((rejected?["payload"] as? [String: Any])?["code"] as? String, "rateLimited")

        // Another phone behind the same proxy (same TCP peer) isn't blocked.
        let other = try await connect("/ws", headers: ["X-Forwarded-For": "198.51.100.10"])
        other.send(#"{"type":"join","code":"\#(code)","version":10}"#)
        _ = await other.waitForMessage(ofType: "joinAccepted")
    }

    func testForwardedAddressIsIgnoredWhenNotTrusted() async throws {
        try await startServer(trustForwardedFor: false)
        let (_, code) = try await openRoom()

        for index in 0...BuzzerConstants.maxCodeAttempts {
            let guesser = try await connect("/ws", headers: ["X-Forwarded-For": "198.51.100.\(index)"])
            guesser.send(#"{"type":"join","code":"ZZZZZZ","version":10}"#)
            _ = await guesser.waitForMessage(ofType: "joinRejected")
        }
        // Made-up addresses don't dodge the limit: it keys on the real peer.
        let blocked = try await connect("/ws", headers: ["X-Forwarded-For": "198.51.100.200"])
        blocked.send(#"{"type":"join","code":"\#(code)","version":10}"#)
        let rejected = await blocked.waitForMessage(ofType: "joinRejected")
        XCTAssertEqual((rejected?["payload"] as? [String: Any])?["code"] as? String, "rateLimited")
    }
}
