//
//  TeamClaimRegistry.swift
//  BuzzerCore
//
//  Tracks which phone session currently holds each team. A team is held by at
//  most one session; a claim lives exactly as long as its session does.
//  Scores are never stored here, so a freed team keeps its score.
//
//  Phones that send a `device` id (#84) are also remembered by it: the team a
//  device last held is restored when it rejoins, and a device can take its own
//  team back from an older connection the server hasn't timed out yet.
//

import Foundation

public struct TeamClaimRegistry: Sendable {

    public enum ClaimResult: Equatable, Sendable {
        case claimed
        /// The same device held the team on an older session, which the caller
        /// should now close.
        case reclaimed(fromSessionID: UUID)
        case alreadyHeld
        case taken
        case invalidTeam
    }

    public private(set) var claims: [UUID: UUID] = [:]   // team id -> session id
    private var deviceBySession: [UUID: String] = [:]   // claiming session id -> device id
    private var lastTeamByDevice: [String: UUID] = [:]  // device id -> team it last held

    public init() {}

    public var claimedTeamIDs: Set<UUID> { Set(claims.keys) }

    public func isClaimed(_ teamID: UUID) -> Bool {
        claims[teamID] != nil
    }

    public func teamID(for sessionID: UUID) -> UUID? {
        claims.first { $0.value == sessionID }?.key
    }

    public func sessionID(for teamID: UUID) -> UUID? {
        claims[teamID]
    }

    /// Claims `teamID` for `sessionID`. A session holds at most one team, so any
    /// team it previously held is released when the new claim succeeds. A team
    /// held by another session is taken over only when both share `deviceID`.
    public mutating func claim(teamID: UUID, sessionID: UUID, deviceID: String? = nil, validTeamIDs: Set<UUID>) -> ClaimResult {
        guard validTeamIDs.contains(teamID) else { return .invalidTeam }
        var result = ClaimResult.claimed
        if let holder = claims[teamID] {
            if holder == sessionID { return .alreadyHeld }
            guard let deviceID, deviceBySession[holder] == deviceID else { return .taken }
            release(sessionID: holder)
            result = .reclaimed(fromSessionID: holder)
        }
        release(sessionID: sessionID)
        claims[teamID] = sessionID
        if let deviceID {
            deviceBySession[sessionID] = deviceID
            lastTeamByDevice[deviceID] = teamID
        }
        return result
    }

    /// The team `deviceID` last held, if it still exists and no other device
    /// holds it now.
    public func teamToRestore(forDevice deviceID: String, validTeamIDs: Set<UUID>) -> UUID? {
        guard let teamID = lastTeamByDevice[deviceID], validTeamIDs.contains(teamID) else { return nil }
        guard let holder = claims[teamID] else { return teamID }
        return deviceBySession[holder] == deviceID ? teamID : nil
    }

    /// Frees whatever team the session holds. Returns that team's id, if any.
    @discardableResult
    public mutating func release(sessionID: UUID) -> UUID? {
        guard let teamID = teamID(for: sessionID) else { return nil }
        claims.removeValue(forKey: teamID)
        deviceBySession.removeValue(forKey: sessionID)
        return teamID
    }

    /// Frees the team regardless of who holds it, and forgets it as the
    /// holder's device's team so it isn't restored on rejoin. Returns the
    /// previous holder.
    @discardableResult
    public mutating func remove(teamID: UUID) -> UUID? {
        guard let holder = claims.removeValue(forKey: teamID) else { return nil }
        if let deviceID = deviceBySession.removeValue(forKey: holder), lastTeamByDevice[deviceID] == teamID {
            lastTeamByDevice.removeValue(forKey: deviceID)
        }
        return holder
    }

    /// Drops claims on teams that no longer exist. Returns the evicted sessions.
    @discardableResult
    public mutating func prune(validTeamIDs: Set<UUID>) -> [UUID] {
        let stale = claims.keys.filter { !validTeamIDs.contains($0) }
        let evicted = stale.compactMap { claims.removeValue(forKey: $0) }
        evicted.forEach { deviceBySession.removeValue(forKey: $0) }
        return evicted
    }

    /// Frees every claim whose session is not in `liveSessionIDs` (TTL sweep).
    /// Returns the freed team ids.
    @discardableResult
    public mutating func sweep(liveSessionIDs: Set<UUID>) -> [UUID] {
        let dead = claims.filter { !liveSessionIDs.contains($0.value) }
        for (teamID, sessionID) in dead {
            claims.removeValue(forKey: teamID)
            deviceBySession.removeValue(forKey: sessionID)
        }
        return Array(dead.keys)
    }
}
