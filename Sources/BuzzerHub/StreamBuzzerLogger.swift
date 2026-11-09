//
//  StreamBuzzerLogger.swift
//  BuzzerHub
//
//  The self-hosted server's log sink (#103): one line per message to stdout
//  (Docker collects it), at or above a minimum level. Same content rules as
//  the app: no clue text, answer text, Final answers or host token.
//

import BuzzerCore
import Foundation

public struct StreamBuzzerLogger: BuzzerLogging {

    private let minimumLevel: BuzzerLogLevel
    private let now: @Sendable () -> Date
    private let write: @Sendable (String) -> Void

    /// - Parameter write: Where each finished line goes; stdout by default.
    public init(
        minimumLevel: BuzzerLogLevel = .info,
        now: @escaping @Sendable () -> Date = { Date() },
        write: @escaping @Sendable (String) -> Void = StreamBuzzerLogger.standardOutput
    ) {
        self.minimumLevel = minimumLevel
        self.now = now
        self.write = write
    }

    public func log(_ level: BuzzerLogLevel, _ message: String, kind: BuzzerLogKind, team: String?, remote: String?) {
        guard level >= minimumLevel else { return }
        var line = "\(now().formatted(BuzzerLogValue.timestampStyle)) \(level.rawValue.uppercased())"
        if let remote { line += " [\(remote)]" }
        if let team { line += " [\(team)]" }
        // One line per entry, whatever the message holds.
        line += " \(kind.prefix)\(message)".replacingOccurrences(of: "\n", with: " ")
        write(line)
    }

    public static let standardOutput: @Sendable (String) -> Void = { line in
        // Unbuffered, unlike `print` when stdout isn't a terminal (Docker), so
        // lines show up as they happen.
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// Adds a prefix to every line, e.g. the room a line is about.
public struct PrefixedBuzzerLogger: BuzzerLogging {
    let base: any BuzzerLogging
    let prefix: String

    public init(_ base: any BuzzerLogging, prefix: String) {
        self.base = base
        self.prefix = prefix
    }

    public func log(_ level: BuzzerLogLevel, _ message: String, kind: BuzzerLogKind, team: String?, remote: String?) {
        base.log(level, "\(prefix)\(message)", kind: kind, team: team, remote: remote)
    }
}
