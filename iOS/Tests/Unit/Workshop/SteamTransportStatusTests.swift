// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import WallpaperMachineIOS

final class SteamTransportStatusTests: XCTestCase {
    func testCancellationRaceTreatsEveryNativeTerminalAsFinished() throws {
        for phase in ["done", "error", "cancelled"] {
            let data = Data("{\"phase\":\"\(phase)\",\"received\":2,\"total\":4,\"message\":\"\",\"guard_type\":\"\"}".utf8)
            XCTAssertTrue(try JSONDecoder().decode(SteamTransportStatus.self, from: data).isTerminal)
        }
    }
    func testUnknownLengthDoesNotInventPercentageAndKnownLengthClamps() throws {
        func status(_ received: UInt64, _ total: UInt64) -> SteamTransportStatus {
            SteamTransportStatus(phase: "downloading", received: received, total: total, message: "", guard_type: "")
        }
        XCTAssertNil(status(5, 0).fraction)
        XCTAssertEqual(status(5, 10).fraction, 0.5)
        XCTAssertEqual(status(15, 10).fraction, 1)
        XCTAssertFalse(status(0, 10).isTerminal)
    }
}
