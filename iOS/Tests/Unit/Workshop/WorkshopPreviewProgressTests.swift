// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import WallpaperMachineIOS

final class WorkshopPreviewProgressTests: XCTestCase {
    func testProgressRequiresKnownExpectedLengthAndClamps() {
        XCTAssertNil(WorkshopPreviewProgress.fraction(received: 10, expected: -1))
        XCTAssertNil(WorkshopPreviewProgress.fraction(received: 10, expected: 0))
        XCTAssertEqual(WorkshopPreviewProgress.fraction(received: 25, expected: 100), 0.25)
        XCTAssertEqual(WorkshopPreviewProgress.fraction(received: 120, expected: 100), 1)
    }

    func testUpdatesAreThrottledButFinalByteUpdateIsPublished() {
        let interval = WorkshopPreviewProgress.updateIntervalBytes
        XCTAssertFalse(WorkshopPreviewProgress.shouldPublish(received: interval - 1, lastPublished: 0, expected: interval * 2))
        XCTAssertTrue(WorkshopPreviewProgress.shouldPublish(received: interval, lastPublished: 0, expected: interval * 2))
        XCTAssertTrue(WorkshopPreviewProgress.shouldPublish(received: 100, lastPublished: 99, expected: 100))
    }

    func testUnknownLengthCompletionDoesNotInventFraction() {
        XCTAssertNil(WorkshopPreviewProgress.fraction(received: 1234, expected: -1))
    }
}
