//
//  HostEvent.swift
//  BuzzerHostProtocol
//
//  Server → host messages (#103): the room opening, the same events the
//  built-in room reports (`BuzzerRoomEvent`), errors and the heartbeat.
//

import BuzzerCore
import Foundation

public enum HostEvent: Equatable, Sendable {
    /// The room is open (or taken back after a drop). The Mac shows `code` as
    /// the Game PIN and keeps `resumeToken` to reconnect.
    case roomOpened(RoomOpened)
    /// The server closed the room: the host sent `closeRoom`, or the server is
    /// shutting down. The connection closes after this.
    case roomClosed(reason: String)
    /// Something the Mac sent was refused. Fatal codes close the connection.
    case error(HostError)
    /// The server's heartbeat; answer with `pong`.
    case ping

    // Room events, as `BuzzerRoomEvent`.
    case claimedTeams(Set<UUID>)
    case firstBuzz(UUID?)
    case wager(WagerSubmission)
    case answer(AnswerSubmission)
    case connectedCount(Int)

    /// The host message for a room event; nil for events the host doesn't get
    /// (a transport failure is the server's own business).
    public init?(_ event: BuzzerRoomEvent) {
        switch event {
        case .claimedTeams(let teams): self = .claimedTeams(teams)
        case .firstBuzz(let teamID): self = .firstBuzz(teamID)
        case .wager(let wager): self = .wager(wager)
        case .answer(let answer): self = .answer(answer)
        case .connectedCount(let count): self = .connectedCount(count)
        case .failed: return nil
        }
    }

    /// The room event this message carries, for the Mac's `BuzzerState`.
    public var roomEvent: BuzzerRoomEvent? {
        switch self {
        case .claimedTeams(let teams): .claimedTeams(teams)
        case .firstBuzz(let teamID): .firstBuzz(teamID)
        case .wager(let wager): .wager(wager)
        case .answer(let answer): .answer(answer)
        case .connectedCount(let count): .connectedCount(count)
        case .roomOpened, .roomClosed, .error, .ping: nil
        }
    }

    /// A one-line form for logs, without answers or tokens.
    public var logDescription: String {
        switch self {
        case .roomOpened(let opened): "roomOpened\(opened.resumed ? " (resumed)" : "")"
        case .roomClosed(let reason): "roomClosed (\(reason))"
        case .error(let error): "error \(error.code.rawValue)"
        case .ping: "ping"
        case .claimedTeams(let teams): "claimedTeams (\(teams.count))"
        case .firstBuzz(let teamID): teamID == nil ? "firstBuzz none" : "firstBuzz"
        case .wager: "wager"
        case .answer(let answer): "answer (\(BuzzerLogValue.length(of: answer.answer)))"
        case .connectedCount(let count): "connectedCount \(count)"
        }
    }
}

/// The `roomOpened` payload.
public struct RoomOpened: Codable, Equatable, Sendable {
    /// The Game PIN phones enter.
    public let code: String
    /// Send in `hello` to take the room back after a drop. Secret: never logged.
    public let resumeToken: String
    /// True when this connection took back an existing room. The Mac then
    /// resyncs the game's buzzer state, as after starting a room.
    public let resumed: Bool
    /// Seconds the server keeps the room after the host drops.
    public let gracePeriod: TimeInterval
    /// The host protocol version the server will speak on this connection.
    public let hostProtocolVersion: Int
    /// The server's public URL, if configured. The Mac builds the join link
    /// from the URL the host entered; this is informational.
    public let publicURL: String?

    public init(
        code: String,
        resumeToken: String,
        resumed: Bool,
        gracePeriod: TimeInterval,
        hostProtocolVersion: Int = BuzzerHostConstants.hostProtocolVersion,
        publicURL: String? = nil
    ) {
        self.code = code
        self.resumeToken = resumeToken
        self.resumed = resumed
        self.gracePeriod = gracePeriod
        self.hostProtocolVersion = hostProtocolVersion
        self.publicURL = publicURL
    }
}

/// The `error` payload.
public struct HostError: Codable, Equatable, Sendable {

    public enum Code: String, Codable, Equatable, Sendable, CaseIterable {
        /// The host token is missing or wrong. Fatal.
        case badToken
        /// Too many wrong tokens from this address; try again later. Fatal.
        case rateLimited
        /// The Mac's host protocol version isn't supported. Fatal; see
        /// `minimumVersion` / `maximumVersion`.
        case unsupportedVersion
        /// The server already has its most rooms. Fatal.
        case serverFull
        /// The resume token doesn't name a room (wrong, or its grace period
        /// ran out). Fatal; send a fresh `hello` without one on a new connection.
        case roomNotFound
        /// The first message wasn't `hello`, or `hello` came twice. Fatal.
        case helloRequired
        /// A message couldn't be decoded. Not fatal; the message is ignored.
        case badMessage

        /// Whether the server closes the connection after this error.
        public var isFatal: Bool { self != .badMessage }
    }

    public let code: Code
    /// Developer English, for logs.
    public let message: String
    /// For `unsupportedVersion`: the versions the server accepts.
    public let minimumVersion: Int?
    public let maximumVersion: Int?

    public init(_ code: Code, message: String, minimumVersion: Int? = nil, maximumVersion: Int? = nil) {
        self.code = code
        self.message = message
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
    }
}

// MARK: - Codable

extension HostEvent: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private struct Closed: Codable { let reason: String }
    private struct ClaimedTeams: Codable { let teamIDs: [UUID] }
    private struct FirstBuzz: Codable { let teamID: UUID? }
    private struct Wager: Codable { let teamID: UUID; let amount: Int }
    private struct Answer: Codable { let teamID: UUID; let answer: String }
    private struct Count: Codable { let count: Int }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func payload<T: Decodable>(_: T.Type) throws -> T {
            try container.decode(T.self, forKey: .payload)
        }
        switch type {
        case "roomOpened": self = .roomOpened(try payload(RoomOpened.self))
        case "roomClosed": self = .roomClosed(reason: try payload(Closed.self).reason)
        case "error": self = .error(try payload(HostError.self))
        case "ping": self = .ping
        case "claimedTeams": self = .claimedTeams(Set(try payload(ClaimedTeams.self).teamIDs))
        case "firstBuzz":
            // `payload` is omitted when nobody is answering.
            self = .firstBuzz(try container.decodeIfPresent(FirstBuzz.self, forKey: .payload)?.teamID)
        case "wager":
            let wager = try payload(Wager.self)
            self = .wager(WagerSubmission(teamID: wager.teamID, amount: wager.amount))
        case "answer":
            let answer = try payload(Answer.self)
            self = .answer(AnswerSubmission(teamID: answer.teamID, answer: answer.answer))
        case "connectedCount": self = .connectedCount(try payload(Count.self).count)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown host event '\(type.prefix(32))'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func put<T: Encodable>(_ type: String, _ payload: T) throws {
            try container.encode(type, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
        switch self {
        case .roomOpened(let opened): try put("roomOpened", opened)
        case .roomClosed(let reason): try put("roomClosed", Closed(reason: reason))
        case .error(let error): try put("error", error)
        case .ping: try container.encode("ping", forKey: .type)
        case .claimedTeams(let teams):
            // Sorted so the same set always encodes the same way.
            try put("claimedTeams", ClaimedTeams(teamIDs: teams.sorted { $0.uuidString < $1.uuidString }))
        case .firstBuzz(let teamID):
            try put("firstBuzz", FirstBuzz(teamID: teamID))
        case .wager(let wager): try put("wager", Wager(teamID: wager.teamID, amount: wager.amount))
        case .answer(let answer): try put("answer", Answer(teamID: answer.teamID, answer: answer.answer))
        case .connectedCount(let count): try put("connectedCount", Count(count: count))
        }
    }
}
