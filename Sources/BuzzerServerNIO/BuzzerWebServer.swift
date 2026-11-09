//
//  BuzzerWebServer.swift
//  BuzzerServerNIO
//
//  The self-hosted server's transport on SwiftNIO (#103): plain HTTP and
//  WebSocket on one port. A reverse proxy in front handles HTTPS.
//
//  Routes
//  ──────
//  • GET /, /index.html    buzzer.html
//  • GET /healthz          200 "ok" (Docker health check)
//  • WebSocket /ws         phones (phone protocol, as with the built-in server)
//  • WebSocket /host       the Mac (host protocol)
//  • anything else         404 (405 for other methods)
//

import BuzzerCore
import BuzzerHostProtocol
import BuzzerHub
import BuzzerWebPage
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public struct BuzzerWebServer: Sendable {

    private let configuration: ServerConfiguration
    private let hub: BuzzerHub
    private let logger: any BuzzerLogging
    private let page: Data

    public init(configuration: ServerConfiguration, hub: BuzzerHub, logger: any BuzzerLogging) {
        self.configuration = configuration
        self.hub = hub
        self.logger = logger
        if let html = BuzzerWebPage.html {
            page = html
        } else {
            logger.error("buzzer.html is missing from the build; phones will get an error page")
            page = BuzzerWebPage.missingPage
        }
    }

    private enum Route: Sendable {
        case phone(remoteKey: String, userAgent: String?)
        case host(remoteKey: String)
    }

    private enum Connection: Sendable {
        case webSocket(NIOAsyncChannel<WSFrame, WSFrame>, Route)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, remoteKey: String)
    }

    /// Listens until the task is cancelled. `onListening` gets the bound port
    /// (useful with port 0 in tests).
    public func run(onListening: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let trust = configuration.trustForwardedFor
        let maxFrameSize = BuzzerHostConstants.maxHostMessageSize
        let server: NIOAsyncChannel<EventLoopFuture<Connection>, Never> = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(.backlog, value: 256)
            .bind(host: configuration.bindAddress, port: configuration.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<Connection>(
                        maxFrameSize: maxFrameSize,
                        shouldUpgrade: { channel, head in
                            let path = Self.path(of: head.uri)
                            let known = path == BuzzerHostConstants.phonePath || path == BuzzerHostConstants.hostPath
                            return channel.eventLoop.makeSucceededFuture(known ? HTTPHeaders() : nil)
                        },
                        upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeCompletedFuture {
                                let remoteKey = Self.remoteKey(of: channel, head: head, trust: trust)
                                let route: Route = Self.path(of: head.uri) == BuzzerHostConstants.hostPath
                                    ? .host(remoteKey: remoteKey)
                                    : .phone(remoteKey: remoteKey, userAgent: head.headers.first(name: "user-agent"))
                                let async = try NIOAsyncChannel<WSFrame, WSFrame>(wrappingChannelSynchronously: channel)
                                return Connection.webSocket(async, route)
                            }
                        }
                    )
                    let upgrade = NIOTypedHTTPServerUpgradeConfiguration<Connection>(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                let async = try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                                    wrappingChannelSynchronously: channel
                                )
                                let peer = channel.remoteAddress?.ipAddress ?? "unknown address"
                                return Connection.http(async, remoteKey: peer)
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: upgrade)
                    )
                }
            }

        let port = server.channel.localAddress?.port ?? configuration.port
        logger.notice("Listening on \(configuration.bindAddress):\(port)")
        onListening(port)
        await hub.start()

        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { inbound in
                for try await negotiation in inbound {
                    group.addTask {
                        await handle(negotiation)
                    }
                }
            }
        }
    }

    // MARK: - Connections

    private func handle(_ negotiation: EventLoopFuture<Connection>) async {
        let connection: Connection
        do {
            connection = try await negotiation.get()
        } catch {
            logger.debug("Connection ended before a full request: \(error)")
            return
        }
        switch connection {
        case .webSocket(let channel, .phone(let remoteKey, let userAgent)):
            let (outgoing, continuation) = AsyncStream.makeStream(of: OutgoingFrame.self)
            let phone = NIOPhoneConnection(remoteKey: remoteKey, userAgent: userAgent, outgoing: continuation)
            // A refused phone is already closed; the close frame it queued still goes out.
            await hub.phoneConnected(phone)
            await WebSocketSession.run(channel, peer: PhonePeer(hub: hub, id: phone.id), outgoing: outgoing, outgoingContinuation: continuation)

        case .webSocket(let channel, .host(let remoteKey)):
            let (outgoing, continuation) = AsyncStream.makeStream(of: OutgoingFrame.self)
            let host = NIOHostConnection(remoteKey: remoteKey, outgoing: continuation)
            await hub.hostConnected(host)
            await WebSocketSession.run(channel, peer: HostPeer(hub: hub, id: host.id), outgoing: outgoing, outgoingContinuation: continuation)

        case .http(let channel, let peer):
            await serveHTTP(channel, peer: peer)
        }
    }

    /// Answers one request, then closes the connection.
    private func serveHTTP(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        peer: String
    ) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
                var request: HTTPRequestHead?
                for try await part in inbound {
                    switch part {
                    case .head(let head):
                        request = head
                    case .body:
                        continue
                    case .end:
                        guard let head = request else { return }
                        let (status, contentType, body) = response(to: head, peer: peer)
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: contentType)
                        headers.add(name: "Content-Length", value: String(body.readableBytes))
                        headers.add(name: "Connection", value: "close")
                        headers.add(name: "Cache-Control", value: "no-store")
                        headers.add(name: "X-Content-Type-Options", value: "nosniff")
                        headers.add(name: "Referrer-Policy", value: "no-referrer")
                        try await outbound.write(.head(HTTPResponseHead(version: head.version, status: status, headers: headers)))
                        if head.method != .HEAD, body.readableBytes > 0 {
                            try await outbound.write(.body(.byteBuffer(body)))
                        }
                        try await outbound.write(.end(nil))
                        return
                    }
                }
            }
        } catch {
            logger.debug("HTTP request from \(peer) failed: \(error)", remote: peer)
        }
    }

    private func response(to head: HTTPRequestHead, peer: String) -> (HTTPResponseStatus, String, ByteBuffer) {
        guard head.method == .GET || head.method == .HEAD else {
            return (.methodNotAllowed, "text/plain; charset=utf-8", ByteBuffer(string: "Method not allowed\n"))
        }
        switch Self.path(of: head.uri) {
        case "/", "/index.html":
            let remote = ForwardedFor.clientAddress(header: Self.forwardedFor(head.headers), peer: peer, trust: configuration.trustForwardedFor)
            logger.info("Page requested by \(remote) (\(UserAgentSummary.shorten(head.headers.first(name: "user-agent"))))", remote: remote)
            return (.ok, "text/html; charset=utf-8", ByteBuffer(bytes: page))
        case BuzzerHostConstants.healthPath:
            return (.ok, "text/plain; charset=utf-8", ByteBuffer(string: "ok\n"))
        default:
            return (.notFound, "text/plain; charset=utf-8", ByteBuffer(string: "Not found\n"))
        }
    }

    // MARK: - Helpers

    /// The URI's path, without the query.
    static func path(of uri: String) -> String {
        String(uri.prefix { $0 != "?" && $0 != "#" })
    }

    /// Every `X-Forwarded-For` value, joined, so the last entry is the proxy's.
    static func forwardedFor(_ headers: HTTPHeaders) -> String? {
        let values = headers[canonicalForm: "x-forwarded-for"]
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    static func remoteKey(of channel: Channel, head: HTTPRequestHead, trust: Bool) -> String {
        let peer = channel.remoteAddress?.ipAddress ?? "unknown address"
        return ForwardedFor.clientAddress(header: forwardedFor(head.headers), peer: peer, trust: trust)
    }
}
