// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import WallpaperMachineIOS

final class WorkshopAnimationDecoderTests: XCTestCase {
    func testFrameCountRequiresAnimationAndHonorsLimit() {
        XCTAssertNil(WorkshopAnimationBudget.frameCount(1))
        XCTAssertEqual(WorkshopAnimationBudget.frameCount(2), 2)
        XCTAssertEqual(WorkshopAnimationBudget.frameCount(300), 300)
        XCTAssertNil(WorkshopAnimationBudget.frameCount(301))
    }

    func testFramePixelBudgetIncludesPerFrameAndAggregateLimits() {
        XCTAssertTrue(WorkshopAnimationBudget.canAddFrame(width: 2048, height: 2048, totalPixels: 0))
        XCTAssertFalse(WorkshopAnimationBudget.canAddFrame(width: 2049, height: 2048, totalPixels: 0))
        XCTAssertFalse(WorkshopAnimationBudget.canAddFrame(width: 2048, height: 2048, totalPixels: 33_554_432 - 1))
        XCTAssertFalse(WorkshopAnimationBudget.canAddFrame(width: 0, height: 1, totalPixels: 0))
    }

    func testFrameDurationsAreFiniteAndBounded() {
        XCTAssertEqual(WorkshopAnimationBudget.duration(nil), 0.1)
        XCTAssertEqual(WorkshopAnimationBudget.duration(0), 0.1)
        XCTAssertEqual(WorkshopAnimationBudget.duration(.infinity), 0.1)
        XCTAssertEqual(WorkshopAnimationBudget.duration(0.001), 0.02)
        XCTAssertEqual(WorkshopAnimationBudget.duration(11), 10)
    }
}
