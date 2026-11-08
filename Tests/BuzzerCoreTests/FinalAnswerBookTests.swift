//
//  FinalAnswerBookTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class FinalAnswerBookTests: XCTestCase {

    private let team = UUID()
    private let other = UUID()

    private func openBook(answers: [UUID: String] = [:]) -> FinalAnswerBook {
        var book = FinalAnswerBook()
        book.set(.open, answers: answers)
        return book
    }

    func testRejectsWhenClosedOrLocked() {
        var book = FinalAnswerBook()
        XCTAssertEqual(book.submit(teamID: team, answer: "Paris"), .rejected(.notOpen))
        book.set(.locked, answers: [:])
        XCTAssertEqual(book.submit(teamID: team, answer: "Paris"), .rejected(.notOpen))
    }

    func testAcceptsAndNormalizes() {
        var book = openBook()
        XCTAssertEqual(book.submit(teamID: team, answer: "  What is\nParis?  "), .accepted("What is Paris?"))
        XCTAssertEqual(book.info(for: team), AnswerInfo(open: true, answer: "What is Paris?", maxLength: 200))
    }

    func testLatestSubmissionWinsWhileOpen() {
        var book = openBook()
        _ = book.submit(teamID: team, answer: "Paris")
        XCTAssertEqual(book.submit(teamID: team, answer: "Lyon"), .accepted("Lyon"))
        XCTAssertEqual(book.info(for: team)?.answer, "Lyon")
    }

    func testRejectsEmptyAndTooLong() {
        var book = openBook()
        XCTAssertEqual(book.submit(teamID: team, answer: " \n "), .rejected(.empty))
        let long = String(repeating: "a", count: FinalAnswerBook.maxLength + 1)
        XCTAssertEqual(book.submit(teamID: team, answer: long), .rejected(.tooLong))
        let exact = String(repeating: "a", count: FinalAnswerBook.maxLength)
        XCTAssertEqual(book.submit(teamID: team, answer: exact), .accepted(exact))
    }

    func testRejectedSubmissionKeepsPreviousAnswer() {
        var book = openBook(answers: [team: "Paris"])
        XCTAssertEqual(book.submit(teamID: team, answer: ""), .rejected(.empty))
        XCTAssertEqual(book.info(for: team)?.answer, "Paris")
    }

    func testLockedShowsSeededAnswersReadOnly() {
        var book = FinalAnswerBook()
        book.set(.locked, answers: [team: "Paris"])
        XCTAssertEqual(book.info(for: team), AnswerInfo(open: false, answer: "Paris", maxLength: 200))
        XCTAssertEqual(book.info(for: other), AnswerInfo(open: false, answer: nil, maxLength: 200))
    }

    func testClosingForgetsAnswersAndHidesScreen() {
        var book = openBook(answers: [team: "Paris"])
        book.set(.closed, answers: [team: "Paris"])
        XCTAssertNil(book.info(for: team))
        book.set(.open, answers: [:])
        XCTAssertNil(book.info(for: team)?.answer)
    }
}
