//
//  BuzzTieResolver.swift
//  BuzzerCore
//
//  Picks the winner among buzzes received inside the tie window. Kept separate
//  from the engine so the tie rules can be tweaked on their own.
//

import Foundation

/// One buzz as received by the server.
public struct Buzz: Equatable, Sendable {
    public let teamID: UUID
    public let receivedAt: Date
    public let score: Int

    public init(teamID: UUID, receivedAt: Date, score: Int) {
        self.teamID = teamID
        self.receivedAt = receivedAt
        self.score = score
    }
}

public enum BuzzTieResolver: Sendable {

    /// The lowest score wins; teams with equal scores are picked at random.
    /// `randomIndex` receives the number of tied teams and returns an index into
    /// them, so tests can make the random pick deterministic.
    public static func winner(
        of buzzes: [Buzz],
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Buzz? {
        guard let lowest = buzzes.map(\.score).min() else { return nil }
        let tied = buzzes.filter { $0.score == lowest }
        return tied[randomIndex(tied.count)]
    }
}
