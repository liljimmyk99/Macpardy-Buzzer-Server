//
//  BuzzerRoom.swift
//  BuzzerCore
//
//  One game's phones and buzzer rules, with no I/O (#101). A transport hands
//  it connections and decoded messages; the room answers through
//  `BuzzerConnection` and reports to the host on `events`.
//
//  Responsibilities
//  ─────────────────
//  • Checks the Game PIN and protocol version on `join`, with rate limiting
//  • Team claims, and giving a rejoining phone (same `device` id) its team back
//  • Pings joined phones on the heartbeat; evicts phones that miss the TTL and
//    sockets that never join
//  • Buzzes, the tie window, and the answering team's response countdown
//  • Final wagers and answers
//  • Logs `uiEvent`s and the phone's disconnect report from `join`
//  • On stop, tells joined phones the session ended (`sessionEnded`) so they
//    return to their Game PIN screen
//  • Pauses the buzzers while a self-hosted server's host is away (#103)
//

import Foundation

public actor BuzzerRoom {

    // MARK: - Public State

    /// The Game PIN phones must send in `join`.
    public nonisolated let joinCode: String

    /// Everything the host needs to know, in order. Finishes on `stop()`.
    public nonisolated let events: AsyncStream<BuzzerRoomEvent>

    // MARK: - Private State

    private let logger: any BuzzerLogging
    private let scheduler: any BuzzerScheduler
    private let randomIndex: @Sendable (Int) -> Int
    private let eventContinuation: AsyncStream<BuzzerRoomEvent>.Continuation

    private var sessions: [UUID: PhoneSession] = [:]
    private var heartbeat: ScheduledWork?
    private var isStopped = false
    /// The self-hosted server lost the Mac and is waiting for it to come back
    /// (#103): phones show the buzzer as unavailable and buzzes are ignored.
    private var isHostAway = false

    /// Teams phones can pick from, as last pushed by the host. `claimed` is
    /// ignored here; it is always derived from `claims`.
    private var currentTeams: [BuzzerTeam] = []
    private var claims = TeamClaimRegistry()
    private var scores: [UUID: Int] = [:]
    private var engine = BuzzerEngine()
    private var wagerBook = FinalWagerBook()
    private var answerBook = FinalAnswerBook()
    private var tieWindow: ScheduledWork?
    /// Bumped whenever the tie window is opened or cancelled, so a timer that
    /// already fired for an older window does nothing.
    private var tieWindowGeneration = 0
    /// The answering team's response countdown, while one is running.
    private var responseTimer: (teamID: UUID, endsAt: Date, total: TimeInterval)?
    private var codeLimiter = AttemptRateLimiter(
        maxAttempts: BuzzerConstants.maxCodeAttempts,
        window: BuzzerConstants.codeAttemptWindow,
        lockout: BuzzerConstants.rateLimitLockout
    )
    private var claimLimiter = AttemptRateLimiter(
        maxAttempts: BuzzerConstants.maxClaimAttempts,
        window: BuzzerConstants.claimAttemptWindow,
        lockout: BuzzerConstants.rateLimitLockout
    )
    /// Keyed by session, so one chatty phone can't flood the log.
    private var uiEventLimiter = AttemptRateLimiter(
        maxAttempts: BuzzerConstants.maxUIEvents,
        window: BuzzerConstants.uiEventWindow,
        lockout: BuzzerConstants.uiEventWindow
    )

    // MARK: - Init

    /// - Parameters:
    ///   - joinCode: The Game PIN. The app generates it; a self-hosted server's hub does (#103).
    ///   - randomIndex: Picks among teams tied on score in the tie window.
    public init(
        joinCode: String,
        logger: any BuzzerLogging = NoBuzzerLogging(),
        scheduler: any BuzzerScheduler = SystemBuzzerScheduler(),
        randomIndex: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.joinCode = joinCode
        self.logger = logger
        self.scheduler = scheduler
        self.randomIndex = randomIndex
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    // MARK: - Lifecycle

    /// Starts the heartbeat. Call once the transport is accepting connections.
    public func start() {
        guard !isStopped, heartbeat == nil else { return }
        scheduleHeartbeat()
    }

    /// Ends the room: joined phones get `sessionEnded` first so they go back to
    /// the Game PIN screen instead of retrying a PIN that no longer works.
    /// Returns how many connections were closed.
    @discardableResult
    public func stop() -> Int {
        isStopped = true
        heartbeat?.cancel()
        heartbeat = nil
        cancelTieWindow()
        let closing = Array(sessions.values)
        sessions.removeAll()
        for session in closing {
            logDisconnect(session, reason: .serverStopped)
            if session.isAuthenticated {
                // Closes the connection once the frame is flushed.
                session.connection.send(.sessionEnded, closeAfterSending: true)
            } else {
                session.connection.close(reason: .serverStopped)
            }
        }
        claims = TeamClaimRegistry()
        eventContinuation.finish()
        return closing.count
    }

    /// The transport failed after it started. Tells the host.
    public func reportFailure(_ description: String) {
        eventContinuation.yield(.failed(description))
    }

    // MARK: - Connections (transport → room)

    /// A phone opened a WebSocket. It has `BuzzerConstants.joinTTL` to send a
    /// valid `join`.
    public func connect(_ connection: any BuzzerConnection) {
        guard !isStopped else {
            connection.close(reason: .serverStopped)
            return
        }
        let session = PhoneSession(connection: connection, connectedAt: scheduler.now)
        sessions[session.id] = session
        publishCount()
        logger.info(
            "WebSocket connected: \(session.logLabel), \(UserAgentSummary.shorten(connection.userAgent)) (open connections: \(sessions.count))",
            remote: session.remoteKey
        )
    }

    /// The connection ended or broke on the transport's side. Frees the team
    /// it held and logs why. The transport closes the connection itself.
    public func disconnect(_ connectionID: UUID, reason: DisconnectReason) {
        guard let session = sessions[connectionID] else { return }
        removeSession(session, reason: reason)
    }

    /// Whether the room still has the connection. Once it doesn't, the
    /// transport can stop reading from it.
    public func isConnected(_ connectionID: UUID) -> Bool {
        sessions[connectionID] != nil
    }

    /// A WebSocket-level pong frame arrived; it counts like a `pong` message.
    public func receivedPong(from connectionID: UUID) {
        sessions[connectionID]?.lastPong = scheduler.now
    }

    /// One text message from a phone, as JSON.
    public func receive(text payload: Data, from connectionID: UUID) {
        guard let session = sessions[connectionID] else { return }
        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: payload) else {
            logger.warning("Ignored an undecodable message from \(session.logLabel)", team: session.claimedTeamName, remote: session.remoteKey)
            return
        }
        handleClientMessage(message, from: session)
    }

    /// One decoded message from a phone.
    public func receive(_ message: ClientMessage, from connectionID: UUID) {
        guard let session = sessions[connectionID] else { return }
        handleClientMessage(message, from: session)
    }

    // MARK: - Broadcasting

    /// Sends a message to every joined phone.
    public func broadcast(_ message: ServerMessage) {
        for session in sessions.values where session.isAuthenticated {
            session.connection.send(message)
        }
    }

    // MARK: - Teams & claims

    /// Replaces the team list phones pick from. Claims on teams that no longer
    /// exist are dropped. Does nothing if the visible fields did not change.
    public func updateTeams(_ teams: [BuzzerTeam]) {
        let normalized = teams.map {
            BuzzerTeam(id: $0.id, name: $0.name, color: $0.color, claimed: false)
        }
        guard normalized != currentTeams else { return }
        currentTeams = normalized
        claims.prune(validTeamIDs: Set(normalized.map(\.id)))
        // Renamed teams: later log lines use the new name.
        for team in normalized {
            if let sessionID = claims.sessionID(for: team.id) {
                sessions[sessionID]?.claimedTeamName = team.name
            }
        }
        claimsChanged()
    }

    /// Frees a team's slot and disconnects its phone, which shows "Removed by
    /// host". The team and its score are untouched, so a new phone can claim it.
    public func removePhone(forTeam teamID: UUID) {
        guard let sessionID = claims.remove(teamID: teamID) else { return }
        if let session = sessions[sessionID] {
            session.connection.send(.removed, closeAfterSending: true)
            removeSession(session, reason: .removedByHost)
        }
        claimsChanged()
    }

    // MARK: - Host presence

    /// The host's connection dropped (`true`) or came back (`false`). Only a
    /// self-hosted server calls this; the built-in server's host is the app.
    /// While away, every phone shows the buzzer as unavailable and buzzes are
    /// ignored; the game state underneath is kept, and on return each phone
    /// gets its real buzzer state again.
    public func setHostAway(_ away: Bool) {
        guard away != isHostAway else { return }
        isHostAway = away
        logger.state("Host \(away ? "away: buzzers paused" : "back: buzzers resumed")")
        for teamID in claims.claimedTeamIDs {
            sendBuzzerState(toTeam: teamID)
        }
    }

    // MARK: - Buzzer

    /// Latest scores, used to break ties between simultaneous buzzes.
    public func updateScores(_ newScores: [UUID: Int]) {
        scores = newScores
    }

    /// Sets up the buzzers for a new screen: clears lockouts and any buzz in progress.
    public func setBuzzerMode(_ mode: BuzzerMode) {
        cancelTieWindow()
        engine.apply(mode)
        buzzerChanged()
    }

    /// The team answered wrong: lock it out and re-arm the others.
    public func markWrong(teamID: UUID) {
        engine.markWrong(teamID: teamID, eligibleTeamIDs: claims.claimedTeamIDs)
        buzzerChanged()
    }

    public func markCorrect() {
        cancelTieWindow()
        engine.markCorrect()
        buzzerChanged()
    }

    private func handleBuzz(from session: PhoneSession) {
        guard !isHostAway, let teamID = claims.teamID(for: session.id) else { return }
        let buzz = Buzz(teamID: teamID, receivedAt: scheduler.now, score: scores[teamID] ?? 0)
        switch engine.buzz(buzz) {
        case .tooEarly:
            session.connection.send(.buzzerState(.tooEarly))
        case .ignored:
            break
        case .windowStarted:
            openTieWindow()
            buzzerChanged()
        case .addedToWindow:
            buzzerChanged()
        }
    }

    private func openTieWindow() {
        tieWindow?.cancel()
        tieWindowGeneration += 1
        let generation = tieWindowGeneration
        tieWindow = scheduler.schedule(after: BuzzerConstants.tieWindow) { [weak self] in
            await self?.closeTieWindow(generation: generation)
        }
    }

    private func cancelTieWindow() {
        tieWindow?.cancel()
        tieWindow = nil
        tieWindowGeneration += 1
    }

    private func closeTieWindow(generation: Int) {
        guard generation == tieWindowGeneration, !isStopped else { return }
        tieWindow = nil
        let contenders = engine.window.map { "'\(teamName($0.teamID))'" }
        if let winner = engine.closeWindow(randomIndex: randomIndex) {
            let how = contenders.count > 1 ? "tie between \(contenders.joined(separator: ", ")) broken" : "no tie"
            logger.state("Tie window closed: \(contenders.count) buzz(es), winner '\(teamName(winner.teamID))' (\(how))", team: teamName(winner.teamID))
            logger.info("\(teamName(winner.teamID)) buzzed in first", team: teamName(winner.teamID))
        }
        buzzerChanged()
    }

    /// Pushes each claimed phone its button state and tells the host who is answering.
    private func buzzerChanged() {
        for teamID in claims.claimedTeamIDs {
            sendBuzzerState(toTeam: teamID)
        }
        eventContinuation.yield(.firstBuzz(engine.firstBuzzTeamID))
    }

    private func sendBuzzerState(toTeam teamID: UUID) {
        send(.buzzerState(isHostAway ? .unavailable : engine.phoneState(for: teamID)), toTeam: teamID)
    }

    // MARK: - Response timer

    /// Starts the answering team's response countdown on every phone, or stops
    /// it when `teamID` is nil. Phones count down locally from the start event.
    public func setResponseTimer(teamID: UUID?, seconds: TimeInterval) {
        if let teamID {
            responseTimer = (teamID, scheduler.now.addingTimeInterval(seconds), seconds)
            if let info = responseTimerInfo() {
                broadcast(.responseTimer(info))
            }
        } else {
            guard responseTimer != nil else { return }
            responseTimer = nil
            broadcast(.responseTimerStopped)
        }
    }

    /// The running countdown with the time left now, for a phone that claims
    /// its team mid-response.
    private func responseTimerInfo() -> ResponseTimerInfo? {
        guard let responseTimer else { return nil }
        return ResponseTimerInfo(
            teamID: responseTimer.teamID,
            remaining: max(0, responseTimer.endsAt.timeIntervalSince(scheduler.now)),
            total: responseTimer.total
        )
    }

    private func sendResponseTimer(to session: PhoneSession) {
        guard let info = responseTimerInfo() else { return }
        session.connection.send(.responseTimer(info))
    }

    // MARK: - Final Macpardy wagers

    /// Opens wagering and tells every claimed phone what it can wager.
    /// `limits` maps each team to its max wager; teams at zero or below are excluded.
    public func openWagering(limits: [UUID: Int], wagers: [UUID: Int]) {
        wagerBook.open(limits: limits, wagers: wagers)
        for teamID in claims.claimedTeamIDs {
            sendWagerInfo(toTeam: teamID)
        }
    }

    public func closeWagering() {
        guard wagerBook.isOpen else { return }
        wagerBook.close()
        for teamID in claims.claimedTeamIDs {
            send(.wagerClosed, toTeam: teamID)
        }
    }

    /// The host entered or edited a wager; the team's phone shows it as locked.
    public func setWager(teamID: UUID, amount: Int?) {
        if let amount {
            guard let stored = wagerBook.hostSet(teamID: teamID, amount: amount) else { return }
            send(.wagerLocked(wager: stored), toTeam: teamID)
        } else {
            wagerBook.hostClear(teamID: teamID)
            sendWagerInfo(toTeam: teamID)
        }
    }

    private func sendWagerInfo(toTeam teamID: UUID) {
        guard let info = wagerBook.info(for: teamID) else { return }
        send(.wagerInfo(info), toTeam: teamID)
    }

    private func handleSubmitWager(_ amount: Int, from session: PhoneSession) {
        guard let teamID = claims.teamID(for: session.id) else { return }
        switch wagerBook.submit(teamID: teamID, amount: amount) {
        case .accepted(let wager):
            session.connection.send(.wagerLocked(wager: wager))
            eventContinuation.yield(.wager(WagerSubmission(teamID: teamID, amount: wager)))
            logger.info("\(teamName(teamID)) submitted a Final wager", team: teamName(teamID))
        case .rejected(let reason):
            session.connection.send(.wagerRejected(reason))
        }
    }

    // MARK: - Final Macpardy answers

    /// Opens, locks or closes Final answering and updates every claimed phone.
    /// `answers` are the answers stored in the game, so a restarted server or a
    /// rejoining phone shows what the team already sent.
    public func setAnswering(_ window: FinalAnswerWindow, answers: [UUID: String]) {
        let wasOpen = answerBook.window != .closed
        answerBook.set(window, answers: answers)
        for teamID in claims.claimedTeamIDs {
            if window == .closed {
                if wasOpen { send(.answerClosed, toTeam: teamID) }
            } else {
                sendAnswerInfo(toTeam: teamID)
            }
        }
    }

    private func sendAnswerInfo(toTeam teamID: UUID) {
        guard let info = answerBook.info(for: teamID) else { return }
        send(.answerInfo(info), toTeam: teamID)
    }

    private func handleSubmitAnswer(_ answer: String, from session: PhoneSession) {
        guard let teamID = claims.teamID(for: session.id) else { return }
        switch answerBook.submit(teamID: teamID, answer: answer) {
        case .accepted(let saved):
            session.connection.send(.answerSaved(answer: saved))
            eventContinuation.yield(.answer(AnswerSubmission(teamID: teamID, answer: saved)))
            logger.info("\(teamName(teamID)) saved a Final answer", team: teamName(teamID))
        case .rejected(let reason):
            session.connection.send(.answerRejected(reason))
        }
    }

    // MARK: - Phone messages

    private func handleClientMessage(_ message: ClientMessage, from session: PhoneSession) {
        logInbound(message, from: session)
        switch message {
        case .join(let code, let version, let diag, let device):
            handleJoin(code: code, version: version, diag: diag, device: device, from: session)

        case .claim(let teamID):
            guard session.isAuthenticated else { return }

            if claimLimiter.record(session.remoteKey, now: scheduler.now) {
                session.connection.send(.claimRejected(reason: .rateLimited))
                logger.warning("Claim of \(teamName(teamID)) by \(session.logLabel) rejected: rate limited", team: teamName(teamID), remote: session.remoteKey)
                return
            }

            claimTeam(teamID, for: session)

        case .pong:
            session.lastPong = scheduler.now

        case .buzz:
            guard session.isAuthenticated else { return }
            handleBuzz(from: session)

        case .submitWager(let amount):
            guard session.isAuthenticated else { return }
            handleSubmitWager(amount, from: session)

        case .submitAnswer(let answer):
            guard session.isAuthenticated else { return }
            handleSubmitAnswer(answer, from: session)

        case .uiEvent(let event, let at):
            handleUIEvent(event, at: at, from: session)
        }
    }

    private func handleJoin(code: String, version: Int, diag: PhoneDisconnectReport?, device: String?, from session: PhoneSession) {
        guard BuzzerConstants.isSupported(version: version) else {
            session.connection.send(.joinRejected(.unsupportedVersion), closeAfterSending: true)
            logger.warning(
                "Join from \(session.logLabel) rejected: page speaks protocol v\(version), this Mac v\(BuzzerConstants.protocolVersion) (an old page left open; reload it)",
                remote: session.remoteKey
            )
            removeSession(session, reason: .joinRejected(.unsupportedVersion))
            return
        }

        // A blocked address is refused even with the right code, otherwise
        // the lockout would only slow down guessing, not stop it.
        if codeLimiter.isBlocked(session.remoteKey, now: scheduler.now) {
            session.connection.send(.joinRejected(.rateLimited), closeAfterSending: true)
            logger.warning("Join from \(session.logLabel) rejected: too many wrong Game PINs from this address", remote: session.remoteKey)
            removeSession(session, reason: .joinRejected(.rateLimited))
            return
        }

        guard code == joinCode else {
            let limited = codeLimiter.record(session.remoteKey, now: scheduler.now)
            session.connection.send(.joinRejected(limited ? .rateLimited : .invalidCode), closeAfterSending: true)
            logger.warning(
                "Join from \(session.logLabel) rejected: wrong Game PIN '\(code.prefix(16))'\(limited ? " (now rate limited)" : "")",
                remote: session.remoteKey
            )
            removeSession(session, reason: .joinRejected(limited ? .rateLimited : .invalidCode))
            return
        }

        session.isAuthenticated = true
        session.deviceID = device
        session.lastPong = scheduler.now
        session.connection.send(.joinAccepted(teams: teamsPayload()))
        publishCount()
        logger.info("Join accepted from \(session.logLabel)", remote: session.remoteKey)
        if let diag {
            logger.notice("Phone report (\(session.remoteKey) #\(session.shortID)): \(diag.summary)", remote: session.remoteKey)
        }
        // A phone coming back (background, lock screen, Wi-Fi blip) goes
        // straight back to its team.
        if let device, let teamID = claims.teamToRestore(forDevice: device, validTeamIDs: Set(currentTeams.map(\.id))) {
            claimTeam(teamID, for: session, restoring: true)
        }
    }

    /// `phone:` line for every inbound message but pongs (#87). Payloads follow
    /// the content rule: a Final answer's length, never its text; never the PIN.
    private func logInbound(_ message: ClientMessage, from session: PhoneSession) {
        let what: String
        switch message {
        case .join(_, let version, let diag, let device):
            what = "join v\(version)\(device == nil ? "" : " with device id")\(diag == nil ? "" : " with disconnect report")"
        case .claim(let teamID): what = "claim '\(teamName(teamID))'"
        case .pong, .uiEvent: return
        case .buzz: what = "buzz"
        case .submitWager(let amount): what = "submitWager $\(amount)"
        case .submitAnswer(let answer): what = "submitAnswer (\(BuzzerLogValue.length(of: answer)))"
        }
        logger.phone("\(session.logLabel): \(what)", team: session.claimedTeamName, remote: session.remoteKey)
    }

    /// Logs a page-only event the phone reported (v10). Unknown events and
    /// phones over the rate limit are dropped without a reply.
    private func handleUIEvent(_ event: String, at: Double?, from session: PhoneSession) {
        guard session.isAuthenticated,
              !uiEventLimiter.record(session.id.uuidString, now: scheduler.now),
              let event = PhoneUIEvent(rawValue: event) else { return }
        // Events from while the phone was offline arrive late; the page's own
        // time shows when they happened.
        let when = at.map { " (phone time \(Date(timeIntervalSince1970: $0 / 1000).formatted(BuzzerLogValue.timestampStyle)))" } ?? ""
        logger.phone("\(session.logLabel): \(event.logDescription)\(when)", team: session.claimedTeamName, remote: session.remoteKey)
    }

    // MARK: - Claims

    /// Gives `teamID` to `session`. `restoring` is a rejoining phone getting
    /// its last team back unasked, so a refusal is silent: it just picks again.
    private func claimTeam(_ teamID: UUID, for session: PhoneSession, restoring: Bool = false) {
        let previousTeamID = claims.teamID(for: session.id)
        let result = claims.claim(
            teamID: teamID,
            sessionID: session.id,
            deviceID: session.deviceID,
            validTeamIDs: Set(currentTeams.map(\.id))
        )
        switch result {
        case .claimed, .reclaimed:
            if case .reclaimed(let oldSessionID) = result, let old = sessions[oldSessionID] {
                // Same phone, older connection the TTL hasn't caught yet.
                old.connection.close(reason: .replacedByNewConnection)
                removeSession(old, reason: .replacedByNewConnection)
            }
            sendClaimState(teamID, to: session)
            claimsChanged()
            if let previousTeamID, previousTeamID != teamID {
                logger.info("\(teamName(previousTeamID)) released by \(session.logLabel)", team: teamName(previousTeamID), remote: session.remoteKey)
            }
            session.claimedTeamName = teamName(teamID)
            let how = restoring ? "Team restored on rejoin" : "Claim accepted"
            logger.info("\(how): \(session.logLabel)", team: teamName(teamID), remote: session.remoteKey)
        case .alreadyHeld:
            sendClaimState(teamID, to: session)
        case .taken, .invalidTeam:
            guard !restoring else { return }
            // Refresh the picker first so the rejection message isn't wiped by it.
            session.connection.send(.teams(teamsPayload()))
            if result == .taken {
                session.connection.send(.claimRejected(reason: .taken))
                logger.info("Claim of \(teamName(teamID)) by \(session.logLabel) rejected: another phone holds it", team: teamName(teamID), remote: session.remoteKey)
            } else {
                session.connection.send(.claimRejected(reason: .invalidTeam))
                logger.info("Claim by \(session.logLabel) rejected: no such team", remote: session.remoteKey)
            }
        }
    }

    /// Everything a phone needs after taking its team: the claim, its buzzer,
    /// any open Final screen and a running countdown.
    private func sendClaimState(_ teamID: UUID, to session: PhoneSession) {
        session.connection.send(.claimAccepted(teamID: teamID))
        sendBuzzerState(toTeam: teamID)
        sendWagerInfo(toTeam: teamID)
        sendAnswerInfo(toTeam: teamID)
        sendResponseTimer(to: session)
    }

    /// Teams with their current claim flags.
    private func teamsPayload() -> [BuzzerTeam] {
        currentTeams.map {
            BuzzerTeam(id: $0.id, name: $0.name, color: $0.color, claimed: claims.isClaimed($0.id))
        }
    }

    /// Tells every phone and the host that claims or teams changed.
    private func claimsChanged() {
        broadcast(.teams(teamsPayload()))
        eventContinuation.yield(.claimedTeams(claims.claimedTeamIDs))
    }

    private func send(_ message: ServerMessage, toTeam teamID: UUID) {
        guard let sessionID = claims.sessionID(for: teamID),
              let session = sessions[sessionID] else { return }
        session.connection.send(message)
    }

    /// A team's name for log lines.
    private func teamName(_ teamID: UUID) -> String {
        currentTeams.first { $0.id == teamID }?.name ?? "Unknown team"
    }

    // MARK: - Sessions

    /// Drops a session, frees the team it held, and logs why. Doesn't close
    /// the connection, so a message sent with `closeAfterSending` still goes out.
    private func removeSession(_ session: PhoneSession, reason: DisconnectReason) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        publishCount()
        if let teamID = claims.release(sessionID: session.id) {
            logger.debug("\(teamName(teamID)) released by \(session.remoteKey) #\(session.shortID)", team: teamName(teamID), remote: session.remoteKey)
            claimsChanged()
        }
        logDisconnect(session, reason: reason)
    }

    /// One line per disconnect: who, for how long, and why.
    private func logDisconnect(_ session: PhoneSession, reason: DisconnectReason) {
        let duration = LogDuration.format(scheduler.now.timeIntervalSince(session.connectedAt))
        let joined = sessions.values.filter(\.isAuthenticated).count
        let state = session.isAuthenticated ? "connected" : "connected, not joined,"
        logger.log(
            reason.logLevel,
            "Disconnected \(session.logLabel) (\(state) \(duration)): \(reason.description). Phones still joined: \(joined)",
            kind: .plain,
            team: session.claimedTeamName,
            remote: session.remoteKey
        )
    }

    private func publishCount() {
        eventContinuation.yield(.connectedCount(sessions.values.filter(\.isAuthenticated).count))
    }

    // MARK: - Heartbeat

    private func scheduleHeartbeat() {
        heartbeat = scheduler.schedule(after: BuzzerConstants.pingInterval) { [weak self] in
            await self?.heartbeatFired()
        }
    }

    private func heartbeatFired() {
        guard !isStopped else { return }
        heartbeatTick()
        scheduleHeartbeat()
    }

    private func heartbeatTick() {
        let ttl = BuzzerConstants.heartbeatTTL
        let joinTTL = BuzzerConstants.joinTTL
        let now = scheduler.now
        var toRemove: [(PhoneSession, DisconnectReason)] = []

        for session in sessions.values {
            if !session.isAuthenticated {
                // Never joined: give it `joinTTL` to send a valid `join`, don't ping it.
                let waited = now.timeIntervalSince(session.connectedAt)
                if waited > joinTTL {
                    let reason = DisconnectReason.neverJoined(after: waited)
                    session.connection.close(reason: reason)
                    toRemove.append((session, reason))
                }
            } else if now.timeIntervalSince(session.lastPong) > ttl {
                let reason = DisconnectReason.heartbeatTimeout(sinceLastPong: now.timeIntervalSince(session.lastPong))
                session.connection.close(reason: reason)
                toRemove.append((session, reason))
            } else {
                session.connection.send(.ping)
            }
        }

        // Removing a session also frees the team it held.
        for (session, reason) in toRemove {
            removeSession(session, reason: reason)
        }

        codeLimiter.prune(now: now)
        claimLimiter.prune(now: now)
        uiEventLimiter.prune(now: now)
    }
}

// MARK: - PhoneSession

/// The room's view of one connection. Only ever touched inside the room.
private final class PhoneSession {

    let connection: any BuzzerConnection
    /// When the WebSocket opened; sockets that never join are evicted from it.
    let connectedAt: Date
    /// The last pong (message or frame).
    var lastPong: Date
    /// Whether the phone sent the right Game PIN.
    var isAuthenticated = false
    /// The page's `device` id from its `join`, if it sent a usable one.
    var deviceID: String?
    /// The last team this phone held. Kept after the claim is released so the
    /// disconnect line can still name the team.
    var claimedTeamName: String?

    init(connection: any BuzzerConnection, connectedAt: Date) {
        self.connection = connection
        self.connectedAt = connectedAt
        self.lastPong = connectedAt
    }

    var id: UUID { connection.id }
    var remoteKey: String { connection.remoteKey }

    /// First four characters of `id`, to tell apart log lines from phones on
    /// the same address.
    var shortID: String { String(id.uuidString.prefix(4)).lowercased() }

    /// How log lines name this phone: its team once it has claimed one,
    /// otherwise its address, plus `shortID`.
    var logLabel: String {
        if let claimedTeamName { "\(claimedTeamName) (\(remoteKey) #\(shortID))" } else { "\(remoteKey) #\(shortID)" }
    }
}
