//
//  WebSocketFrameParser.swift
//  BuzzerCore
//
//  Incremental RFC 6455 frame parser. TCP may deliver a frame split across
//  reads or several frames in one read, so callers append received bytes to a
//  buffer and repeatedly parse from its front.
//

import Foundation

public struct WebSocketFrame: Equatable, Sendable {
    public let fin: Bool
    public let opcode: UInt8
    /// Unmasked payload.
    public let payload: Data


    public init(fin: Bool, opcode: UInt8, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WebSocketFrameParser: Sendable {

    public enum Result: Equatable, Sendable {
        /// A complete frame and the number of buffer bytes it occupied.
        case frame(WebSocketFrame, consumed: Int)
        /// More bytes are needed.
        case incomplete
        /// The frame is malformed or exceeds `maxPayload`; the connection should be closed.
        case invalid
    }

    /// Largest payload accepted. Buzzer messages are tiny JSON objects.
    public static let maxPayload = 65_536

    public static func parse(_ data: Data) -> Result {
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return .incomplete }

        let fin = (bytes[0] & 0x80) != 0
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var payloadLen = Int(bytes[1] & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard bytes.count >= 4 else { return .incomplete }
            payloadLen = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if payloadLen == 127 {
            guard bytes.count >= 10 else { return .incomplete }
            var length: UInt64 = 0
            for i in 0..<8 { length = length << 8 | UInt64(bytes[2 + i]) }
            guard length <= UInt64(maxPayload) else { return .invalid }
            payloadLen = Int(length)
            offset = 10
        }

        guard payloadLen <= maxPayload else { return .invalid }

        var maskingKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return .incomplete }
            maskingKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        guard data.count >= offset + payloadLen else { return .incomplete }

        let start = data.startIndex + offset
        var payload = Data(data[start..<(start + payloadLen)])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskingKey[i % 4]
            }
        }

        return .frame(
            WebSocketFrame(fin: fin, opcode: opcode, payload: payload),
            consumed: offset + payloadLen
        )
    }
}
