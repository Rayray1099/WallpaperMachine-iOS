// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Writable host directories, not bundled Wallpaper Engine assets.
struct SceneResourceDirectories {
    enum PreparationError: Error { case sharedAssetsUnavailable }

    let sharedAssets: URL
    /// The native engine accepts an empty cache path and compiles without caching.
    let shaderCache: URL?

    static func prepare(
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        fileManager: FileManager = .default
    ) throws -> SceneResourceDirectories {
        let assets: URL
        do {
            guard let applicationSupport else { throw PreparationError.sharedAssetsUnavailable }
            let root = try prepareRoot(applicationSupport, fileManager: fileManager)
            let support = try prepareChild("WallpaperMachine", under: root, fileManager: fileManager)
            assets = try prepareChild("SharedAssets", under: support, fileManager: fileManager)
        } catch {
            throw PreparationError.sharedAssetsUnavailable
        }

        // A cache is optional, unlike the /assets mount: do not pass a path the
        // host failed to prepare, and do not block playback when caching fails.
        let cache = caches.flatMap { root in
            try? prepareChild("SceneShaders", under: prepareRoot(root, fileManager: fileManager), fileManager: fileManager)
        }
        return SceneResourceDirectories(sharedAssets: assets, shaderCache: cache)
    }

    private static func prepareRoot(_ url: URL, fileManager: FileManager) throws -> URL {
        guard url.isFileURL else { throw PreparationError.sharedAssetsUnavailable }
        // System container roots may use /var aliases on Darwin. Only children
        // owned by this helper reject symbolic links; the trusted root may alias.
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func prepareChild(_ name: String, under root: URL, fileManager: FileManager) throws -> URL {
        let child = root.appendingPathComponent(name, isDirectory: true)
        // Never follow an existing child link and create directories outside the
        // supplied root, including dangling links and links to other owned data.
        if (try? fileManager.destinationOfSymbolicLink(atPath: child.path)) != nil {
            throw PreparationError.sharedAssetsUnavailable
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw PreparationError.sharedAssetsUnavailable }
        } else {
            try fileManager.createDirectory(at: child, withIntermediateDirectories: false)
        }
        return child
    }
}
