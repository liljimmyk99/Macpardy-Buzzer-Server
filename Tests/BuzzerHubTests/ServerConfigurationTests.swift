//
//  ServerConfigurationTests.swift
//  BuzzerHubTests
//

import BuzzerCore
import XCTest
@testable import BuzzerHub

final class ServerConfigurationTests: XCTestCase {

    private let token = "0123456789abcdef0123"

    private func parse(_ arguments: [String] = [], _ environment: [String: String] = [:], files: [String: String] = [:]) throws(ServerConfiguration.ParseError) -> ServerConfiguration {
        try ServerConfiguration.parse(arguments: arguments, environment: environment, readFile: { files[$0] })
    }

    private func assertError(_ expected: ServerConfiguration.ParseError, _ arguments: [String] = [], _ environment: [String: String] = [:], file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try parse(arguments, environment)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    func testDefaults() throws {
        let configuration = try parse([], ["MACPARDY_HOST_TOKEN": token])
        XCTAssertEqual(configuration.port, 8472)
        XCTAssertEqual(configuration.bindAddress, "0.0.0.0")
        XCTAssertEqual(configuration.hostToken, token)
        XCTAssertNil(configuration.publicURL)
        XCTAssertFalse(configuration.trustForwardedFor)
        XCTAssertEqual(configuration.gracePeriod, 45)
        XCTAssertEqual(configuration.logLevel, .info)
    }

    func testEnvironmentVariables() throws {
        let configuration = try parse([], [
            "MACPARDY_HOST_TOKEN": token,
            "MACPARDY_PORT": "9000",
            "MACPARDY_BIND": "127.0.0.1",
            "MACPARDY_PUBLIC_URL": "https://macpardy.duckdns.org",
            "MACPARDY_TRUST_FORWARDED_FOR": "true",
            "MACPARDY_GRACE_PERIOD": "60",
            "MACPARDY_MAX_ROOMS": "3",
            "MACPARDY_MAX_PHONES_PER_ROOM": "8",
            "MACPARDY_MAX_PENDING_PHONES": "50",
            "MACPARDY_LOG_LEVEL": "DEBUG",
        ])
        XCTAssertEqual(configuration.port, 9000)
        XCTAssertEqual(configuration.bindAddress, "127.0.0.1")
        XCTAssertEqual(configuration.publicURL, "https://macpardy.duckdns.org")
        XCTAssertTrue(configuration.trustForwardedFor)
        XCTAssertEqual(configuration.gracePeriod, 60)
        XCTAssertEqual(configuration.maxRooms, 3)
        XCTAssertEqual(configuration.maxPhonesPerRoom, 8)
        XCTAssertEqual(configuration.maxPendingPhones, 50)
        XCTAssertEqual(configuration.logLevel, .debug)
    }

    func testFlagsWinOverTheEnvironment() throws {
        let configuration = try parse(
            ["--port", "7000", "--trust-forwarded-for", "--grace-period", "30"],
            ["MACPARDY_HOST_TOKEN": token, "MACPARDY_PORT": "9000", "MACPARDY_TRUST_FORWARDED_FOR": "false"]
        )
        XCTAssertEqual(configuration.port, 7000)
        XCTAssertTrue(configuration.trustForwardedFor)
        XCTAssertEqual(configuration.gracePeriod, 30)
    }

    func testTokenFromAFileIsTrimmed() throws {
        let configuration = try parse(["--host-token-file", "/run/secrets/token"], [:], files: ["/run/secrets/token": "\(token)\n"])
        XCTAssertEqual(configuration.hostToken, token)
    }

    func testTokenProblems() {
        assertError(.missingToken)
        assertError(.tokenTooShort, [], ["MACPARDY_HOST_TOKEN": "short"])
        assertError(.unreadableTokenFile("/nope"), ["--host-token-file", "/nope"])
        assertError(.unknownFlag("--host-token"), ["--host-token", token])
    }

    func testBadValues() {
        let env = ["MACPARDY_HOST_TOKEN": token]
        assertError(.invalidValue(name: "MACPARDY_GRACE_PERIOD", value: "29", expected: "a whole number from 30 to 60"), ["--grace-period", "29"], env)
        assertError(.invalidValue(name: "MACPARDY_GRACE_PERIOD", value: "61", expected: "a whole number from 30 to 60"), ["--grace-period", "61"], env)
        assertError(.invalidValue(name: "MACPARDY_PORT", value: "0", expected: "a whole number from 1 to 65535"), ["--port", "0"], env)
        assertError(.invalidValue(name: "MACPARDY_PUBLIC_URL", value: "duckdns.org", expected: "an http(s) URL"), ["--public-url", "duckdns.org"], env)
        assertError(.missingValue("--port"), ["--port"], env)
        assertError(.helpRequested, ["--help"], env)
    }

    func testLogDescriptionLeavesOutTheToken() throws {
        let configuration = try parse([], ["MACPARDY_HOST_TOKEN": token])
        XCTAssertFalse(configuration.logDescription.contains(token))
    }
}
