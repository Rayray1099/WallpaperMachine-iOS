// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Foundation security-scoped resources are Apple-only; keeping this boundary
/// explicit lets the same import/path code be type-checked and tested on Windows.
enum ScopedAssetAccess {
    static func begin(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }
    static func end(_ url: URL) {
        #if canImport(Darwin)
        url.stopAccessingSecurityScopedResource()
        #endif
    }
}
