//
//  WebSocketSessions.swift
//  BuzzerServerNIO
//
//  One upgraded WebSocket, for a phone or a Mac (#103). Frames are read in
//  order on one task and handed to the hub; anything the hub sends goes
//  through a queue that one writer task drains, so `send` can be called from
//  anywhere without blocking.
//

import BuzzerCore
import BuzzerHostProtocol
import BuzzerHub
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOWebSocket

/// NIO's frame; BuzzerCore has its own `WebSocketFrame` for the app's parser.
typealias WSFrame = NIOWebSocket.WebSocketFrame

/// What the writer task does next.
enum OutgoingFrame: Sendable {
    case frame(WSFrame)
    /// Sends a close frame with `code`, then ends the connection.
    case close(code: WebSocketErrorCode)
}

// MARK: - Connections

/// A phone, as the room sees it.
final class NIOPhoneConnection: BuzzerConnection {
    let id = UUID()
    let remoteKey: String
    let userAgent: String?
    private let outgoing: AsyncStream<OutgoingFrame>.Continuation

    init(remoteKey: String, userAgent: String?, outgoing: AsyncStream<OutgoingFrame>.Continuation) {
        self.remoteKey = remoteKey
        self.userAgent = userAgent
        self.outgoing = outgoing
    }

    func send(_ message: ServerMessage, closeAfterSending: Bool) {
        if let data = try? message.jsonData() {
            outgoing.yield(.frame(WSFrame.text(data)))
        }
        if closeAfterSending {
            outgoing.yield(.close(code: .normalClosure))
        }
    }

    func close(reason: DisconnectReason) {
        let code: WebSocketErrorCode = switch reason {
        case .oversizedMessage: .messageTooLarge
        case .invalidFrame: .protocolError
        case .serverBusy: .unexpectedServerError
        default: .normalClosure
        }
        outgoing.yield(.close(code: code))
    }
}

/// A Mac, as the hub sees it.
final class NIOHostConnection: HostConnection {
    let id = UUID()
    let remoteKey: String
    private let outgoing: AsyncStream<OutgoingFrame>.Continuation

    init(remoteKey: String, outgoing: AsyncStream<OutgoingFrame>.Continuation) {
        self.remoteKey = remoteKey
        self.outgoing = outgoing
    }

    func send(_ event: HostEvent) {
        if let data = try? JSONEncoder().encode(event) {
            outgoing.yield(.frame(WSFrame.text(data)))
        }
    }

    func close() {
        outgoing.yield(.close(code: .normalClosure))
    }
}

extension WSFrame {
    static func text(_ data: Data) -> WSFrame {
        WSFrame(fin: true, opcode: .text, data: ByteBuffer(bytes: data))
    }

    static func close(_ code: WebSocketErrorCode) -> WSFrame {
        var buffer = ByteBuffer()
        buffer.write(webSocketErrorCode: code)
        return WSFrame(fin: true, opcode: .connectionClose, data: buffer)
    }
}

// MARK: - Session loop

/// Who is on the other end, and where its messages go.
protocol WebSocketPeer: Sendable {
    /// Largest message, after joining fragments.
    var maxMessageSize: Int { get }
    func received(text: Data) async
    func receivedPong() async
    /// The connection ended; `reason` is why, as far as the server saw.
    func ended(_ reason: DisconnectReason) async
}

struct PhonePeer: WebSocketPeer {
    let hub: BuzzerHub
    let id: UUID
    var maxMessageSize: Int { WebSocketFrameParser.maxPayload }
    func received(text: Data) async { await hub.phoneReceived(text: text, from: id) }
    func receivedPong() async { await hub.phonePong(from: id) }
    func ended(_ reason: DisconnectReason) async { await hub.phoneDisconnected(id, reason: reason) }
}

struct HostPeer: WebSocketPeer {
    let hub: BuzzerHub
    let id: UUID
    var maxMessageSize: Int { BuzzerHostConstants.maxHostMessageSize }
    func received(text: Data) async { await hub.hostReceived(text: text, from: id) }
    func receivedPong() async {}
    func ended(_ reason: DisconnectReason) async { await hub.hostDisconnected(id) }
}

enum WebSocketSession {

    /// Runs one WebSocket until either side closes it.
    ///
    /// The reader stays on this task (the inbound stream can't be sent to
    /// another); the writer is a child task. When the server closes, the
    /// writer sends the close frame and closes the channel, which ends the
    /// reader. When the phone closes, the reader queues the close reply and
    /// finishes the queue, which ends the writer.
    static func run(
        _ channel: NIOAsyncChannel<WSFrame, WSFrame>,
        peer: some WebSocketPeer,
        outgoing: AsyncStream<OutgoingFrame>,
        outgoingContinuation: AsyncStream<OutgoingFrame>.Continuation
    ) async {
        var reason = DisconnectReason.connectionEnded
        let underlying = channel.channel
        do {
            reason = try await channel.executeThenClose { inbound, outbound in
                await withTaskGroup(of: Void.self, returning: DisconnectReason.self) { group in
                    group.addTask {
                        for await item in outgoing {
                            switch item {
                            case .frame(let frame):
                                do { try await outbound.write(frame) } catch { return }
                            case .close(let code):
                                try? await outbound.write(.close(code))
                                underlying.close(promise: nil)
                                return
                            }
                        }
                    }
                    let ended = await read(inbound, peer: peer, pongs: outgoingContinuation)
                    if case .phoneClosed = ended {
                        // Answer the close handshake before the channel closes.
                        outgoingContinuation.yield(.close(code: .normalClosure))
                    }
                    outgoingContinuation.finish()
                    await group.waitForAll()
                    return ended
                }
            }
        } catch {
            if case .connectionEnded = reason { reason = .networkError(String(describing: error)) }
        }
        outgoingContinuation.finish()
        await peer.ended(reason)
    }

    /// Reads until the connection closes; returns why it did.
    private static func read(
        _ inbound: NIOAsyncChannelInboundStream<WSFrame>,
        peer: some WebSocketPeer,
        pongs: AsyncStream<OutgoingFrame>.Continuation
    ) async -> DisconnectReason {
        var fragments: ByteBuffer?
        do {
            for try await frame in inbound {
                switch frame.opcode {
                case .text:
                    guard frame.length <= peer.maxMessageSize else { return .oversizedMessage }
                    if frame.fin {
                        await peer.received(text: Data(buffer: frame.unmaskedData))
                    } else {
                        fragments = frame.unmaskedData
                    }
                case .continuation:
                    guard var buffer = fragments else { continue }
                    var data = frame.unmaskedData
                    buffer.writeBuffer(&data)
                    guard buffer.readableBytes <= peer.maxMessageSize else { return .oversizedMessage }
                    if frame.fin {
                        fragments = nil
                        await peer.received(text: Data(buffer: buffer))
                    } else {
                        fragments = buffer
                    }
                case .connectionClose:
                    var data = frame.unmaskedData
                    let code = data.readInteger(as: UInt16.self)
                    return .phoneClosed(code: code)
                case .ping:
                    pongs.yield(.frame(WSFrame(fin: true, opcode: .pong, data: frame.unmaskedData)))
                case .pong:
                    await peer.receivedPong()
                default:
                    // Binary frames aren't part of either protocol.
                    continue
                }
            }
        } catch let error as NIOWebSocketError {
            return error == .invalidFrameLength ? .oversizedMessage : .invalidFrame
        } catch {
            return .networkError(String(describing: error))
        }
        return .connectionEnded
    }
}
