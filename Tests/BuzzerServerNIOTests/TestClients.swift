//
//  TestClients.swift
//  BuzzerServerNIOTests
//
//  Raw-socket HTTP and WebSocket clients for testing the server over real
//  sockets (#103). Hand-rolled on NIO rather than URLSession so the tests run
//  the same on Linux.
//

import BuzzerCore
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

/// Sends one HTTP request and returns the whole response as text.
func httpRequest(port: Int, _ request: String) async throws -> String {
    let channel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    return try await channel.executeThenClose { inbound, outbound in
        try await outbound.write(ByteBuffer(string: request))
        var response = ""
        for try await var chunk in inbound {
            response += chunk.readString(length: chunk.readableBytes) ?? ""
        }
        return response
    }
}

/// A WebSocket client that records every text message it gets and answers
/// app-level pings.
final class TestWebSocket: Sendable {

    private struct State {
        var handshake: String?
        var texts: [String] = []
        var closed = false
    }

    private let state = Mutex(State())
    private let outgoing: AsyncStream<ByteBuffer>.Continuation
    private let task: Task<Void, Never>

    private init(outgoing: AsyncStream<ByteBuffer>.Continuation, task: Task<Void, Never>) {
        self.outgoing = outgoing
        self.task = task
    }

    var texts: [String] { state.withLock { $0.texts } }
    var isClosed: Bool { state.withLock { $0.closed } }
    var handshake: String? { state.withLock { $0.handshake } }

    static func connect(port: Int, path: String, headers: [String: String] = [:]) async throws -> TestWebSocket {
        let channel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        let box = Mutex<TestWebSocket?>(nil)
        let task = Task<Void, Never> {
            try? await channel.executeThenClose { inbound, outbound in
                // Reader on this task (the inbound stream can't be sent), writer as a child.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await buffer in stream {
                            try? await outbound.write(buffer)
                        }
                    }
                    var buffer = Data()
                    do {
                        for try await var chunk in inbound {
                            buffer.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
                            box.withLock { $0 }?.consume(&buffer)
                        }
                    } catch {}
                    box.withLock { $0 }?.state.withLock { $0.closed = true }
                    group.cancelAll()
                }
            }
        }
        let socket = TestWebSocket(outgoing: continuation, task: task)
        box.withLock { $0 = socket }

        var request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        continuation.yield(ByteBuffer(string: request))
        await socket.wait("handshake") { socket.handshake != nil || socket.isClosed }
        return socket
    }

    /// The handshake, then every complete frame at the front of `buffer`.
    private func consume(_ buffer: inout Data) {
        if handshake == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end.upperBound...])
            state.withLock { $0.handshake = head }
        }
        while case .frame(let frame, let consumed) = WebSocketFrameParser.parse(buffer) {
            buffer = Data(buffer.dropFirst(consumed))
            switch frame.opcode {
            case 0x1:
                let text = String(decoding: frame.payload, as: UTF8.self)
                if text == #"{"type":"ping"}"# {
                    send(#"{"type":"pong"}"#)
                } else {
                    state.withLock { $0.texts.append(text) }
                }
            case 0x8:
                state.withLock { $0.closed = true }
            default:
                break
            }
        }
    }

    var upgraded: Bool { handshake?.hasPrefix("HTTP/1.1 101") ?? false }

    /// Sends a masked text frame, as a browser does.
    func send(_ text: String) {
        outgoing.yield(Self.maskedFrame(opcode: 0x1, payload: Array(text.utf8)))
    }

    func close() {
        outgoing.yield(Self.maskedFrame(opcode: 0x8, payload: [0x03, 0xE8]))
    }

    func cancel() {
        outgoing.finish()
        task.cancel()
    }

    static func maskedFrame(opcode: UInt8, payload: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(0x80 | opcode)
        if payload.count < 126 {
            buffer.writeInteger(UInt8(0x80 | payload.count))
        } else if payload.count <= Int(UInt16.max) {
            buffer.writeInteger(UInt8(0x80 | 126))
            buffer.writeInteger(UInt16(payload.count))
        } else {
            buffer.writeInteger(UInt8(0x80 | 127))
            buffer.writeInteger(UInt64(payload.count))
        }
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        buffer.writeBytes(mask)
        buffer.writeBytes(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return buffer
    }

    /// The first received message whose JSON `type` is `type`.
    func message(ofType type: String) -> [String: Any]? {
        texts.lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == type }
    }

    func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) async {
        for _ in 0..<3_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(what); got \(texts)", file: file, line: line)
    }

    func waitForMessage(ofType type: String, file: StaticString = #filePath, line: UInt = #line) async -> [String: Any]? {
        await wait(type, file: file, line: line) { message(ofType: type) != nil }
        return message(ofType: type)
    }
}
