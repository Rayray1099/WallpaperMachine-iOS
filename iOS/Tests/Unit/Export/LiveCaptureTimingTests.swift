// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import WallpaperMachineIOS

final class LiveCaptureTimingTests: XCTestCase {
    func testPacesWithoutOverflowOrInvalidTimestamps() {
        XCTAssertEqual(LiveCaptureTiming.waitNanoseconds(origin: 1_000_000_000, now: 1_000_000_000, seconds: 0.5), 500_000_000)
        XCTAssertEqual(LiveCaptureTiming.waitNanoseconds(origin: 1_000_000_000, now: 1_100_000_000, seconds: 0), 0)
        XCTAssertNil(LiveCaptureTiming.waitNanoseconds(origin: 1, now: 2_000_000_000, seconds: 0))
        for value in [Double.infinity, -.infinity, .nan, -1, 86_400.001, Double.greatestFiniteMagnitude] {
            XCTAssertNil(LiveCaptureTiming.waitNanoseconds(origin: 0, now: 0, seconds: value))
        }
        XCTAssertNil(LiveCaptureTiming.waitNanoseconds(origin: UInt64.max - 1, now: UInt64.max - 1, seconds: 1))
    }

    func testDriftBoundaryAndMonotonicClock() {
        XCTAssertEqual(LiveCaptureTiming.waitNanoseconds(origin: 10, now: 500_000_010, seconds: 0), 0)
        XCTAssertNil(LiveCaptureTiming.waitNanoseconds(origin: 10, now: 500_000_011, seconds: 0))
        XCTAssertNil(LiveCaptureTiming.waitNanoseconds(origin: 10, now: 9, seconds: 0))
        XCTAssertEqual(LiveCaptureTiming.waitNanoseconds(origin: 0, now: 0, seconds: 86_400), 86_400_000_000_000)
        XCTAssertEqual(LiveCaptureTiming.waitNanoseconds(origin: UInt64.max, now: UInt64.max, seconds: 0), 0)
    }

    func testCaptureDimensionsRejectNonfiniteAndStayPositiveAndBounded() {
        for size in [CGSize.zero, CGSize(width: -1, height: 1), CGSize(width: .infinity, height: 1),
                     CGSize(width: 1, height: CGFloat.nan)] {
            XCTAssertNil(LiveCaptureLimits.boundedSize(size))
        }
        XCTAssertEqual(LiveCaptureLimits.boundedSize(CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(LiveCaptureLimits.boundedSize(CGSize(width: 1, height: 8192)), CGSize(width: 1, height: 1920))
        XCTAssertEqual(LiveCaptureLimits.boundedSize(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1)), CGSize(width: 1920, height: 1))
    }
}
