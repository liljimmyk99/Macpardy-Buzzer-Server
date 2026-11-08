//
//  PhoneDisconnectReport.swift
//  BuzzerCore
//
//  The phone's account of how its previous connection ended, sent as the
//  optional `diag` object on its next `join` (protocol v8, #81). The Mac
//  only sees a missing pong; the phone knows whether its page was hidden.
//
//  Decoding is forgiving: every field is optional, numbers are clamped, the
//  close reason is truncated, and an unknown `cause` is dropped. A malformed
//  report never fails the `join` it rides on.
//

import Foundation

public struct PhoneDisconnectReport: Equatable, Sendable {

    public enum Cause: String, Sendable {
        /// The page heard nothing from the Mac for 5 s and gave up.
        case watchdog
        /// The socket closed (see `closeCode`).
        case socketClose
        /// The socket reported an error.
        case socketError
        /// The host removed the phone.
        case removed
        /// The game session ended.
        case sessionEnded
    }

    public static let maxStringLength = 64
    /// Longer than any game; anything above is clamped.
    public static let maxDurationMs = 7 * 24 * 60 * 60 * 1000
    public static let maxSecondsSince = 30 * 24 * 60 * 60

    public var cause: Cause?
    /// WebSocket close code the page saw (1000–4999).
    public var closeCode: Int?
    /// WebSocket close reason the page saw, at most `maxStringLength` characters.
    public var closeReason: String?
    /// How long the connection had been joined.
    public var connectedMs: Int?
    /// How long the page was hidden during that connection.
    public var hiddenMs: Int?
    /// Whether the page was hidden when the connection was lost.
    public var hiddenAtLoss: Bool?
    /// Seconds between the loss and this `join`.
    public var secondsSince: Int?

    public init(
        cause: Cause? = nil,
        closeCode: Int? = nil,
        closeReason: String? = nil,
        connectedMs: Int? = nil,
        hiddenMs: Int? = nil,
        hiddenAtLoss: Bool? = nil,
        secondsSince: Int? = nil
    ) {
        self.cause = cause
        self.closeCode = closeCode
        self.closeReason = closeReason
        self.connectedMs = connectedMs
        self.hiddenMs = hiddenMs
        self.hiddenAtLoss = hiddenAtLoss
        self.secondsSince = secondsSince
    }

    /// True when nothing usable was sent.
    public var isEmpty: Bool {
        cause == nil && closeCode == nil && closeReason == nil && connectedMs == nil
            && hiddenMs == nil && hiddenAtLoss == nil && secondsSince == nil
    }

    // MARK: - Summary

    /// The report in plain words, e.g. "previous connection lost 41s ago after
    /// 12m — the phone heard nothing from the Mac for 5s (watchdog); page was
    /// hidden for 38s (screen locked or app switched)".
    public var summary: String {
        var head = "previous connection"
        switch cause {
        case .removed: head += " was removed by the host"
        case .sessionEnded: head += " ended with the game session"
        default: head += " lost"
        }
        if let secondsSince { head += " \(LogDuration.format(TimeInterval(secondsSince))) ago" }
        if let connectedMs { head += " after \(LogDuration.format(TimeInterval(connectedMs) / 1000))" }

        var parts = [head]
        if let causeText { parts[0] += " — \(causeText)" }

        if hiddenAtLoss == true {
            let duration = hiddenMs.map { " (hidden for \(LogDuration.format(TimeInterval($0) / 1000)))" } ?? ""
            parts.append("page was hidden when it was lost\(duration): screen locked or app switched")
        } else if let hiddenMs, hiddenMs >= 1000 {
            parts.append("page was hidden for \(LogDuration.format(TimeInterval(hiddenMs) / 1000)) (screen locked or app switched)")
        } else if hiddenMs != nil || hiddenAtLoss == false {
            parts.append("page stayed visible")
        }
        return parts.joined(separator: "; ")
    }

    private var causeText: String? {
        switch cause {
        case .watchdog:
            return "the phone heard nothing from the Mac for 5s (watchdog)"
        case .socketClose:
            var text = "the socket closed (\(WebSocketCloseCode.describe(closeCode.map { UInt16(clamping: $0) })))"
            if let closeReason, !closeReason.isEmpty { text += " “\(closeReason)”" }
            return text
        case .socketError:
            return "the socket reported an error"
        case .removed, .sessionEnded, nil:
            return nil
        }
    }
}

extension PhoneDisconnectReport: Decodable {

    private enum CodingKeys: String, CodingKey {
        case cause, closeCode, closeReason, connectedMs, hiddenMs, hiddenAtLoss, secondsSince
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each field is read on its own, so one bad value only loses that field.
        func int(_ key: CodingKeys, in range: ClosedRange<Int>) -> Int? {
            let value: Int
            if let whole = try? container.decodeIfPresent(Int.self, forKey: key) {
                value = whole
            } else if let number = try? container.decodeIfPresent(Double.self, forKey: key), number.isFinite {
                // Pages send JS numbers, which may have a fraction.
                value = Int(max(-1e15, min(1e15, number)))
            } else {
                return nil
            }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        func string(_ key: CodingKeys) -> String? {
            guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            let trimmed = String(text.prefix(Self.maxStringLength))
            return trimmed.isEmpty ? nil : trimmed
        }

        cause = string(.cause).flatMap(Cause.init(rawValue:))
        closeCode = int(.closeCode, in: 0...4999)
        closeReason = string(.closeReason)
        connectedMs = int(.connectedMs, in: 0...Self.maxDurationMs)
        hiddenMs = int(.hiddenMs, in: 0...Self.maxDurationMs)
        hiddenAtLoss = try? container.decodeIfPresent(Bool.self, forKey: .hiddenAtLoss)
        secondsSince = int(.secondsSince, in: 0...Self.maxSecondsSince)
    }
}
