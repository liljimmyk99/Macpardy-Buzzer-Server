//
//  DisconnectReason.swift
//  BuzzerCore
//
//  Why a phone's connection was dropped (#81), so each disconnect logs one
//  specific line instead of a generic "Client removed". The room picks most
//  reasons; the transport reports the ones it sees (close frames, network
//  errors, bad frames). The app describes Network.framework errors for
//  `networkError` itself, since the package can't import Network.
//

import Foundation

public enum DisconnectReason: Equatable, Sendable {
    /// The phone sent a WebSocket close frame, with its status code if it had one.
    case phoneClosed(code: UInt16?)
    /// The TCP connection ended without a WebSocket close frame.
    case connectionEnded
    /// The transport reported an error on the connection, already described.
    case networkError(String)
    /// No pong within the heartbeat TTL.
    case heartbeatTimeout(sinceLastPong: TimeInterval)
    /// The socket connected but never sent a valid `join`.
    case neverJoined(after: TimeInterval)
    /// A frame that couldn't be parsed.
    case invalidFrame
    /// A fragmented message larger than the parser's limit.
    case oversizedMessage
    /// The `join` was refused.
    case joinRejected(JoinRejectReason)
    /// The host removed the phone from its team.
    case removedByHost
    /// The server stopped (game completed, resumed or left).
    case serverStopped
    /// The same phone rejoined on a new connection and took its team back.
    case replacedByNewConnection
    /// A self-hosted server already had its most connections waiting to join (#103).
    case serverBusy

    public var description: String {
        switch self {
        case .phoneClosed(let code):
            "phone closed the connection (\(WebSocketCloseCode.describe(code)))"
        case .connectionEnded:
            "the connection ended without a WebSocket close (phone browser or network dropped it)"
        case .networkError(let detail):
            "network error: \(detail)"
        case .heartbeatTimeout(let since):
            "no pong for \(LogDuration.seconds(since)) (heartbeat timeout; phone locked, in the background, or off Wi-Fi)"
        case .neverJoined(let after):
            "never sent a join within \(LogDuration.seconds(after))"
        case .invalidFrame:
            "sent an invalid WebSocket frame"
        case .oversizedMessage:
            "sent a message larger than \(WebSocketFrameParser.maxPayload / 1024) KB"
        case .joinRejected(let reason):
            "join rejected (\(reason.rawValue))"
        case .removedByHost:
            "removed by the host"
        case .serverStopped:
            "the buzzer server stopped"
        case .serverBusy:
            "the server has too many connections waiting to join"
        case .replacedByNewConnection:
            "the same phone reconnected and took its team back"
        }
    }

    /// Expected endings are `info`; ones that point at a problem are `warning`.
    public var logLevel: BuzzerLogLevel {
        switch self {
        case .removedByHost, .serverStopped, .joinRejected, .replacedByNewConnection:
            .info
        case .phoneClosed(let code):
            code == 1000 || code == 1001 ? .info : .warning
        case .connectionEnded, .networkError, .heartbeatTimeout, .neverJoined, .invalidFrame, .oversizedMessage, .serverBusy:
            .warning
        }
    }
}
