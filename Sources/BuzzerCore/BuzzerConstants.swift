//
//  BuzzerConstants.swift
//  BuzzerCore
//
//  Central configuration for the buzzer: timings, limits and protocol versions.
//

import Foundation

public enum BuzzerConstants: Sendable {
    /// TCP port the built-in buzzer server listens on unless the host changes it
    /// in Settings. The app's `AppSettings` reads its default from here.
    public static let defaultPort: UInt16 = 8472

    /// Seconds a joined phone can go without sending a pong before being
    /// disconnected. Long on purpose (#84): a phone's browser stops answering
    /// while it's in the background or the screen is locked, and a short Wi-Fi
    /// hiccup shouldn't cost a team its slot. A phone that really left is
    /// usually seen sooner, when its TCP connection closes.
    public static let heartbeatTTL: TimeInterval = 60.0

    /// Seconds a socket gets to send a valid `join` before being closed.
    public static let joinTTL: TimeInterval = 5.0

    /// Longest `device` id accepted in a `join`.
    public static let maxDeviceIDLength = 64

    /// How often the server sends a ping to each connected client.
    public static let pingInterval: TimeInterval = 2.0

    /// Current wire-protocol version sent in joinAccepted messages.
    /// v8 (#81): `join` may carry the phone's `diag` report.
    /// v9 (#84): `join` may carry a `device` id; a returning phone gets its team back.
    /// v10 (#87): phones may send `uiEvent` messages for the Mac's log.
    public static let protocolVersion = 10

    /// Oldest page version still allowed to join. v9 pages only lack `uiEvent`,
    /// so a page left open across an update keeps working.
    public static let minimumProtocolVersion = 9

    /// Whether a page speaking `version` may join.
    public static func isSupported(version: Int) -> Bool {
        (minimumProtocolVersion...protocolVersion).contains(version)
    }

    /// `uiEvent` messages one phone may send within `uiEventWindow`; extras are dropped.
    public static let maxUIEvents = 30
    public static let uiEventWindow: TimeInterval = 10.0

    /// Buzzes received within this long of the first one count as a tie.
    public static let tieWindow: TimeInterval = 0.075

    /// Wrong join codes allowed from one address within `codeAttemptWindow`.
    public static let maxCodeAttempts = 5
    public static let codeAttemptWindow: TimeInterval = 60.0

    /// Team claim attempts allowed from one address within `claimAttemptWindow`.
    public static let maxClaimAttempts = 10
    public static let claimAttemptWindow: TimeInterval = 10.0

    /// How long an address stays blocked after exceeding an attempt limit.
    public static let rateLimitLockout: TimeInterval = 30.0
}
