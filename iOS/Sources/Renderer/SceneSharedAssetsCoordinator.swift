// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Process-local ownership of the shared resource mount. Native readers are all
/// destroyed before publication; only the matching owner may release the gate.
/// Weak registration never extends a view's lifetime or revives a dismantled one.
@MainActor
final class SceneSharedAssetsCoordinator {
    static let shared = SceneSharedAssetsCoordinator()

    enum CoordinationError: Error, LocalizedError {
        case busy
        var errorDescription: String? { NSLocalizedString("scene.assets.error.busy", comment: "Resource operation already in progress") }
    }

    private final class WeakSurface {
        weak var value: SceneMetalSurface?
        init(_ value: SceneMetalSurface) { self.value = value }
    }

    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]
    private var installationToken: UUID?
    private var exportToken: UUID?

    private init() {}

    var isInstallingAssets: Bool { installationToken != nil }

    func register(_ surface: SceneMetalSurface) {
        discardReleasedSurfaces()
        surfaces[ObjectIdentifier(surface)] = WeakSurface(surface)
    }

    func unregister(_ surface: SceneMetalSurface) {
        surfaces.removeValue(forKey: ObjectIdentifier(surface))
    }

    /// Invoked only after the archive has passed full CRC/hash validation.
    /// Blocks creation first, then synchronously closes every native VFS reader.
    func beginAssetInstallation() throws -> UUID {
        guard installationToken == nil, exportToken == nil else { throw CoordinationError.busy }
        let token = UUID()
        installationToken = token
        discardReleasedSurfaces()
        for entry in surfaces.values { entry.value?.prepareForSharedAssetsReplacement() }
        return token
    }

    /// Required on success, cancellation and failure. A mismatched/stale token
    /// cannot release another import's gate. Reinitialization remains layout-driven.
    func endAssetInstallation(token: UUID) {
        guard installationToken == token else { return }
        installationToken = nil
        discardReleasedSurfaces()
        for entry in surfaces.values { entry.value?.resumeAfterSharedAssetsReplacement() }
    }

    /// The scene export controller reserves before preparing its surface and keeps
    /// this lease through finish/failure/cancellation. At most one scene export.
    func beginExport() throws -> UUID {
        guard installationToken == nil, exportToken == nil else { throw CoordinationError.busy }
        let token = UUID()
        exportToken = token
        return token
    }

    func endExport(token: UUID) {
        guard exportToken == token else { return }
        exportToken = nil
    }

    private func discardReleasedSurfaces() {
        surfaces = surfaces.filter { $0.value.value != nil }
    }
}
