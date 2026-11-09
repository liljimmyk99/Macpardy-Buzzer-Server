//
//  BuzzerHostConstants.swift
//  BuzzerHostProtocol
//
//  Versions, paths and timings of the host protocol: the channel between the
//  Mac (the game's host) and a self-hosted buzzer server (#103). It has its
//  own version, separate from the phone protocol, because the app and the
//  server are released separately.
//

import Foundation

public enum BuzzerHostConstants: Sendable {

    /// The host protocol version this build speaks. Sent by the Mac in `hello`.
    /// v1 (#103): first version.
    public static let hostProtocolVersion = 1

    /// The oldest host protocol version the server accepts.
    public static let minimumHostProtocolVersion = 1

    /// Whether a Mac speaking `version` may open or resume a room.
    public static func isSupported(version: Int) -> Bool {
        (minimumHostProtocolVersion...hostProtocolVersion).contains(version)
    }

    /// WebSocket path the Mac connects to.
    public static let hostPath = "/host"

    /// WebSocket path phones connect to (same as the built-in server).
    public static let phonePath = "/ws"

    /// Health check path: answers 200 while the server runs.
    public static let healthPath = "/healthz"

    /// Seconds a new host connection has to send `hello`.
    public static let helloTimeout: TimeInterval = 10

    /// How often the server pings the host.
    public static let pingInterval: TimeInterval = 5

    /// Seconds without a `pong` before the server treats the host as gone and
    /// starts the grace period, even if the TCP connection looks open.
    public static let hostTTL: TimeInterval = 20

    /// Allowed range for the host reconnect grace period, and its default.
    public static let gracePeriodRange: ClosedRange<TimeInterval> = 30...60
    public static let defaultGracePeriod: TimeInterval = 45

    /// Largest host message the server reads. Higher than a phone's, since
    /// `setAnswering` carries every team's Final answer.
    public static let maxHostMessageSize = 1 << 20

    /// Wrong host tokens allowed from one address within `tokenAttemptWindow`
    /// before it is locked out for `tokenLockout`.
    public static let maxTokenAttempts = 5
    public static let tokenAttemptWindow: TimeInterval = 60
    public static let tokenLockout: TimeInterval = 300
}
