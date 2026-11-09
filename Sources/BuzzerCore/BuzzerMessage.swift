//
//  BuzzerMessage.swift
//  BuzzerCore
//
//  Versioned JSON message protocol for the buzzer WebSocket connection.
//  All messages use a top-level `type` string field plus an optional `payload`.
//
//  Server → Phone: ServerMessage
//  Phone → Server: ClientMessage
//

import Foundation

// MARK: - Server → Phone

/// A team as shown in the phone's team picker.
public struct BuzzerTeam: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let color: String
    /// True while a phone holds the team; the phone disables its Join button.
    public let claimed: Bool

    public init(id: UUID, name: String, color: String, claimed: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.claimed = claimed
    }
}

/// Why a `claim` was refused.
public enum ClaimRejectReason: String, Encodable, Equatable, Sendable {
    case taken
    case invalidTeam
    case rateLimited
}

/// Why a `join` was refused. Sent as `code` so the phone doesn't have to match
/// the English `reason` text.
public enum JoinRejectReason: String, Encodable, CaseIterable, Sendable {
    /// The Game PIN doesn't match this session (wrong, or from a finished game).
    case invalidCode
    /// Too many wrong PINs from this address.
    case rateLimited
    /// The page speaks a different protocol version.
    case unsupportedVersion
    /// A self-hosted server's room already has its most phones (#103).
    case roomFull

    /// Human-readable text sent as `reason`, for logs and older pages.
    public var message: String {
        switch self {
        case .invalidCode: "Invalid join code"
        case .rateLimited: "Too many attempts. Try again shortly."
        case .unsupportedVersion: "Unsupported protocol version"
        case .roomFull: "This game is full"
        }
    }
}

/// The answering team's response countdown. Phones count down locally from
/// `remaining`; the server only sends start and stop events.
public struct ResponseTimerInfo: Equatable, Sendable {
    public let teamID: UUID
    /// Seconds left when the message was sent.
    public let remaining: TimeInterval
    /// The full response time, in seconds.
    public let total: TimeInterval

    public init(teamID: UUID, remaining: TimeInterval, total: TimeInterval) {
        self.teamID = teamID
        self.remaining = remaining
        self.total = total
    }
}

/// Messages sent by the server to a connected phone client.
public enum ServerMessage: Equatable, Sendable {
    /// Sent after a valid join code is received. Carries the teams (with claim
    /// flags) so the phone can render its team picker.
    case joinAccepted(teams: [BuzzerTeam])

    /// Sent when the join is refused. The server closes the connection after it;
    /// the phone goes back to its Game PIN screen.
    case joinRejected(JoinRejectReason)

    /// The server is ending this session (game completed, saved game resumed, or
    /// host left the game). The Game PIN no longer works; the phone returns to its
    /// Game PIN screen. The server closes the connection after it.
    case sessionEnded

    /// Broadcast whenever teams are added, renamed, removed, claimed or freed.
    case teams([BuzzerTeam])

    /// The phone now holds the team.
    case claimAccepted(teamID: UUID)

    /// The claim was refused; the phone stays on the team picker.
    case claimRejected(reason: ClaimRejectReason)

    /// The host removed this phone from its team. The server closes the
    /// connection afterwards and the phone must not reconnect on its own.
    case removed

    /// Heartbeat request. The phone must respond with a `pong` client message
    /// within `BuzzerConstants.heartbeatTTL` seconds or be disconnected.
    case ping

    /// Broadcast when the game phase changes so the phone can update its UI.
    case state(phase: String)

    /// What the phone's buzzer button should show. Sent to a single phone.
    case buzzerState(BuzzerPhoneState)

    /// Final Macpardy wagering is open; sent to a single phone. Ineligible
    /// teams get `eligible: false` and cannot wager.
    case wagerInfo(WagerInfo)

    /// A submitted wager was refused. The phone stays on the wager screen.
    case wagerRejected(WagerRejectReason)

    /// The team's wager is locked in (submitted, or set by the host).
    case wagerLocked(wager: Int)

    /// Wagering is over; the phone returns to the buzzer.
    case wagerClosed

    /// A team buzzed in and its response time is running. Broadcast.
    case responseTimer(ResponseTimerInfo)

    /// The response time ended early (host judged the answer) or was cancelled. Broadcast.
    case responseTimerStopped

    /// The Final answer screen: open for typing, or locked once the correct
    /// response is revealed. Sent to a single phone.
    case answerInfo(AnswerInfo)

    /// The team's answer was saved (it can still change it while answering is open).
    case answerSaved(answer: String)

    /// A submitted answer was refused. The phone stays on the answer screen.
    case answerRejected(AnswerRejectReason)

    /// Final answering is over; the phone returns to the buzzer.
    case answerClosed
}

extension ServerMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .joinAccepted(let teams):
            try container.encode("joinAccepted", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(teams, forKey: .teams)
            try payload.encode(BuzzerConstants.protocolVersion, forKey: .version)

        case .joinRejected(let reason):
            try container.encode("joinRejected", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason.message, forKey: .reason)
            try payload.encode(reason, forKey: .code)

        case .sessionEnded:
            try container.encode("sessionEnded", forKey: .type)

        case .teams(let teams):
            try container.encode("teams", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(teams, forKey: .teams)

        case .claimAccepted(let teamID):
            try container.encode("claimAccepted", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(teamID, forKey: .teamID)

        case .claimRejected(let reason):
            try container.encode("claimRejected", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)

        case .removed:
            try container.encode("removed", forKey: .type)

        case .ping:
            try container.encode("ping", forKey: .type)

        case .state(let phase):
            try container.encode("state", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(phase, forKey: .phase)

        case .buzzerState(let state):
            try container.encode("buzzerState", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(state, forKey: .state)

        case .wagerInfo(let info):
            try container.encode("wagerInfo", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(info.eligible, forKey: .eligible)
            try payload.encode(info.max, forKey: .max)
            try payload.encodeIfPresent(info.wager, forKey: .wager)

        case .wagerRejected(let reason):
            try container.encode("wagerRejected", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)

        case .wagerLocked(let wager):
            try container.encode("wagerLocked", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(wager, forKey: .wager)

        case .wagerClosed:
            try container.encode("wagerClosed", forKey: .type)

        case .responseTimer(let info):
            try container.encode("responseTimer", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(info.teamID, forKey: .teamID)
            // Tenths are plenty for a countdown the phone animates itself.
            try payload.encode((info.remaining * 10).rounded() / 10, forKey: .remaining)
            try payload.encode(info.total, forKey: .total)

        case .responseTimerStopped:
            try container.encode("responseTimerStopped", forKey: .type)

        case .answerInfo(let info):
            try container.encode("answerInfo", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(info.open, forKey: .open)
            try payload.encode(info.maxLength, forKey: .maxLength)
            try payload.encodeIfPresent(info.answer, forKey: .answer)

        case .answerSaved(let answer):
            try container.encode("answerSaved", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(answer, forKey: .answer)

        case .answerRejected(let reason):
            try container.encode("answerRejected", forKey: .type)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)

        case .answerClosed:
            try container.encode("answerClosed", forKey: .type)
        }
    }

    private enum PayloadKeys: String, CodingKey {
        case teams, version, reason, phase, teamID, state, eligible, max, wager, remaining, total, code
        case open, maxLength, answer
    }
}

// MARK: - Phone → Server

/// Messages sent by a phone client to the server.
public enum ClientMessage: Sendable {
    /// First message a phone sends after the WebSocket connection opens.
    /// `version` must match `BuzzerConstants.protocolVersion`. `diag` is the
    /// phone's optional report on how its previous connection ended (v8).
    /// `device` is a random per-tab id the page keeps in sessionStorage, so a phone that
    /// reconnects gets its team back (v9).
    case join(code: String, version: Int, diag: PhoneDisconnectReport?, device: String?)

    /// Asks to take a team. Only valid after a successful `join`.
    case claim(teamID: UUID)

    /// Response to a `ping`. Resets the client's heartbeat TTL.
    case pong

    /// The phone's buzzer button was pressed. Only valid once a team is claimed.
    case buzz

    /// Final Macpardy wager. Only the first valid submission counts.
    case submitWager(amount: Int)

    /// Final Macpardy answer. The latest submission counts while answering is open.
    case submitAnswer(answer: String)

    /// Something that happened on the phone's page only, for the Mac's log
    /// (v10). Fire-and-forget: never answered. `event` is checked against
    /// `PhoneUIEvent` by the server; `at` is the page's clock in ms.
    case uiEvent(event: String, at: Double?)
}

/// The page events a phone reports in `uiEvent` (v10). Anything else is ignored.
public enum PhoneUIEvent: String, CaseIterable, Sendable {
    case pageVisible
    case pageHidden
    /// A tap on the buzzer while it can't be pressed.
    case disabledBuzzerTap
    case teamPickerOpened
    case pinSubmitted
    case pinRejected
    case reconnecting

    /// How the Mac's log describes it.
    public var logDescription: String {
        switch self {
        case .pageVisible: "page visible"
        case .pageHidden: "page hidden"
        case .disabledBuzzerTap: "tapped the buzzer while it was disabled"
        case .teamPickerOpened: "team picker opened"
        case .pinSubmitted: "Game PIN submitted"
        case .pinRejected: "Game PIN rejected"
        case .reconnecting: "reconnect attempt"
        }
    }
}

extension ClientMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, code, version, teamID, amount, answer, diag, device, event, at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "join":
            let code = try container.decode(String.self, forKey: .code)
            let version = try container.decode(Int.self, forKey: .version)
            // Optional and best-effort: a malformed report never fails the join.
            let diag = (try? container.decodeIfPresent(PhoneDisconnectReport.self, forKey: .diag))
                .flatMap { $0.isEmpty ? nil : $0 }
            // Also best-effort: an unusable id just means no team is restored.
            let device = (try? container.decodeIfPresent(String.self, forKey: .device))
                .flatMap { Self.validDeviceID($0) }
            self = .join(code: code, version: version, diag: diag, device: device)
        case "claim":
            self = .claim(teamID: try container.decode(UUID.self, forKey: .teamID))
        case "pong":
            self = .pong
        case "buzz":
            self = .buzz
        case "submitWager":
            self = .submitWager(amount: try container.decode(Int.self, forKey: .amount))
        case "submitAnswer":
            self = .submitAnswer(answer: try container.decode(String.self, forKey: .answer))
        case "uiEvent":
            self = .uiEvent(
                event: try container.decode(String.self, forKey: .event),
                at: try? container.decodeIfPresent(Double.self, forKey: .at)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown client message type: \(type_)"
            )
        }
    }
}

extension ClientMessage {
    /// `id` if it's a usable device id: 1 to `maxDeviceIDLength` letters,
    /// digits or dashes.
    public static func validDeviceID(_ id: String) -> String? {
        guard (1...BuzzerConstants.maxDeviceIDLength).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return id
    }
}

// MARK: - Helpers

extension ServerMessage {
    /// Encodes the message to a UTF-8 JSON `Data` blob ready for transmission.
    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
