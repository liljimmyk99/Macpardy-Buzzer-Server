//
//  LogDuration.swift
//  BuzzerCore
//
//  Durations for log lines ("6.1s", "12m 3s", "1h 5m").
//

import Foundation

public enum LogDuration {

    /// Seconds with one decimal under a minute ("6.1s"), else as `format`.
    public static func seconds(_ interval: TimeInterval) -> String {
        guard interval < 60 else { return format(interval) }
        return String(format: "%.1fs", max(0, interval))
    }

    /// "41s", "12m 3s", "1h 5m".
    public static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m" }
        return "\(seconds)s"
    }
}
