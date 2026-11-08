//
//  BuzzerLogging.swift
//  BuzzerCore
//
//  How package code logs. BuzzerCore can't use the app's `AppLogger` (or
//  OSLog, which isn't on Linux), so it logs through `BuzzerLogging` and each
//  host supplies the sink: the app forwards to `AppLogger.buzzer`, so the Logs
//  window and its team and remote filters keep working; a server can write to
//  stdout.
//
//  Content rule, as in the app (AGENTS.md): log IDs, team names, scores,
//  wagers, local IPs and browser versions, never clue text, answer text or
//  Final answers.
//

import Foundation

/// How serious a log line is, least to most severe. Mirrors the app's `LogLevel`.
public enum BuzzerLogLevel: String, CaseIterable, Comparable, Sendable {
    case debug, info, notice, warning, error

    public static func < (lhs: BuzzerLogLevel, rhs: BuzzerLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        }
    }
}

/// Which verbose-log prefix (#87) a line gets. The sink adds the prefix, so
/// package code passes the bare message.
public enum BuzzerLogKind: String, CaseIterable, Sendable {
    /// No prefix.
    case plain
    /// `state: …`, a model value changed (also used by `change`).
    case state
    /// `phone: …`, something a phone did.
    case phone

    /// The prefix the app's verbose log uses, e.g. "state: ".
    public var prefix: String {
        switch self {
        case .plain: ""
        case .state: "state: "
        case .phone: "phone: "
        }
    }
}

/// A destination for package log lines.
public protocol BuzzerLogging: Sendable {
    /// - Parameters:
    ///   - team: The team the line is about, for a team filter.
    ///   - remote: The phone's IP address, when the line is about one phone.
    func log(_ level: BuzzerLogLevel, _ message: String, kind: BuzzerLogKind, team: String?, remote: String?)
}

extension BuzzerLogging {

    public func debug(_ message: String, team: String? = nil, remote: String? = nil) {
        log(.debug, message, kind: .plain, team: team, remote: remote)
    }

    public func info(_ message: String, team: String? = nil, remote: String? = nil) {
        log(.info, message, kind: .plain, team: team, remote: remote)
    }

    public func notice(_ message: String, team: String? = nil, remote: String? = nil) {
        log(.notice, message, kind: .plain, team: team, remote: remote)
    }

    public func warning(_ message: String, team: String? = nil, remote: String? = nil) {
        log(.warning, message, kind: .plain, team: team, remote: remote)
    }

    public func error(_ message: String, team: String? = nil, remote: String? = nil) {
        log(.error, message, kind: .plain, team: team, remote: remote)
    }

    /// A verbose `state:` line that isn't a single `old → new` value.
    public func state(_ message: String, team: String? = nil) {
        log(.debug, message, kind: .state, team: team, remote: nil)
    }

    /// A verbose `phone:` line about something one phone did.
    public func phone(_ message: String, team: String? = nil, remote: String? = nil) {
        log(.debug, message, kind: .phone, team: team, remote: remote)
    }

    /// Logs `state: <field>: <old> → <new> (<reason>)`, or nothing when the
    /// value didn't change. Same format as the app's `MacpardyLogger.change`.
    public func change<T: Equatable>(
        _ field: String,
        from old: T,
        to new: T,
        reason: String? = nil,
        team: String? = nil
    ) {
        guard old != new else { return }
        let suffix = reason.map { " (\($0))" } ?? ""
        state("\(field): \(BuzzerLogValue.describe(old)) → \(BuzzerLogValue.describe(new))\(suffix)", team: team)
    }
}

/// A value with a one-line form that's safe to log (IDs and names, never clue
/// or answer text). Mirrors the app's `LogDescribable`.
public protocol BuzzerLogDescribable {
    var logDescription: String { get }
}

public enum BuzzerLogValue {

    /// `logDescription` for `BuzzerLogDescribable` values, "none" for nil,
    /// quoted for strings, else `String(describing:)`. Matches the app's `LogValue`.
    public static func describe(_ value: Any) -> String {
        if let describable = value as? BuzzerLogDescribable { return describable.logDescription }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return "none" }
            return describe(wrapped)
        }
        if let text = value as? String { return "'\(text)'" }
        return String(describing: value)
    }
}

/// Drops every line. The default until a host connects a real sink.
public struct NoBuzzerLogging: BuzzerLogging {
    public init() {}

    public func log(_ level: BuzzerLogLevel, _ message: String, kind: BuzzerLogKind, team: String?, remote: String?) {}
}
