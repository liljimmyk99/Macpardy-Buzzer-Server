//
//  BuzzerEngine.swift
//  BuzzerCore
//
//  Pure state machine behind the buzzers: disabled, armed, window open and
//  answering. It has no networking or timers; the server feeds it buzzes,
//  closes the tie window and reads back what each phone should show.
//

import Foundation

/// What a phone's buzzer button shows.
public enum BuzzerPhoneState: String, Encodable, Equatable, Sendable {
    /// Buzzer disabled; pressing it shows "too early".
    case waiting
    /// Buzzer disabled and the button cannot be pressed (Daily Double).
    case unavailable
    case armed
    case pressed
    case first
    case lockedOut
    case tooEarly
}

/// How the host wants the buzzers set up for the current screen.
public enum BuzzerMode: Equatable, Sendable {
    /// Board and other screens: not armed, but pressing is answered with "too early".
    case disabled
    /// Daily Double: not armed and the button cannot be pressed at all.
    case unavailable
    /// A normal question is displayed.
    case armed
}

public struct BuzzerEngine: Sendable {

    public enum Phase: Equatable, Sendable {
        case disabled(pressable: Bool)
        case armed
        case windowOpen
        case answering(teamID: UUID)
    }

    public enum BuzzOutcome: Equatable, Sendable {
        case tooEarly
        case ignored
        case windowStarted
        case addedToWindow
    }

    public private(set) var phase: Phase = .disabled(pressable: true)
    public private(set) var window: [Buzz] = []
    public private(set) var lockedOut: Set<UUID> = []

    public init() {}

    /// The team currently answering, if a buzz has been resolved.
    public var firstBuzzTeamID: UUID? {
        if case .answering(let teamID) = phase { return teamID }
        return nil
    }

    // MARK: - Host-driven transitions

    /// Applies a mode for a new screen. Lockouts never outlive a mode change.
    public mutating func apply(_ mode: BuzzerMode) {
        lockedOut = []
        window = []
        switch mode {
        case .disabled: phase = .disabled(pressable: true)
        case .unavailable: phase = .disabled(pressable: false)
        case .armed: phase = .armed
        }
    }

    /// The team answered wrong: it is locked out for the question and everyone
    /// else can buzz again. Stays disabled if no other team is left to buzz.
    public mutating func markWrong(teamID: UUID, eligibleTeamIDs: Set<UUID>) {
        switch phase {
        case .disabled:
            return
        case .armed, .windowOpen, .answering:
            lockedOut.insert(teamID)
            window.removeAll { $0.teamID == teamID }
        }
        if case .answering(let answering) = phase, answering != teamID { return }
        if case .windowOpen = phase, !window.isEmpty { return }
        phase = eligibleTeamIDs.subtracting(lockedOut).isEmpty ? .disabled(pressable: true) : .armed
    }

    /// The question was answered correctly; the buzzers stop.
    public mutating func markCorrect() {
        guard phase != .disabled(pressable: false) else { return }
        window = []
        phase = .disabled(pressable: true)
    }

    // MARK: - Phone input

    public mutating func buzz(_ buzz: Buzz) -> BuzzOutcome {
        switch phase {
        case .disabled(let pressable):
            return pressable ? .tooEarly : .ignored
        case .answering:
            return .ignored
        case .armed:
            guard !lockedOut.contains(buzz.teamID) else { return .ignored }
            window = [buzz]
            phase = .windowOpen
            return .windowStarted
        case .windowOpen:
            guard !lockedOut.contains(buzz.teamID),
                  !window.contains(where: { $0.teamID == buzz.teamID }) else { return .ignored }
            window.append(buzz)
            return .addedToWindow
        }
    }

    /// Ends the tie window and returns the winner, who is now answering.
    @discardableResult
    public mutating func closeWindow(
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Buzz? {
        guard case .windowOpen = phase else { return nil }
        let buzzes = window
        window = []
        guard let winner = BuzzTieResolver.winner(of: buzzes, randomIndex: randomIndex) else {
            phase = .armed
            return nil
        }
        phase = .answering(teamID: winner.teamID)
        return winner
    }

    // MARK: - Phone display

    public func phoneState(for teamID: UUID) -> BuzzerPhoneState {
        switch phase {
        case .disabled(let pressable):
            return pressable ? .waiting : .unavailable
        case .armed:
            return lockedOut.contains(teamID) ? .lockedOut : .armed
        case .windowOpen:
            if lockedOut.contains(teamID) { return .lockedOut }
            return window.contains { $0.teamID == teamID } ? .pressed : .armed
        case .answering(let answering):
            if answering == teamID { return .first }
            return lockedOut.contains(teamID) ? .lockedOut : .waiting
        }
    }
}
