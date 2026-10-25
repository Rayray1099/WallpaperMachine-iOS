// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only exact transport protocol codes may become visible diagnostics. Unknown
/// native messages may contain server text or credentials and are never echoed.
enum WorkshopContentDiagnostics {
    struct Failure: Equatable {
        let localizationKey: String
        let code: String?
    }

    static func failure(_ reason: String) -> Failure {
        let category: String
        switch reason {
        case "ownership_required": category = "ownership"
        case "content_signin_required": category = "signIn"
        case "login_rejected", "invalid_credentials": category = "credentials"
        case "login_timeout", "connection_failed": category = "connection"
        case "content_connection_failed": category = "contentConnection"
        case "app_info_failed": category = "appInfo"
        case "workshop_depot_missing": category = "workshopDepot"
        case "download_timeout", "operation_timeout": category = "timeout"
        case "item_access_denied", "item_unavailable", "item_type_unsupported", "invalid_item_id": category = "item"
        case "manifest_missing", "manifest_failed", "manifest_access_denied", "manifest_mismatch": category = "manifest"
        case "depot_access_denied", "app_access_denied", "ownership_check_failed": category = "access"
        case "wallpaper_project_missing": category = "project"
        case "import_failed": category = "import"
        case "write_failed", "invalid_destination": category = "storage"
        case "unsafe_manifest_path", "manifest_symlink_refused", "duplicate_manifest_path", "manifest_hash_missing",
             "verify_failed", "file_size_mismatch", "file_hash_mismatch": category = "integrity"
        case "content_too_large": category = "size"
        case "chunk_download_failed": category = "transfer"
        case "busy", "already_signed_in": category = "busy"
        case "native_failure", "invalid_operation", "unknown_task": category = "generic"
        default: return Failure(localizationKey: "workshop.native.error.generic", code: nil)
        }
        return Failure(localizationKey: "workshop.native.error." + category, code: reason)
    }

    static func localizedError(_ reason: String) -> String {
        let diagnostic = failure(reason)
        let friendly = NSLocalizedString(diagnostic.localizationKey, comment: "Native Workshop failure")
        guard let code = diagnostic.code else { return friendly }
        return String(format: NSLocalizedString("workshop.native.error.withCode", comment: "Friendly failure and allowlisted diagnostic code"), friendly, code)
    }

    static func phaseLocalizationKey(_ phase: String) -> String {
        switch phase {
        case "guard", "connecting", "authenticating", "checking_ownership", "resolving_item",
             "resolving_depot", "discovering_content", "authorizing_manifest", "fetching_manifest",
             "downloading", "done", "cancelled", "error":
            return "workshop.native.phase." + phase
        default: return "workshop.native.phase.waiting"
        }
    }
}
