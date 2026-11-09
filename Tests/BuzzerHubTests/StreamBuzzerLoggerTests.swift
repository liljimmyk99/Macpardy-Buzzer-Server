//
//  StreamBuzzerLoggerTests.swift
//  BuzzerHubTests
//

import BuzzerCore
import Synchronization
import XCTest
@testable import BuzzerHub

final class StreamBuzzerLoggerTests: XCTestCase {

    func testFormatsOneLinePerEntryAtOrAboveTheLevel() {
        let lines = Mutex<[String]>([])
        let logger = StreamBuzzerLogger(
            minimumLevel: .info,
            now: { Date(timeIntervalSince1970: 0) },
            write: { line in lines.withLock { $0.append(line) } }
        )
        logger.debug("hidden")
        logger.info("Join accepted", team: "Red", remote: "198.51.100.7")
        logger.warning("two\nlines")
        PrefixedBuzzerLogger(logger, prefix: "Room ab12: ").phone("buzz")
        PrefixedBuzzerLogger(logger, prefix: "Room ab12: ").notice("hello")

        XCTAssertEqual(lines.withLock { $0 }, [
            "1970-01-01T00:00:00.000Z INFO [198.51.100.7] [Red] Join accepted",
            "1970-01-01T00:00:00.000Z WARNING two lines",
            "1970-01-01T00:00:00.000Z NOTICE Room ab12: hello",
        ])
    }
}
