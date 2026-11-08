//
//  BuzzerRoomEvent.swift
//  BuzzerCore
//
//  What a room tells its host (#101), on one ordered stream. The app turns
//  these into `BuzzerState` properties; a self-hosted server will forward
//  them to the Mac over the host protocol.
//

import Foundation

public enum BuzzerRoomEvent: Equatable, Sendable {
    /// The teams a phone holds now. Sent whenever claims or teams change.
    case claimedTeams(Set<UUID>)
    /// The team answering after a buzz, or nil when none is.
    case firstBuzz(UUID?)
    /// A phone submitted a valid Final wager.
    case wager(WagerSubmission)
    /// A phone saved a Final answer.
    case answer(AnswerSubmission)
    /// How many phones have joined with the Game PIN.
    case connectedCount(Int)
    /// The transport failed after it started; phones can no longer connect.
    case failed(String)
}
