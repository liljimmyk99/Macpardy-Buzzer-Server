//
//  WebSocketCloseCode.swift
//  BuzzerCore
//
//  Reading and describing WebSocket close status codes (RFC 6455 §7.4), for
//  disconnect log lines on the Mac and in the phone's `diag` report.
//

import Foundation

public enum WebSocketCloseCode {

    /// The status code at the start of a close frame's payload (RFC 6455 §5.5.1),
    /// or nil when the payload is too short to carry one.
    public static func fromPayload(_ payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        let bytes = [UInt8](payload.prefix(2))
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    /// "1001 going away: tab closed, reloaded or navigated away", "code 4321",
    /// or "no status code".
    public static func describe(_ code: UInt16?) -> String {
        guard let code else { return "no status code" }
        let meaning: String? = switch code {
        case 1000: "normal closure"
        case 1001: "going away: tab closed, reloaded or navigated away"
        case 1002: "protocol error"
        case 1003: "unsupported data"
        case 1005: "no status code"
        case 1006: "abnormal closure"
        case 1007: "invalid payload"
        case 1008: "policy violation"
        case 1009: "message too big"
        case 1011: "internal error"
        default: nil
        }
        return meaning.map { "\(code) \($0)" } ?? "code \(code)"
    }
}
