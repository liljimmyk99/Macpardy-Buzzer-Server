//
//  BuzzerHub.swift
//  BuzzerHub
//
//  A self-hosted server's rooms, with no I/O (#103). The transport hands it
//  phone and host connections and their text messages; it routes each phone
//  to its room by Game PIN and speaks the host protocol with each Mac.
//
//  Responsibilities
//  ─────────────────
//  • Opens a `BuzzerRoom` per authenticated host, with a Game PIN no other
//    room is using, up to `maxRooms`
//  • Checks the host token (constant time) and the host protocol version,
//    and locks out addresses that keep sending a wrong token
//  • Routes a phone's `join` to the room its `code` names, up to
//    `maxPhonesPerRoom`; wrong PINs are rate limited per address across the
//    whole server, not per room
//  • Forwards host commands to the room and room events to the host
//  • Pings hosts; a host that drops or stops answering leaves its room
//    waiting for the grace period, with phones paused. A `hello` with the
//    room's resume token takes it back; after the grace period phones get
//    `sessionEnded` and the room is removed
//  • Closes phone sockets that never join and hosts that never say `hello`
//

import BuzzerCore
import BuzzerHostProtocol
import Foundation

// MARK: - HostConnection

/// One Mac's connection, as the hub sees it. The transport conforms to this.
public protocol HostConnection: Sendable {
    /// Unique for the connection's lifetime.
    var id: UUID { get }
    /// The Mac's address, after `X-Forwarded-For` if trusted. Keys the token rate limit.
    var remoteKey: String { get }
    func send(_ event: HostEvent)
    /// Closes the connection once everything sent so far has gone out.
    func close()
}

// MARK: - BuzzerHub

public actor BuzzerHub {

    private let configuration: ServerConfiguration
    private let logger: any BuzzerLogging
    private let scheduler: any BuzzerScheduler
    private let makeJoinCode: @Sendable () -> String
    private let makeResumeToken: @Sendable () -> String
    private let randomIndex: @Sendable (Int) -> Int

    private var rooms: [UUID: HostedRoom] = [:]
    private var roomIDByCode: [String: UUID] = [:]
    private var roomIDByResumeToken: [String: UUID] = [:]

    /// Phones that opened a socket but haven't joined a room.
    private var pendingPhones: [UUID: PendingPhone] = [:]
    /// Joined phones' rooms, by connection.
    private var phoneRoomIDs: [UUID: UUID] = [:]
    /// Host connections, before and after `hello`.
    private var hosts: [UUID: HostLink] = [:]

    /// Wrong Game PINs, per address, across every room.
    private var codeLimiter = AttemptRateLimiter(
        maxAttempts: BuzzerConstants.maxCodeAttempts,
        window: BuzzerConstants.codeAttemptWindow,
        lockout: BuzzerConstants.rateLimitLockout
    )
    /// Wrong host tokens, per address.
    private var tokenLimiter = AttemptRateLimiter(
        maxAttempts: BuzzerHostConstants.maxTokenAttempts,
        window: BuzzerHostConstants.tokenAttemptWindow,
        lockout: BuzzerHostConstants.tokenLockout
    )

    private var tick: ScheduledWork?
    private var isStopped = false

    /// How often the hub checks timeouts and pings hosts.
    static let tickInterval: TimeInterval = 1
    /// Room events kept for a host that is away, beyond its latest state.
    static let maxBufferedEvents = 500

    // MARK: - Init

    public init(
        configuration: ServerConfiguration,
        logger: any BuzzerLogging = NoBuzzerLogging(),
        scheduler: any BuzzerScheduler = SystemBuzzerScheduler(),
        makeJoinCode: @escaping @Sendable () -> String = { JoinCodeGenerator.generate() },
        makeResumeToken: @escaping @Sendable () -> String = { SecureToken.generate() },
        randomIndex: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.configuration = configuration
        self.logger = logger
        self.scheduler = scheduler
        self.makeJoinCode = makeJoinCode
        self.makeResumeToken = makeResumeToken
        self.randomIndex = randomIndex
    }

    // MARK: - Lifecycle

    /// Starts the timeout and heartbeat checks. Call once the transport listens.
    public func start() {
        guard !isStopped, tick == nil else { return }
        scheduleTick()
    }

    /// Ends every room: hosts get `roomClosed`, phones `sessionEnded`.
    public func stop() async {
        isStopped = true
        tick?.cancel()
        tick = nil
        for room in Array(rooms.values) {
            await closeRoom(room, reason: "serverStopping")
        }
        for pending in pendingPhones.values {
            pending.connection.close(reason: .serverStopped)
        }
        pendingPhones.removeAll()
        for host in hosts.values {
            host.connection.close()
        }
        hosts.removeAll()
    }

    /// Open rooms, for tests and the startup log.
    public var roomCount: Int { rooms.count }

    // MARK: - Phones (transport → hub)

    /// A phone opened a WebSocket. It has `BuzzerConstants.joinTTL` to `join`.
    /// Returns false when the hub refused it; the connection is already closed.
    @discardableResult
    public func phoneConnected(_ connection: any BuzzerConnection) -> Bool {
        guard !isStopped else {
            connection.close(reason: .serverStopped)
            return false
        }
        guard pendingPhones.count < configuration.maxPendingPhones else {
            logger.warning("Phone connection from \(connection.remoteKey) refused: \(pendingPhones.count) already waiting to join", remote: connection.remoteKey)
            connection.close(reason: .serverBusy)
            return false
        }
        pendingPhones[connection.id] = PendingPhone(connection: connection, connectedAt: scheduler.now)
        logger.debug("Phone connected: \(connection.remoteKey) #\(Self.shortID(connection.id)), \(UserAgentSummary.shorten(connection.userAgent))", remote: connection.remoteKey)
        return true
    }

    /// One text message from a phone.
    public func phoneReceived(text payload: Data, from connectionID: UUID) async {
        if let roomID = phoneRoomIDs[connectionID] {
            await rooms[roomID]?.room.receive(text: payload, from: connectionID)
            return
        }
        guard let pending = pendingPhones[connectionID] else { return }
        // Before joining, only `join` matters; anything else (pongs, page
        // events, garbage) is dropped.
        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: payload),
              case let .join(code, version, _, _) = message else { return }
        await handleJoin(message, code: code, version: version, from: pending)
    }

    /// A WebSocket pong frame from a phone.
    public func phonePong(from connectionID: UUID) async {
        guard let roomID = phoneRoomIDs[connectionID] else { return }
        await rooms[roomID]?.room.receivedPong(from: connectionID)
    }

    /// The phone's connection ended on the transport's side.
    public func phoneDisconnected(_ connectionID: UUID, reason: DisconnectReason) async {
        if let pending = pendingPhones.removeValue(forKey: connectionID) {
            logger.debug("Phone \(pending.connection.remoteKey) #\(Self.shortID(connectionID)) left before joining: \(reason.description)", remote: pending.connection.remoteKey)
            return
        }
        guard let roomID = phoneRoomIDs.removeValue(forKey: connectionID), let hosted = rooms[roomID] else { return }
        hosted.phoneIDs.remove(connectionID)
        await hosted.room.disconnect(connectionID, reason: reason)
    }

    /// Whether the transport should keep reading from the phone.
    public func isPhoneConnected(_ connectionID: UUID) async -> Bool {
        if pendingPhones[connectionID] != nil { return true }
        guard let roomID = phoneRoomIDs[connectionID], let hosted = rooms[roomID] else { return false }
        let connected = await hosted.room.isConnected(connectionID)
        if !connected {
            // The room dropped it (removed, timed out, wrong state); forget the route.
            phoneRoomIDs.removeValue(forKey: connectionID)
            hosted.phoneIDs.remove(connectionID)
        }
        return connected
    }

    private func handleJoin(_ message: ClientMessage, code: String, version: Int, from pending: PendingPhone) async {
        let connection = pending.connection
        let remote = connection.remoteKey
        let label = "\(remote) #\(Self.shortID(connection.id))"

        func reject(_ reason: JoinRejectReason, _ why: String) {
            pendingPhones.removeValue(forKey: connection.id)
            connection.send(.joinRejected(reason), closeAfterSending: true)
            logger.warning("Join from \(label) rejected: \(why)", remote: remote)
        }

        guard BuzzerConstants.isSupported(version: version) else {
            reject(.unsupportedVersion, "page speaks protocol v\(version), this server v\(BuzzerConstants.protocolVersion)")
            return
        }
        // Blocked addresses are refused even with a right PIN, so the lockout
        // stops guessing instead of slowing it down.
        if codeLimiter.isBlocked(remote, now: scheduler.now) {
            reject(.rateLimited, "too many wrong Game PINs from this address")
            return
        }
        guard let roomID = roomIDByCode[code], let hosted = rooms[roomID] else {
            let limited = codeLimiter.record(remote, now: scheduler.now)
            reject(limited ? .rateLimited : .invalidCode, "no room has that Game PIN\(limited ? " (now rate limited)" : "")")
            return
        }
        guard hosted.phoneIDs.count < configuration.maxPhonesPerRoom else {
            reject(.roomFull, "room \(hosted.label) already has \(hosted.phoneIDs.count) phones")
            return
        }

        pendingPhones.removeValue(forKey: connection.id)
        phoneRoomIDs[connection.id] = roomID
        hosted.phoneIDs.insert(connection.id)
        await hosted.room.connect(connection)
        await hosted.room.receive(message, from: connection.id)
    }

    // MARK: - Hosts (transport → hub)

    /// A Mac opened a WebSocket on the host path. It has
    /// `BuzzerHostConstants.helloTimeout` to send `hello`.
    public func hostConnected(_ connection: any HostConnection) {
        guard !isStopped else {
            connection.close()
            return
        }
        hosts[connection.id] = HostLink(connection: connection, connectedAt: scheduler.now)
        logger.info("Host connected from \(connection.remoteKey) #\(Self.shortID(connection.id))", remote: connection.remoteKey)
    }

    /// One text message from a Mac.
    public func hostReceived(text payload: Data, from connectionID: UUID) async {
        guard let link = hosts[connectionID] else { return }
        let command: HostCommand
        do {
            command = try JSONDecoder().decode(HostCommand.self, from: payload)
        } catch {
            if link.roomID == nil {
                fail(link, HostError(.helloRequired, message: "The first message must be hello"))
            } else {
                link.connection.send(.error(HostError(.badMessage, message: "Couldn't decode the message; ignored")))
                logger.warning("Ignored an undecodable host message from \(link.label)", remote: link.connection.remoteKey)
            }
            return
        }
        if case .pong = command {
            link.lastPong = scheduler.now
            return
        }
        logger.debug("Host \(link.label): \(command.logDescription)", remote: link.connection.remoteKey)

        guard let roomID = link.roomID else {
            if case .hello(let hello) = command {
                await handleHello(hello, from: link)
            } else {
                fail(link, HostError(.helloRequired, message: "The first message must be hello"))
            }
            return
        }
        guard let hosted = rooms[roomID] else { return }
        await apply(command, to: hosted, from: link)
    }

    /// The Mac's connection ended on the transport's side.
    public func hostDisconnected(_ connectionID: UUID) async {
        guard let link = hosts.removeValue(forKey: connectionID) else { return }
        guard let roomID = link.roomID, let hosted = rooms[roomID], hosted.hostID == connectionID else {
            logger.info("Host \(link.label) disconnected", remote: link.connection.remoteKey)
            return
        }
        await hostLeft(hosted, why: "connection closed")
    }

    private func handleHello(_ hello: HostHello, from link: HostLink) async {
        let remote = link.connection.remoteKey
        if tokenLimiter.isBlocked(remote, now: scheduler.now) {
            fail(link, HostError(.rateLimited, message: "Too many wrong host tokens from this address; try again later"))
            return
        }
        guard SecureToken.constantTimeEquals(hello.token, configuration.hostToken) else {
            let limited = tokenLimiter.record(remote, now: scheduler.now)
            fail(link, HostError(limited ? .rateLimited : .badToken, message: limited ? "Too many wrong host tokens from this address; try again later" : "Wrong host token"))
            return
        }
        guard BuzzerHostConstants.isSupported(version: hello.version) else {
            fail(link, HostError(
                .unsupportedVersion,
                message: "This server speaks host protocol v\(BuzzerHostConstants.minimumHostProtocolVersion)–v\(BuzzerHostConstants.hostProtocolVersion)",
                minimumVersion: BuzzerHostConstants.minimumHostProtocolVersion,
                maximumVersion: BuzzerHostConstants.hostProtocolVersion
            ))
            return
        }
        let client = hello.client.map { " (Macpardy \($0.prefix(24)))" } ?? ""

        if let resumeToken = hello.resumeToken {
            guard let roomID = roomIDByResumeToken[resumeToken], let hosted = rooms[roomID] else {
                fail(link, HostError(.roomNotFound, message: "No room for that resume token; its grace period may have ended"))
                return
            }
            await resume(hosted, with: link, client: client)
            return
        }

        guard rooms.count < configuration.maxRooms else {
            fail(link, HostError(.serverFull, message: "The server already has its most rooms (\(configuration.maxRooms))"))
            return
        }
        await open(for: link, client: client)
    }

    /// Sends an error, closes the connection and forgets it.
    private func fail(_ link: HostLink, _ error: HostError) {
        hosts.removeValue(forKey: link.connection.id)
        link.connection.send(.error(error))
        link.connection.close()
        logger.warning("Host \(link.label) refused: \(error.code.rawValue)", remote: link.connection.remoteKey)
    }

    // MARK: - Rooms

    private func open(for link: HostLink, client: String) async {
        var code = makeJoinCode()
        var attempts = 1
        while roomIDByCode[code] != nil {
            attempts += 1
            guard attempts <= 100 else {
                fail(link, HostError(.serverFull, message: "Couldn't find a free Game PIN"))
                return
            }
            code = makeJoinCode()
        }
        let roomID = UUID()
        let label = Self.shortID(roomID)
        let room = BuzzerRoom(
            joinCode: code,
            logger: PrefixedBuzzerLogger(logger, prefix: "Room \(label): "),
            scheduler: scheduler,
            randomIndex: randomIndex
        )
        let hosted = HostedRoom(id: roomID, label: label, code: code, resumeToken: makeResumeToken(), room: room)
        rooms[roomID] = hosted
        roomIDByCode[code] = roomID
        roomIDByResumeToken[hosted.resumeToken] = roomID
        attach(link, to: hosted)
        hosted.eventPump = Task { [weak self] in
            for await event in room.events {
                await self?.roomReported(event, roomID: roomID)
            }
        }
        await room.start()

        link.connection.send(.roomOpened(RoomOpened(
            code: code,
            resumeToken: hosted.resumeToken,
            resumed: false,
            gracePeriod: configuration.gracePeriod,
            publicURL: configuration.publicURL
        )))
        logger.info("Room \(label) opened by \(link.label)\(client) (rooms open: \(rooms.count))", remote: link.connection.remoteKey)
    }

    private func resume(_ hosted: HostedRoom, with link: HostLink, client: String) async {
        // A Mac whose old connection is still half-open takes the room from it.
        if let oldID = hosted.hostID, oldID != link.connection.id, let old = hosts.removeValue(forKey: oldID) {
            old.connection.close()
            logger.info("Room \(hosted.label): host connection \(old.label) replaced by \(link.label)", remote: link.connection.remoteKey)
        }
        hosted.graceTimer?.cancel()
        hosted.graceTimer = nil
        hosted.graceGeneration += 1
        attach(link, to: hosted)

        // What happened while the host was away comes before `roomOpened`, so
        // a Mac that resyncs on `roomOpened` already has every wager and answer.
        let away = hosted.awaySince.map { LogDuration.format(scheduler.now.timeIntervalSince($0)) } ?? "0s"
        hosted.awaySince = nil
        for event in hosted.catchUpEvents() {
            link.connection.send(event)
        }
        hosted.buffered.removeAll()
        link.connection.send(.roomOpened(RoomOpened(
            code: hosted.code,
            resumeToken: hosted.resumeToken,
            resumed: true,
            gracePeriod: configuration.gracePeriod,
            publicURL: configuration.publicURL
        )))
        await hosted.room.setHostAway(false)
        logger.info("Room \(hosted.label) resumed by \(link.label)\(client) after \(away)", remote: link.connection.remoteKey)
    }

    private func attach(_ link: HostLink, to hosted: HostedRoom) {
        link.roomID = hosted.id
        link.lastPong = scheduler.now
        hosted.hostID = link.connection.id
    }

    /// The host is gone: pause the phones and start the grace period.
    private func hostLeft(_ hosted: HostedRoom, why: String) async {
        hosted.hostID = nil
        hosted.awaySince = scheduler.now
        hosted.graceGeneration += 1
        let generation = hosted.graceGeneration
        let roomID = hosted.id
        hosted.graceTimer = scheduler.schedule(after: configuration.gracePeriod) { [weak self] in
            await self?.graceExpired(roomID: roomID, generation: generation)
        }
        logger.warning("Room \(hosted.label): host gone (\(why)); keeping the room for \(Int(configuration.gracePeriod))s")
        await hosted.room.setHostAway(true)
    }

    private func graceExpired(roomID: UUID, generation: Int) async {
        guard let hosted = rooms[roomID], hosted.hostID == nil, hosted.graceGeneration == generation else { return }
        logger.warning("Room \(hosted.label): host didn't come back within \(Int(configuration.gracePeriod))s; closing")
        await closeRoom(hosted, reason: "hostGone")
    }

    /// Ends the room: phones get `sessionEnded`, the host (if any) `roomClosed`.
    private func closeRoom(_ hosted: HostedRoom, reason: String) async {
        guard rooms.removeValue(forKey: hosted.id) != nil else { return }
        roomIDByCode.removeValue(forKey: hosted.code)
        roomIDByResumeToken.removeValue(forKey: hosted.resumeToken)
        hosted.graceTimer?.cancel()
        hosted.graceTimer = nil
        for phoneID in hosted.phoneIDs {
            phoneRoomIDs.removeValue(forKey: phoneID)
        }
        hosted.phoneIDs.removeAll()
        if let hostID = hosted.hostID, let link = hosts.removeValue(forKey: hostID) {
            link.connection.send(.roomClosed(reason: reason))
            link.connection.close()
        }
        hosted.hostID = nil
        let phoneCount = await hosted.room.stop()
        hosted.eventPump?.cancel()
        logger.info("Room \(hosted.label) closed (\(reason)), \(phoneCount) connection(s) closed (rooms open: \(rooms.count))")
    }

    private func apply(_ command: HostCommand, to hosted: HostedRoom, from link: HostLink) async {
        let room = hosted.room
        switch command {
        case .hello:
            fail(link, HostError(.helloRequired, message: "hello was already sent on this connection"))
            if hosted.hostID == link.connection.id {
                await hostLeft(hosted, why: "protocol error")
            }
        case .pong:
            break
        case .closeRoom:
            await closeRoom(hosted, reason: "hostClosed")
        case .updateTeams(let teams): await room.updateTeams(teams)
        case .updateScores(let scores): await room.updateScores(scores)
        case .setBuzzerMode(let mode): await room.setBuzzerMode(mode)
        case .markWrong(let teamID): await room.markWrong(teamID: teamID)
        case .markCorrect: await room.markCorrect()
        case .setResponseTimer(let teamID, let seconds): await room.setResponseTimer(teamID: teamID, seconds: seconds)
        case .openWagering(let limits, let wagers): await room.openWagering(limits: limits, wagers: wagers)
        case .closeWagering: await room.closeWagering()
        case .setWager(let teamID, let amount): await room.setWager(teamID: teamID, amount: amount)
        case .setAnswering(let window, let answers): await room.setAnswering(window, answers: answers)
        case .removePhone(let teamID): await room.removePhone(forTeam: teamID)
        case .broadcastPhase(let phase): await room.broadcast(.state(phase: phase))
        }
    }

    /// A room event: to the host if it's here, else kept for its return.
    private func roomReported(_ event: BuzzerRoomEvent, roomID: UUID) {
        guard let hosted = rooms[roomID], let hostEvent = HostEvent(event) else { return }
        hosted.remember(hostEvent)
        if let hostID = hosted.hostID, let link = hosts[hostID] {
            link.connection.send(hostEvent)
        } else {
            hosted.buffer(hostEvent)
        }
    }

    // MARK: - Timeouts and heartbeat

    private func scheduleTick() {
        tick = scheduler.schedule(after: Self.tickInterval) { [weak self] in
            await self?.tickFired()
        }
    }

    private func tickFired() async {
        guard !isStopped else { return }
        let now = scheduler.now

        for pending in Array(pendingPhones.values) {
            let waited = now.timeIntervalSince(pending.connectedAt)
            guard waited > BuzzerConstants.joinTTL else { continue }
            pendingPhones.removeValue(forKey: pending.connection.id)
            let reason = DisconnectReason.neverJoined(after: waited)
            pending.connection.close(reason: reason)
            logger.info("Phone \(pending.connection.remoteKey) #\(Self.shortID(pending.connection.id)) closed: \(reason.description)", remote: pending.connection.remoteKey)
        }

        for link in Array(hosts.values) {
            if let roomID = link.roomID {
                if now.timeIntervalSince(link.lastPong) > BuzzerHostConstants.hostTTL {
                    hosts.removeValue(forKey: link.connection.id)
                    link.connection.close()
                    if let hosted = rooms[roomID], hosted.hostID == link.connection.id {
                        await hostLeft(hosted, why: "no pong for \(LogDuration.format(now.timeIntervalSince(link.lastPong)))")
                    }
                } else if now.timeIntervalSince(link.lastPing) >= BuzzerHostConstants.pingInterval {
                    link.lastPing = now
                    link.connection.send(.ping)
                }
            } else if now.timeIntervalSince(link.connectedAt) > BuzzerHostConstants.helloTimeout {
                fail(link, HostError(.helloRequired, message: "No hello within \(Int(BuzzerHostConstants.helloTimeout))s"))
            }
        }

        codeLimiter.prune(now: now)
        tokenLimiter.prune(now: now)
        if !isStopped { scheduleTick() }
    }

    // MARK: - Helpers

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(4)).lowercased()
    }
}

// MARK: - State

private struct PendingPhone {
    let connection: any BuzzerConnection
    let connectedAt: Date
}

/// One host connection. Only touched inside the hub.
private final class HostLink {
    let connection: any HostConnection
    let connectedAt: Date
    var roomID: UUID?
    var lastPong: Date
    var lastPing: Date

    init(connection: any HostConnection, connectedAt: Date) {
        self.connection = connection
        self.connectedAt = connectedAt
        self.lastPong = connectedAt
        self.lastPing = connectedAt
    }

    var label: String { "\(connection.remoteKey) #\(BuzzerHub.shortID(connection.id))" }
}

/// One room and its host. Only touched inside the hub.
private final class HostedRoom {
    let id: UUID
    /// Short id for log lines; the PIN isn't logged.
    let label: String
    let code: String
    let resumeToken: String
    let room: BuzzerRoom

    var hostID: UUID?
    var phoneIDs: Set<UUID> = []
    var eventPump: Task<Void, Never>?
    var graceTimer: ScheduledWork?
    /// Bumped when the host leaves or comes back, so an old grace timer does nothing.
    var graceGeneration = 0
    var awaySince: Date?

    /// The room's latest state, sent to a host that comes back.
    private var claimedTeams: Set<UUID> = []
    private var firstBuzz: UUID?
    private var connectedCount = 0
    /// Wagers and answers while the host was away.
    var buffered: [HostEvent] = []

    init(id: UUID, label: String, code: String, resumeToken: String, room: BuzzerRoom) {
        self.id = id
        self.label = label
        self.code = code
        self.resumeToken = resumeToken
        self.room = room
    }

    func remember(_ event: HostEvent) {
        switch event {
        case .claimedTeams(let teams): claimedTeams = teams
        case .firstBuzz(let teamID): firstBuzz = teamID
        case .connectedCount(let count): connectedCount = count
        default: break
        }
    }

    func buffer(_ event: HostEvent) {
        switch event {
        case .wager, .answer:
            buffered.append(event)
            if buffered.count > BuzzerHub.maxBufferedEvents { buffered.removeFirst() }
        default:
            break   // the latest state covers the rest
        }
    }

    /// For a returning host: the latest state, then wagers and answers in order.
    func catchUpEvents() -> [HostEvent] {
        [.claimedTeams(claimedTeams), .connectedCount(connectedCount), .firstBuzz(firstBuzz)] + buffered
    }
}
