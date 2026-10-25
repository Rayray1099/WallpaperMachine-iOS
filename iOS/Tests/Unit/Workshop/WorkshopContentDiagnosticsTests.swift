// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import WallpaperMachineIOS

final class WorkshopContentDiagnosticsTests: XCTestCase {
    func testDiscoveryFailuresHaveDistinctFriendlyMessagesAndSafeCodes() {
        let keys = ["content_connection_failed", "app_info_failed", "workshop_depot_missing"].map {
            let failure = WorkshopContentDiagnostics.failure($0)
            XCTAssertEqual(failure.code, $0)
            return failure.localizationKey
        }
        XCTAssertEqual(Set(keys).count, 3)
    }

    func testUnknownNativeMessagesNeverBecomeVisibleDiagnostics() {
        for raw in ["", "new_native_failure", "content_connection_failed token=SECRET",
                    "content_connection_failed\npassword=SECRET", " CONTENT_CONNECTION_FAILED ",
                    "https://user:SECRET@example.invalid/error", "帳號秘密"] {
            let failure = WorkshopContentDiagnostics.failure(raw)
            XCTAssertNil(failure.code)
            XCTAssertEqual(failure.localizationKey, "workshop.native.error.generic")
            XCTAssertFalse(WorkshopContentDiagnostics.localizedError(raw).contains("SECRET"))
        }
    }

    func testAllowlistRequiresExactProtocolCode() {
        let code = "file_hash_mismatch"
        XCTAssertEqual(WorkshopContentDiagnostics.failure(code).code, code)
        for decorated in [code + ": details", code + " ", code.uppercased(), "prefix_" + code] {
            XCTAssertNil(WorkshopContentDiagnostics.failure(decorated).code)
        }
    }

    func testNewNativeStagesAreExplicitAndUnknownStageIsNotEchoed() {
        for phase in ["resolving_depot", "discovering_content", "authorizing_manifest"] {
            XCTAssertEqual(WorkshopContentDiagnostics.phaseLocalizationKey(phase), "workshop.native.phase." + phase)
        }
        XCTAssertEqual(WorkshopContentDiagnostics.phaseLocalizationKey("server-secret"), "workshop.native.phase.waiting")
    }
}
