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

    func testChunkTransferCodesAreAllowlistedButNearMissesAreNot() {
        let codes = [
            "chunk_http_401", "chunk_http_403", "chunk_http_404", "chunk_http_429", "chunk_http_5xx",
            "chunk_http_failed", "chunk_request_failed", "chunk_decrypt_failed", "chunk_format_unsupported",
            "chunk_decompress_failed", "chunk_size_mismatch", "chunk_checksum_mismatch", "chunk_write_failed",
            "chunk_download_failed"
        ]
        for code in codes {
            let failure = WorkshopContentDiagnostics.failure(code)
            XCTAssertEqual(failure.code, code)
            XCTAssertEqual(failure.localizationKey, "workshop.native.error.transfer")
            for nearMiss in [code + ": SECRET", code + "\npassword=SECRET", " " + code,
                             code + " ", code.uppercased(), "prefix_" + code, code + "\0"] {
                let unknown = WorkshopContentDiagnostics.failure(nearMiss)
                XCTAssertNil(unknown.code)
                XCTAssertEqual(unknown.localizationKey, "workshop.native.error.generic")
                XCTAssertFalse(WorkshopContentDiagnostics.localizedError(nearMiss).contains("SECRET"))
            }
        }
        for unlisted in ["chunk_http_500", "chunk_http_502", "chunk_http_503", "chunk_http_402",
                         "chunk_http_5XX", "chunk_checksum_failed", "chunk_", "chunk_download_failed_extra"] {
            XCTAssertNil(WorkshopContentDiagnostics.failure(unlisted).code)
        }
    }

    func testNewNativeStagesAreExplicitAndUnknownStageIsNotEchoed() {
        for phase in ["resolving_depot", "discovering_content", "authorizing_manifest"] {
            XCTAssertEqual(WorkshopContentDiagnostics.phaseLocalizationKey(phase), "workshop.native.phase." + phase)
        }
        XCTAssertEqual(WorkshopContentDiagnostics.phaseLocalizationKey("server-secret"), "workshop.native.phase.waiting")
    }
}
