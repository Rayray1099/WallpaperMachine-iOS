// SPDX-License-Identifier: GPL-3.0-only
// Compile with SceneResourceDirectories.swift; Foundation only, no app launch or XCTest.
import Foundation

@main
struct SceneResourceDirectoryRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: SceneResourceDirectories: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("wm-scene-resources-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(description: label) }
            checks += 1
        }
        func directory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        func roots(_ name: String) -> (URL, URL) {
            let base = scratch.appendingPathComponent(name, isDirectory: true)
            return (base.appendingPathComponent("Application Support", isDirectory: true),
                    base.appendingPathComponent("Caches", isDirectory: true))
        }
        func rejects(_ support: URL?, caches: URL?) throws {
            do { _ = try SceneResourceDirectories.prepare(applicationSupport: support, caches: caches, fileManager: fm) }
            catch SceneResourceDirectories.PreparationError.sharedAssetsUnavailable { checks += 1; return }
            throw Failure(description: "Invalid shared asset directory did not fail with the typed startup error")
        }
        let marker = Data("Preserve user-owned bytes".utf8)

        // Reproduce the old host's setup in an isolated new container, then run
        // the actual helper against those same roots. No renderer/Metal is used.
        let (support, caches) = roots("fresh")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let previousAssets = support.appendingPathComponent("WallpaperMachine/SharedAssets", isDirectory: true)
        let previousCache = caches.appendingPathComponent("SceneShaders", isDirectory: true)
        try? fm.createDirectory(at: previousCache, withIntermediateDirectories: true)
        try require(!directory(previousAssets), "Previous setup unexpectedly created the shared asset directory")
        print("BASELINE: previous host leaves SharedAssets missing although its cache exists")
        let fresh = try SceneResourceDirectories.prepare(applicationSupport: support, caches: caches, fileManager: fm)
        try require(directory(fresh.sharedAssets), "Fresh shared asset directory was not created")
        try require(fresh.sharedAssets.path == previousAssets.standardizedFileURL.resolvingSymlinksInPath().path, "Shared asset path contract changed")
        try require(fresh.shaderCache?.path == previousCache.standardizedFileURL.resolvingSymlinksInPath().path, "Shader cache path contract changed")
        try require(try fm.contentsOfDirectory(atPath: fresh.sharedAssets.path).isEmpty, "Fresh shared asset directory must remain empty")

        // Existing user assets and shader cache files survive repeated startup.
        let asset = fresh.sharedAssets.appendingPathComponent("user-owned.asset")
        let cached = previousCache.appendingPathComponent("shader.cache")
        try marker.write(to: asset)
        try marker.write(to: cached)
        let existing = try SceneResourceDirectories.prepare(applicationSupport: support, caches: caches, fileManager: fm)
        try require(existing.sharedAssets == fresh.sharedAssets, "Repeated startup changed the shared asset root")
        try require(try Data(contentsOf: asset) == marker, "Existing user assets were modified")
        try require(try Data(contentsOf: cached) == marker, "Existing shader cache was modified")

        // Missing container roots can be created, but regular files at any
        // required level are errors and must never be replaced or removed.
        let (newSupport, newCaches) = roots("new-roots")
        let new = try SceneResourceDirectories.prepare(applicationSupport: newSupport, caches: newCaches, fileManager: fm)
        try require(directory(new.sharedAssets) && new.shaderCache.map(directory) == true, "Missing injected roots were not prepared")
        for component in ["", "WallpaperMachine", "WallpaperMachine/SharedAssets"] {
            let (blockedSupport, blockedCaches) = roots("conflict-" + UUID().uuidString)
            let conflict = component.isEmpty ? blockedSupport : blockedSupport.appendingPathComponent(component)
            try fm.createDirectory(at: conflict.deletingLastPathComponent(), withIntermediateDirectories: true)
            try marker.write(to: conflict)
            try rejects(blockedSupport, caches: blockedCaches)
            try require(try Data(contentsOf: conflict) == marker, "Conflicting regular file was modified")
            try require(!fm.fileExists(atPath: blockedCaches.path), "Cache setup ran after required asset directory failure")
        }
        let (_, nilSupportCaches) = roots("nil-support")
        try rejects(nil, caches: nilSupportCaches)
        try require(!fm.fileExists(atPath: nilSupportCaches.path), "Missing support root caused an unrelated cache write")
        try rejects(URL(string: "https://example.invalid/not-a-file")!, caches: nilSupportCaches)

        // Optional cache failure cannot prevent a project-local scene loading.
        let noCache = try SceneResourceDirectories.prepare(applicationSupport: support, caches: nil, fileManager: fm)
        try require(noCache.shaderCache == nil && directory(noCache.sharedAssets), "Missing optional cache blocked shared asset preparation")
        for component in ["", "SceneShaders"] {
            let (cacheSupport, cacheRoot) = roots("cache-conflict-" + UUID().uuidString)
            let conflict = component.isEmpty ? cacheRoot : cacheRoot.appendingPathComponent(component)
            try fm.createDirectory(at: conflict.deletingLastPathComponent(), withIntermediateDirectories: true)
            try marker.write(to: conflict)
            let result = try SceneResourceDirectories.prepare(applicationSupport: cacheSupport, caches: cacheRoot, fileManager: fm)
            try require(result.shaderCache == nil && directory(result.sharedAssets), "Cache conflict prevented required asset preparation")
            try require(try Data(contentsOf: conflict) == marker, "Conflicting optional cache file was modified")
        }

        // Fixed child components must not follow links to another directory.
        // All fixtures (including the outside sentinel) remain under scratch;
        // the test never touches real Application Support, Caches or user assets.
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try marker.write(to: sentinel)
        for component in ["WallpaperMachine", "WallpaperMachine/SharedAssets"] {
            let (linkSupport, linkCaches) = roots("link-" + UUID().uuidString)
            let link = linkSupport.appendingPathComponent(component, isDirectory: true)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            try rejects(linkSupport, caches: linkCaches)
        }
        let (danglingSupport, danglingCaches) = roots("dangling-link")
        let dangling = danglingSupport.appendingPathComponent("WallpaperMachine", isDirectory: true)
        try fm.createDirectory(at: danglingSupport, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing", isDirectory: true))
        try rejects(danglingSupport, caches: danglingCaches)
        let (cacheLinkSupport, cacheLinkRoot) = roots("cache-link")
        try fm.createDirectory(at: cacheLinkRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cacheLinkRoot.appendingPathComponent("SceneShaders", isDirectory: true), withDestinationURL: outside)
        let cacheLink = try SceneResourceDirectories.prepare(applicationSupport: cacheLinkSupport, caches: cacheLinkRoot, fileManager: fm)
        try require(cacheLink.shaderCache == nil, "Optional cache followed a child link")
        try require(try Data(contentsOf: sentinel) == marker, "Outside sentinel was modified")
        try require(try fm.contentsOfDirectory(atPath: outside.path) == ["sentinel"], "Preparation wrote outside injected roots")
        print("PASS: fresh and existing roots, preservation, required file conflicts, optional cache failures, child links, outside-write guards (\(checks) checks)")
        print("Scope: Foundation filesystem regression only; no app, device, shader or Metal rendering verification.")
    }
}
