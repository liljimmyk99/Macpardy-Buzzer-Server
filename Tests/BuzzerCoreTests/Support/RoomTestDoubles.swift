//
//  RoomTestDoubles.swift
//  BuzzerCoreTests
//
//  A fake phone connection and a clock that only moves when told, for
//  testing `BuzzerRoom` without a network or sleeps (#101).
//

import Foundation
import Synchronization
@testable import BuzzerCore

/// Records what the room sent and whether it closed the connection.
final class FakeConnection: BuzzerConnection {

    struct Sent: Equatable {
        let message: ServerMessage
        let closeAfterSending: Bool
    }

    private struct State {
        var sent: [Sent] = []
        var closeReason: DisconnectReason?
        var closed = false
    }

    let id = UUID()
    let remoteKey: String
    let userAgent: String?
    private let state = Mutex(State())

    init(remoteKey: String = "192.168.1.10", userAgent: String? = nil) {
        self.remoteKey = remoteKey
        self.userAgent = userAgent
    }

    /// Everything sent, oldest first.
    var sent: [Sent] { state.withLock { $0.sent } }
    var messages: [ServerMessage] { sent.map(\.message) }
    var lastMessage: ServerMessage? { messages.last }
    /// Closed now, or after the last message went out.
    var isClosed: Bool { state.withLock { $0.closed } }
    /// The reason passed to `close(reason:)`, if the room closed it that way.
    var closeReason: DisconnectReason? { state.withLock { $0.closeReason } }

    /// Forgets what was sent so far, to look at only what comes next.
    func clear() {
        state.withLock { $0.sent = [] }
    }

    func send(_ message: ServerMessage, closeAfterSending: Bool) {
        state.withLock {
            $0.sent.append(Sent(message: message, closeAfterSending: closeAfterSending))
            if closeAfterSending { $0.closed = true }
        }
    }

    func close(reason: DisconnectReason) {
        state.withLock {
            $0.closed = true
            $0.closeReason = reason
        }
    }
}

/// A clock that stands still until `advance(by:)`, which runs the work that
/// falls due in order, at its due time.
final class TestScheduler: BuzzerScheduler {

    private struct Item {
        let id: Int
        let fireAt: Date
        let work: @Sendable () async -> Void
    }

    private struct State {
        var now: Date
        var nextID = 0
        var items: [Item] = []
    }

    private let state: Mutex<State>

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        state = Mutex(State(now: now))
    }

    var now: Date { state.withLock { $0.now } }

    /// Work waiting to run.
    var pendingCount: Int { state.withLock { $0.items.count } }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> ScheduledWork {
        let id = state.withLock { state in
            state.nextID += 1
            state.items.append(Item(id: state.nextID, fireAt: state.now.addingTimeInterval(delay), work: work))
            return state.nextID
        }
        return ScheduledWork { [weak self] in
            self?.state.withLock { $0.items.removeAll { $0.id == id } }
        }
    }

    /// Moves time forward, running everything due on the way, including work
    /// that this work schedules.
    func advance(by seconds: TimeInterval) async {
        let target = now.addingTimeInterval(seconds)
        while let item = popDue(before: target) {
            await item.work()
        }
        state.withLock { $0.now = target }
    }

    private func popDue(before target: Date) -> Item? {
        state.withLock { state in
            guard let next = state.items.filter({ $0.fireAt <= target }).min(by: { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }) else {
                return nil
            }
            state.items.removeAll { $0.id == next.id }
            state.now = next.fireAt
            return next
        }
    }
}

extension BuzzerRoom {
    /// Stops the room and returns every event it reported.
    func stopAndCollectEvents() async -> [BuzzerRoomEvent] {
        stop()
        var events: [BuzzerRoomEvent] = []
        for await event in self.events {
            events.append(event)
        }
        return events
    }
}
