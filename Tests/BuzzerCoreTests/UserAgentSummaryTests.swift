//
//  UserAgentSummaryTests.swift
//  BuzzerCoreTests
//

import XCTest
@testable import BuzzerCore

final class UserAgentSummaryTests: XCTestCase {

    private func check(_ userAgent: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(UserAgentSummary.shorten(userAgent), expected, file: file, line: line)
    }

    func testIPhoneSafari() {
        check(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1.1 Mobile/15E148 Safari/604.1",
            "Safari 18 on iOS 18.1"
        )
    }

    func testIPhoneChromeAndFirefox() {
        check(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.6723.90 Mobile/15E148 Safari/604.1",
            "Chrome 130 on iOS 17"
        )
        check(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/132.0 Mobile/15E148 Safari/605.1.15",
            "Firefox 132 on iOS 18.2"
        )
    }

    func testIPad() {
        check(
            "Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
            "Safari 17 on iPadOS 17.6"
        )
    }

    func testAndroidChromeAndSamsung() {
        check(
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
            "Chrome 130 on Android 14"
        )
        check(
            "Mozilla/5.0 (Linux; Android 13; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 Chrome/122.0.0.0 Mobile Safari/537.36",
            "Samsung Internet 26 on Android 13"
        )
    }

    func testDesktopBrowsers() {
        check(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
            "Edge 130 on macOS"
        )
        check(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0",
            "Firefox 132 on Windows"
        )
    }

    func testMissingOrUnknown() {
        XCTAssertEqual(UserAgentSummary.shorten(nil), "unknown browser")
        XCTAssertEqual(UserAgentSummary.shorten(""), "unknown browser")
        XCTAssertEqual(UserAgentSummary.shorten("curl/8.4.0"), "Unknown browser")
    }
}
