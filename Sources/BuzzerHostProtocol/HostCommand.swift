//
//  HostCommand.swift
//  BuzzerHostProtocol
//
//  Host → server messages (#103). After `hello`, the Mac sends the same game
//  changes `BuzzerBackend` forwards to the built-in room.
//
//  Wire format, as in the phone protocol: `{ "type": "…", "payload": { … } }`,
//  `payload` omitted when empty. Maps keyed by team are JSON objects keyed by
//  the team's UUID string.
//

import BuzzerCore
import Foundation

public enum HostCommand: Equatable, Sendable {
    /// First message on a host connection: authenticates and opens a room, or
    /// takes back the room `resumeToken` names.
    case hello(HostHello)
    /// Answer to the server's `ping`.
    case pong
    /// Ends the room: phones get `sessionEnded` and the server forgets it.
    case closeRoom

    case updateTeams([BuzzerTeam])
    case updateScores([UUID: Int])
    case setBuzzerMode(BuzzerMode)
    case markWrong(teamID: UUID)
    case markCorrect
    case setResponseTimer(teamID: UUID?, seconds: TimeInterval)
    case openWagering(limits: [UUID: Int], wagers: [UUID: Int])
    case closeWagering
    case setWager(teamID: UUID, amount: Int?)
    case setAnswering(FinalAnswerWindow, answers: [UUID: String])
    case removePhone(teamID: UUID)
    case broadcastPhase(String)

    /// A one-line form for logs: the message type and sizes, never the host
    /// token or Final answers.
    public var logDescription: String {
        switch self {
        case .hello(let hello): "hello v\(hello.version)\(hello.resumeToken == nil ? "" : " (resume)")"
        case .pong: "pong"
        case .closeRoom: "closeRoom"
        case .updateTeams(let teams): "updateTeams (\(teams.count))"
        case .updateScores(let scores): "updateScores (\(scores.count))"
        case .setBuzzerMode(let mode): "setBuzzerMode \(HostWire.modeName(mode))"
        case .markWrong: "markWrong"
        case .markCorrect: "markCorrect"
        case .setResponseTimer(let teamID, _): teamID == nil ? "setResponseTimer stop" : "setResponseTimer start"
        case .openWagering(let limits, _): "openWagering (\(limits.count))"
        case .closeWagering: "closeWagering"
        case .setWager: "setWager"
        case .setAnswering(let window, let answers): "setAnswering \(HostWire.windowName(window)) (\(answers.count) answers)"
        case .removePhone: "removePhone"
        case .broadcastPhase(let phase): "broadcastPhase '\(phase.prefix(32))'"
        }
    }
}

/// The `hello` payload.
public struct HostHello: Codable, Equatable, Sendable {
    /// The host token configured on the server. Never logged.
    public let token: String
    /// The host protocol version the Mac speaks.
    public let version: Int
    /// From an earlier `roomOpened`, to take that room back after a drop.
    public let resumeToken: String?
    /// The app's version, for the server's log.
    public let client: String?

    public init(token: String, version: Int = BuzzerHostConstants.hostProtocolVersion, resumeToken: String? = nil, client: String? = nil) {
        self.token = token
        self.version = version
        self.resumeToken = resumeToken
        self.client = client
    }
}

// MARK: - Codable

extension HostCommand: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private struct Teams: Codable { let teams: [BuzzerTeam] }
    private struct Scores: Codable { let scores: [String: Int] }
    private struct Mode: Codable { let mode: String }
    private struct Team: Codable { let teamID: UUID }
    private struct ResponseTimer: Codable { let teamID: UUID?; let seconds: TimeInterval }
    private struct Wagering: Codable { let limits: [String: Int]; let wagers: [String: Int] }
    private struct Wager: Codable { let teamID: UUID; let amount: Int? }
    private struct Answering: Codable { let window: String; let answers: [String: String] }
    private struct Phase: Codable { let phase: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func payload<T: Decodable>(_: T.Type) throws -> T {
            try container.decode(T.self, forKey: .payload)
        }
        switch type {
        case "hello": self = .hello(try payload(HostHello.self))
        case "pong": self = .pong
        case "closeRoom": self = .closeRoom
        case "updateTeams": self = .updateTeams(try payload(Teams.self).teams)
        case "updateScores": self = .updateScores(try HostWire.uuidKeyed(try payload(Scores.self).scores, in: container))
        case "setBuzzerMode":
            self = .setBuzzerMode(try HostWire.mode(named: try payload(Mode.self).mode, in: container))
        case "markWrong": self = .markWrong(teamID: try payload(Team.self).teamID)
        case "markCorrect": self = .markCorrect
        case "setResponseTimer":
            let timer = try payload(ResponseTimer.self)
            self = .setResponseTimer(teamID: timer.teamID, seconds: timer.seconds)
        case "openWagering":
            let wagering = try payload(Wagering.self)
            self = .openWagering(
                limits: try HostWire.uuidKeyed(wagering.limits, in: container),
                wagers: try HostWire.uuidKeyed(wagering.wagers, in: container)
            )
        case "closeWagering": self = .closeWagering
        case "setWager":
            let wager = try payload(Wager.self)
            self = .setWager(teamID: wager.teamID, amount: wager.amount)
        case "setAnswering":
            let answering = try payload(Answering.self)
            self = .setAnswering(
                try HostWire.window(named: answering.window, in: container),
                answers: try HostWire.uuidKeyed(answering.answers, in: container)
            )
        case "removePhone": self = .removePhone(teamID: try payload(Team.self).teamID)
        case "broadcastPhase": self = .broadcastPhase(try payload(Phase.self).phase)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown host command '\(type.prefix(32))'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func put<T: Encodable>(_ type: String, _ payload: T) throws {
            try container.encode(type, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
        switch self {
        case .hello(let hello): try put("hello", hello)
        case .pong: try container.encode("pong", forKey: .type)
        case .closeRoom: try container.encode("closeRoom", forKey: .type)
        case .updateTeams(let teams): try put("updateTeams", Teams(teams: teams))
        case .updateScores(let scores): try put("updateScores", Scores(scores: HostWire.stringKeyed(scores)))
        case .setBuzzerMode(let mode): try put("setBuzzerMode", Mode(mode: HostWire.modeName(mode)))
        case .markWrong(let teamID): try put("markWrong", Team(teamID: teamID))
        case .markCorrect: try container.encode("markCorrect", forKey: .type)
        case .setResponseTimer(let teamID, let seconds): try put("setResponseTimer", ResponseTimer(teamID: teamID, seconds: seconds))
        case .openWagering(let limits, let wagers):
            try put("openWagering", Wagering(limits: HostWire.stringKeyed(limits), wagers: HostWire.stringKeyed(wagers)))
        case .closeWagering: try container.encode("closeWagering", forKey: .type)
        case .setWager(let teamID, let amount): try put("setWager", Wager(teamID: teamID, amount: amount))
        case .setAnswering(let window, let answers):
            try put("setAnswering", Answering(window: HostWire.windowName(window), answers: HostWire.stringKeyed(answers)))
        case .removePhone(let teamID): try put("removePhone", Team(teamID: teamID))
        case .broadcastPhase(let phase): try put("broadcastPhase", Phase(phase: phase))
        }
    }
}
