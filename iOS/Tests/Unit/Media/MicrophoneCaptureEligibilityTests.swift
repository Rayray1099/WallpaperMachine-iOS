// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import WallpaperMachineIOS

final class MicrophoneCaptureEligibilityTests: XCTestCase {
    func testCaptureRequiresEnabledActiveAppAndVisibleConsumer() {
        XCTAssertTrue(MicrophoneCaptureEligibility(
            isEnabled: true, applicationActive: true, visibleConsumerCount: 1).shouldCapture)

        XCTAssertFalse(MicrophoneCaptureEligibility(
            isEnabled: false, applicationActive: true, visibleConsumerCount: 1).shouldCapture)
        XCTAssertFalse(MicrophoneCaptureEligibility(
            isEnabled: true, applicationActive: false, visibleConsumerCount: 1).shouldCapture)
        XCTAssertFalse(MicrophoneCaptureEligibility(
            isEnabled: true, applicationActive: true, visibleConsumerCount: 0).shouldCapture)
        XCTAssertFalse(MicrophoneCaptureEligibility(
            isEnabled: true, applicationActive: true, visibleConsumerCount: -1).shouldCapture)
    }

    func testAdditionalVisibleConsumersDoNotDisableCapture() {
        XCTAssertTrue(MicrophoneCaptureEligibility(
            isEnabled: true, applicationActive: true, visibleConsumerCount: 2).shouldCapture)
    }
}
