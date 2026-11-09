//
//  ServerConfiguration.swift
//  BuzzerHub
//
//  The self-hosted server's settings (#103), from flags or environment
//  variables (flags win). The host token comes only from the environment or a
//  file, never a flag, so it doesn't show up in `ps`.
//

import BuzzerCore
import BuzzerHostProtocol
import Foundation

public struct ServerConfiguration: Equatable, Sendable {

    public var port: Int = Int(BuzzerConstants.defaultPort)
    public var bindAddress = "0.0.0.0"
    /// Opening a room needs this. Never logged.
    public var hostToken: String
    /// Where phones reach the server, e.g. `https://macpardy.duckdns.org`.
    public var publicURL: String?
    /// Take the client address from `X-Forwarded-For` (behind a reverse proxy).
    public var trustForwardedFor = false
    public var gracePeriod: TimeInterval = BuzzerHostConstants.defaultGracePeriod
    public var maxRooms = 20
    public var maxPhonesPerRoom = 24
    /// Connections that opened a WebSocket but haven't joined a room yet.
    public var maxPendingPhones = 200
    public var logLevel: BuzzerLogLevel = .info

    /// Shortest host token accepted, so a weak one doesn't go unnoticed.
    public static let minimumTokenLength = 16

    public init(hostToken: String) {
        self.hostToken = hostToken
    }

    // MARK: - Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case helpRequested
        case unknownFlag(String)
        case missingValue(String)
        case invalidValue(name: String, value: String, expected: String)
        case missingToken
        case tokenTooShort
        case unreadableTokenFile(String)

        public var description: String {
            switch self {
            case .helpRequested: ServerConfiguration.usage
            case .unknownFlag(let flag): "Unknown option \(flag). Run with --help for the options."
            case .missingValue(let flag): "\(flag) needs a value."
            case let .invalidValue(name, value, expected): "\(name) is '\(value.prefix(64))'; expected \(expected)."
            case .missingToken: "No host token. Set MACPARDY_HOST_TOKEN, or MACPARDY_HOST_TOKEN_FILE / --host-token-file to a file holding it."
            case .tokenTooShort: "The host token must be at least \(ServerConfiguration.minimumTokenLength) characters."
            case .unreadableTokenFile(let path): "Couldn't read the host token file at \(path)."
            }
        }
    }

    public static let usage = """
    Usage: macpardy-buzzer-server [options]

    Each option can also be set with the environment variable in brackets.

      --port <n>                  Port to listen on (MACPARDY_PORT, default 8472)
      --bind <address>            Address to bind (MACPARDY_BIND, default 0.0.0.0)
      --host-token-file <path>    File holding the host token (MACPARDY_HOST_TOKEN_FILE)
                                  or set the token itself in MACPARDY_HOST_TOKEN
      --public-url <url>          Where phones reach the server (MACPARDY_PUBLIC_URL)
      --trust-forwarded-for       Use X-Forwarded-For for client addresses; only behind
                                  a reverse proxy (MACPARDY_TRUST_FORWARDED_FOR=true)
      --grace-period <seconds>    Keep a room this long after the Mac drops, 30–60
                                  (MACPARDY_GRACE_PERIOD, default 45)
      --max-rooms <n>             (MACPARDY_MAX_ROOMS, default 20)
      --max-phones-per-room <n>   (MACPARDY_MAX_PHONES_PER_ROOM, default 24)
      --max-pending-phones <n>    Connections not yet in a room (MACPARDY_MAX_PENDING_PHONES, default 200)
      --log-level <level>         debug, info, notice, warning or error (MACPARDY_LOG_LEVEL, default info)
      --help                      Show this help
    """

    /// - Parameters:
    ///   - arguments: Command-line arguments without the program name.
    ///   - readFile: Reads the token file; injected for tests.
    public static func parse(
        arguments: [String],
        environment: [String: String],
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws(ParseError) -> ServerConfiguration {
        // Flags first, folded into the same names as the environment.
        var values: [String: String] = [:]
        var index = 0
        let valueFlags: [String: String] = [
            "--port": "MACPARDY_PORT",
            "--bind": "MACPARDY_BIND",
            "--host-token-file": "MACPARDY_HOST_TOKEN_FILE",
            "--public-url": "MACPARDY_PUBLIC_URL",
            "--grace-period": "MACPARDY_GRACE_PERIOD",
            "--max-rooms": "MACPARDY_MAX_ROOMS",
            "--max-phones-per-room": "MACPARDY_MAX_PHONES_PER_ROOM",
            "--max-pending-phones": "MACPARDY_MAX_PENDING_PHONES",
            "--log-level": "MACPARDY_LOG_LEVEL",
        ]
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" { throw .helpRequested }
            if argument == "--trust-forwarded-for" {
                values["MACPARDY_TRUST_FORWARDED_FOR"] = "true"
            } else if let name = valueFlags[argument] {
                guard index + 1 < arguments.count else { throw .missingValue(argument) }
                index += 1
                values[name] = arguments[index]
            } else {
                throw .unknownFlag(argument)
            }
            index += 1
        }
        func value(_ name: String) -> String? {
            let raw = values[name] ?? environment[name]
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }

        // The token: the variable itself, else the file.
        let token: String
        if let direct = value("MACPARDY_HOST_TOKEN") {
            token = direct
        } else if let path = value("MACPARDY_HOST_TOKEN_FILE") {
            guard let contents = readFile(path) else { throw .unreadableTokenFile(path) }
            token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw .missingToken }
        } else {
            throw .missingToken
        }
        guard token.count >= minimumTokenLength else { throw .tokenTooShort }

        var configuration = ServerConfiguration(hostToken: token)

        func integer(_ name: String, in range: ClosedRange<Int>) throws(ParseError) -> Int? {
            guard let text = value(name) else { return nil }
            guard let number = Int(text), range.contains(number) else {
                throw .invalidValue(name: name, value: text, expected: "a whole number from \(range.lowerBound) to \(range.upperBound)")
            }
            return number
        }

        if let port = try integer("MACPARDY_PORT", in: 1...65535) { configuration.port = port }
        if let bind = value("MACPARDY_BIND") { configuration.bindAddress = bind }
        if let url = value("MACPARDY_PUBLIC_URL") {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", parsed.host != nil else {
                throw .invalidValue(name: "MACPARDY_PUBLIC_URL", value: url, expected: "an http(s) URL")
            }
            configuration.publicURL = url
        }
        if let trust = value("MACPARDY_TRUST_FORWARDED_FOR") {
            switch trust.lowercased() {
            case "1", "true", "yes", "on": configuration.trustForwardedFor = true
            case "0", "false", "no", "off": configuration.trustForwardedFor = false
            default: throw .invalidValue(name: "MACPARDY_TRUST_FORWARDED_FOR", value: trust, expected: "true or false")
            }
        }
        let graceRange = Int(BuzzerHostConstants.gracePeriodRange.lowerBound)...Int(BuzzerHostConstants.gracePeriodRange.upperBound)
        if let grace = try integer("MACPARDY_GRACE_PERIOD", in: graceRange) { configuration.gracePeriod = TimeInterval(grace) }
        if let rooms = try integer("MACPARDY_MAX_ROOMS", in: 1...10_000) { configuration.maxRooms = rooms }
        if let phones = try integer("MACPARDY_MAX_PHONES_PER_ROOM", in: 1...1_000) { configuration.maxPhonesPerRoom = phones }
        if let pending = try integer("MACPARDY_MAX_PENDING_PHONES", in: 1...100_000) { configuration.maxPendingPhones = pending }
        if let level = value("MACPARDY_LOG_LEVEL") {
            guard let parsed = BuzzerLogLevel(rawValue: level.lowercased()) else {
                throw .invalidValue(name: "MACPARDY_LOG_LEVEL", value: level, expected: "debug, info, notice, warning or error")
            }
            configuration.logLevel = parsed
        }
        return configuration
    }

    /// A summary for the startup log line, without the token.
    public var logDescription: String {
        "port \(port) on \(bindAddress), public URL \(publicURL ?? "not set"), "
            + "X-Forwarded-For \(trustForwardedFor ? "trusted" : "ignored"), grace period \(Int(gracePeriod))s, "
            + "max \(maxRooms) rooms × \(maxPhonesPerRoom) phones, \(maxPendingPhones) pending, log level \(logLevel.rawValue)"
    }
}
