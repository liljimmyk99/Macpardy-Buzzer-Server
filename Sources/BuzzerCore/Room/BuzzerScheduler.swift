//
//  BuzzerScheduler.swift
//  BuzzerCore
//
//  The room's clock and timers (#101): the heartbeat, the tie window and the
//  response countdown all read the time and schedule work through this, so
//  tests can move time forward instead of sleeping.
//

import Foundation

public protocol BuzzerScheduler: Sendable {
    /// The current time.
    var now: Date { get }

    /// Runs `work` once, `delay` seconds from now, unless the returned handle
    /// is cancelled first.
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> ScheduledWork
}

/// A handle to work scheduled with `BuzzerScheduler`.
public struct ScheduledWork: Sendable {
    private let onCancel: @Sendable () -> Void

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Stops the work from running if it hasn't started yet.
    public func cancel() {
        onCancel()
    }
}

/// The real clock, with `Task.sleep` timers.
public struct SystemBuzzerScheduler: BuzzerScheduler {

    public init() {}

    public var now: Date { Date() }

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) -> ScheduledWork {
        let task = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await work()
        }
        return ScheduledWork { task.cancel() }
    }
}
