//
//  HealthCheck.swift
//  BuzzerServerNIO
//
//  `macpardy-buzzer-server healthcheck`: asks a running server for /healthz,
//  so the Docker image's HEALTHCHECK doesn't need curl (#103).
//

import BuzzerHostProtocol
import NIOCore
import NIOPosix

public enum HealthCheck {

    /// Whether the server on `host:port` answers /healthz with 200.
    public static func run(host: String = "127.0.0.1", port: Int) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectTimeout(.seconds(3))
                .connect(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                }
            return try await channel.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "GET \(BuzzerHostConstants.healthPath) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
                var response = ""
                for try await var chunk in inbound {
                    response += chunk.readString(length: chunk.readableBytes) ?? ""
                    if response.contains("\r\n") { break }
                }
                return response.hasPrefix("HTTP/1.1 200")
            }
        } catch {
            return false
        }
    }
}
