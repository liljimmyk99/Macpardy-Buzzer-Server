//
//  WebSocketFrameParserTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class WebSocketFrameParserTests: XCTestCase {

    /// Builds a client-style (masked) text frame.
    private func maskedFrame(_ text: String, opcode: UInt8 = 0x1, fin: Bool = true) -> Data {
        let payload = Array(text.utf8)
        let key: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        var frame = Data([(fin ? 0x80 : 0x00) | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(contentsOf: key)
        for (i, byte) in payload.enumerated() { frame.append(byte ^ key[i % 4]) }
        return frame
    }

    func testParsesMaskedTextFrame() {
        let data = maskedFrame("hello")
        guard case .frame(let frame, let consumed) = WebSocketFrameParser.parse(data) else {
            return XCTFail("expected a frame")
        }
        XCTAssertEqual(frame.opcode, 0x1)
        XCTAssertTrue(frame.fin)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "hello")
        XCTAssertEqual(consumed, data.count)
    }

    func testSplitFrameIsIncompleteUntilAllBytesArrive() {
        let data = maskedFrame("hello")
        for cut in 0..<data.count {
            XCTAssertEqual(WebSocketFrameParser.parse(data.prefix(cut)), .incomplete, "cut at \(cut)")
        }
        guard case .frame = WebSocketFrameParser.parse(data) else { return XCTFail("expected a frame") }
    }

    func testCoalescedFramesParseOneAtATime() {
        let first = maskedFrame("one")
        let second = maskedFrame("two")
        var buffer = first + second

        guard case .frame(let a, let usedA) = WebSocketFrameParser.parse(buffer) else {
            return XCTFail("expected first frame")
        }
        XCTAssertEqual(String(decoding: a.payload, as: UTF8.self), "one")
        XCTAssertEqual(usedA, first.count)

        buffer = Data(buffer.dropFirst(usedA))
        guard case .frame(let b, _) = WebSocketFrameParser.parse(buffer) else {
            return XCTFail("expected second frame")
        }
        XCTAssertEqual(String(decoding: b.payload, as: UTF8.self), "two")
    }

    func testSixteenBitLengthFrame() {
        let text = String(repeating: "a", count: 300)
        guard case .frame(let frame, _) = WebSocketFrameParser.parse(maskedFrame(text)) else {
            return XCTFail("expected a frame")
        }
        XCTAssertEqual(frame.payload.count, 300)
    }

    func testOversizedLengthIsInvalid() {
        var data = Data([0x81, 0x80 | 127] as [UInt8])
        data.append(contentsOf: [0, 0, 0, 0, 0, 1, 0, 1])   // 65_537 bytes
        data.append(contentsOf: [0, 0, 0, 0])
        XCTAssertEqual(WebSocketFrameParser.parse(data), .invalid)
    }

    func testFragmentFlagsAreReported() {
        guard case .frame(let frame, _) = WebSocketFrameParser.parse(maskedFrame("ab", fin: false)) else {
            return XCTFail("expected a frame")
        }
        XCTAssertFalse(frame.fin)
    }
}
