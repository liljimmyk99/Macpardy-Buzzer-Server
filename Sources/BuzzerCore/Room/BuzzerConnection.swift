//
//  BuzzerConnection.swift
//  BuzzerCore
//
//  One phone's connection, as the room sees it (#101). The transport (the
//  app's Network.framework server today, a self-hosted server later) conforms
//  to this; the room never touches sockets or WebSocket frames.
//

import Foundation

public protocol BuzzerConnection: Sendable {
    /// Unique for the connection's lifetime. The room keys its sessions by it,
    /// and its first four characters tell apart log lines from one address.
    var id: UUID { get }

    /// The phone's IP address, used to key rate limits and in log lines. Falls
    /// back to something unique per connection when there is no address.
    var remoteKey: String { get }

    /// The browser's User-Agent from the WebSocket handshake, if it sent one.
    /// Logged shortened (`UserAgentSummary`).
    var userAgent: String? { get }

    /// Sends one message. With `closeAfterSending`, the connection closes once
    /// the message has gone out, so the phone sees it before the close.
    func send(_ message: ServerMessage, closeAfterSending: Bool)

    /// Closes the connection now. `reason` is why the room dropped it; a
    /// transport may use it to pick a close code.
    func close(reason: DisconnectReason)
}

extension BuzzerConnection {
    public func send(_ message: ServerMessage) {
        send(message, closeAfterSending: false)
    }
}
