//
//  AttemptRateLimiter.swift
//  BuzzerCore
//
//  Sliding-window attempt counter with a lockout, keyed by remote address.
//  Pure value type; the caller supplies the clock so it can be tested.
//

import Foundation

public struct AttemptRateLimiter: Sendable {

    public let maxAttempts: Int
    public let window: TimeInterval
    public let lockout: TimeInterval

    private var attempts: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]

    public init(maxAttempts: Int, window: TimeInterval, lockout: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.window = window
        self.lockout = lockout
    }

    /// Whether `key` may make another attempt right now.
    public func isBlocked(_ key: String, now: Date = Date()) -> Bool {
        guard let until = lockedUntil[key] else { return false }
        return now < until
    }

    /// Records an attempt. Returns `true` if the key is (now) rate limited.
    @discardableResult
    public mutating func record(_ key: String, now: Date = Date()) -> Bool {
        if isBlocked(key, now: now) { return true }
        lockedUntil.removeValue(forKey: key)

        var recent = (attempts[key] ?? []).filter { now.timeIntervalSince($0) < window }
        recent.append(now)
        attempts[key] = recent

        if recent.count > maxAttempts {
            lockedUntil[key] = now.addingTimeInterval(lockout)
            attempts.removeValue(forKey: key)
            return true
        }
        return false
    }

    /// Forgets expired entries so the dictionaries don't grow without bound.
    public mutating func prune(now: Date = Date()) {
        lockedUntil = lockedUntil.filter { now < $0.value }
        attempts = attempts.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < window }
            return recent.isEmpty ? nil : recent
        }
    }
}
