//
//  main.swift
//  macpardy-buzzer-server
//
//  The self-hosted buzzer server (#103). Run behind a reverse proxy that
//  handles HTTPS; see Packages/MacpardyBuzzer/README.md.
//
//    macpardy-buzzer-server [options]       run the server (--help for options)
//    macpardy-buzzer-server healthcheck     exit 0 if the local server is healthy
//

import BuzzerHub
import BuzzerServerNIO
import Dispatch
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

var arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

// The health check only needs the port.
if arguments.first == "healthcheck" {
    let port = environment["MACPARDY_PORT"].flatMap(Int.init) ?? 8472
    exit(await HealthCheck.run(port: port) ? 0 : 1)
}

let configuration: ServerConfiguration
do {
    configuration = try ServerConfiguration.parse(arguments: arguments, environment: environment)
} catch .helpRequested {
    print(ServerConfiguration.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("macpardy-buzzer-server: \(error.description)\n".utf8))
    exit(64)   // EX_USAGE
}

let logger = StreamBuzzerLogger(minimumLevel: configuration.logLevel)
let hub = BuzzerHub(configuration: configuration, logger: logger)
let server = BuzzerWebServer(configuration: configuration, hub: hub, logger: logger)
logger.notice("Macpardy buzzer server starting: \(configuration.logDescription)")
if !configuration.trustForwardedFor {
    logger.notice("X-Forwarded-For is ignored; behind a reverse proxy every phone shares the proxy's address for rate limits. Set MACPARDY_TRUST_FORWARDED_FOR=true there.")
}

let serverTask = Task {
    do {
        try await server.run()
    } catch is CancellationError {
    } catch {
        logger.error("Server stopped: \(error)")
        exit(1)
    }
}

// SIGTERM (docker stop) and SIGINT (Ctrl-C): end rooms gracefully so phones
// see "session ended" and Macs see `roomClosed`, then stop listening.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    // Explicitly @Sendable: top-level code is main-actor isolated, and this
    // runs on a global queue.
    source.setEventHandler { @Sendable [hub, logger, serverTask] in
        logger.notice("Shutting down")
        Task {
            await hub.stop()
            // Give the closing frames a moment to go out.
            try? await Task.sleep(for: .milliseconds(500))
            serverTask.cancel()
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

await serverTask.value
