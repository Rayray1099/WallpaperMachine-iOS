// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// The filesystem implementation is deliberately separate from the main-actor UI store.
/// Call through a serial task/actor. No import modifies its source; no backup contains sign-ins.
public final class LibraryRepository {
    public let rootURL: URL
    private let fm = FileManager.default
    private let byteLimit: Int64 = 20 * 1024 * 1024 * 1024
    private let fileLimit = 100_000
    private var manifestURL: URL { rootURL.appendingPathComponent("library.json") }

    public init(rootURL: URL) { self.rootURL = rootURL.standardizedFileURL }

    public func load() throws -> LibraryManifest {
        try fm.createDirectory(at: rootURL.appendingPathComponent("Wallpapers"), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: manifestURL.path) else { return LibraryManifest() }
        let data = try Data(contentsOf: manifestURL)
        guard data.count < 32 * 1024 * 1024 else { throw LibraryError.tooLarge }
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
        try validate(manifest, at: rootURL)
        return manifest
    }

    public func save(_ manifest: LibraryManifest) throws {
        try validate(manifest, at: rootURL)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    public func importWallpaper(from sourceURL: URL, into original: LibraryManifest) throws -> LibraryManifest {
        let source = sourceURL.standardizedFileURL
        if source.pathExtension.lowercased() == "wmbackup" { return try restoreBackup(from: source) }
        let granted = ScopedAssetAccess.begin(source)
        defer { if granted { ScopedAssetAccess.end(source) } }
        let temp = fm.temporaryDirectory.appendingPathComponent("wm-import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? removeTemporary(temp, prefix: "wm-import-") }
        let staged = temp.appendingPathComponent("project", isDirectory: true)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw LibraryError.symbolicLink }
        if values.isDirectory == true {
            try inspectTree(source)
            try fm.copyItem(at: source, to: staged)
        } else if source.pathExtension.lowercased() == "zip" {
            try extractArchive(source, to: staged)
        } else {
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staged.appendingPathComponent(source.lastPathComponent))
        }
        let project = try projectRoot(in: staged)
        var item = try readProject(at: project, originalName: source.deletingPathExtension().lastPathComponent)
        var manifest = original
        if let id = item.workshopID, let existing = manifest.items.first(where: { $0.workshopID == id }) {
            item.id = existing.id; item.isFavorite = existing.isFavorite; item.collections = existing.collections
            for (key, property) in existing.properties where item.properties[key] != nil { item.properties[key]?.value = property.value }
            item.addedAt = existing.addedAt
        }
        item.relativePath = "Wallpapers/" + item.id.uuidString
        let destination = try AssetPath.resolve(item.relativePath, inside: rootURL)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prior = temp.appendingPathComponent("previous", isDirectory: true)
        let hadPrior = fm.fileExists(atPath: destination.path)
        if hadPrior { try fm.moveItem(at: destination, to: prior) }
        do {
            try fm.moveItem(at: project, to: destination)
            if let index = manifest.items.firstIndex(where: { $0.id == item.id }) { manifest.items[index] = item }
            else { manifest.items.append(item) }
            try save(manifest)
        } catch {
            if fm.fileExists(atPath: destination.path) { try? removeManaged(destination) }
            if hadPrior { try? fm.moveItem(at: prior, to: destination) }
            throw error
        }
        return manifest
    }

    public func remove(_ item: WallpaperItem, from original: LibraryManifest) throws -> LibraryManifest {
        var manifest = original
        guard manifest.items.contains(where: { $0.id == item.id && $0.relativePath == item.relativePath }) else {
            throw LibraryError.invalidPath(item.relativePath)
        }
        let target = try AssetPath.resolve(item.relativePath, inside: rootURL)
        let trash = rootURL.appendingPathComponent(".removed-" + UUID().uuidString)
        let existed = fm.fileExists(atPath: target.path)
        if existed { try fm.moveItem(at: target, to: trash) }
        manifest.items.removeAll { $0.id == item.id }; manifest.playlistIDs.removeAll { $0 == item.id }
        do { try save(manifest) }
        catch { if existed { try? fm.moveItem(at: trash, to: target) }; throw error }
        if existed { try removeManaged(trash) }
        return manifest
    }

    public func exportBackup(_ manifest: LibraryManifest, to destination: URL) throws {
        try validate(manifest, at: rootURL)
        let stage = fm.temporaryDirectory.appendingPathComponent("wm-backup-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? removeTemporary(stage, prefix: "wm-backup-") }
        try inspectTree(rootURL.appendingPathComponent("Wallpapers"))
        try fm.copyItem(at: rootURL.appendingPathComponent("Wallpapers"), to: stage.appendingPathComponent("Wallpapers"))
        try LibraryRepository(rootURL: stage).save(manifest)
        #if canImport(ZIPFoundation)
        let archive = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wmbackup")
        defer { if fm.fileExists(atPath: archive.path) { try? fm.removeItem(at: archive) } }
        try fm.zipItem(at: stage, to: archive, shouldKeepParent: false)
        let granted = ScopedAssetAccess.begin(destination)
        defer { if granted { ScopedAssetAccess.end(destination) } }
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.copyItem(at: archive, to: destination)
        #else
        throw LibraryError.unsupported("ZIPFoundation is not linked")
        #endif
    }

    public func restoreBackup(from source: URL) throws -> LibraryManifest {
        let granted = ScopedAssetAccess.begin(source)
        defer { if granted { ScopedAssetAccess.end(source) } }
        let parent = rootURL.deletingLastPathComponent()
        let stage = parent.appendingPathComponent("wm-restore-" + UUID().uuidString)
        let previous = parent.appendingPathComponent("wm-previous-" + UUID().uuidString)
        defer { try? removeSibling(stage, prefix: "wm-restore-") }
        try extractArchive(source, to: stage)
        let manifest = try LibraryRepository(rootURL: stage).load()
        try validate(manifest, at: stage)
        // Only the documented manifest and asset folder are part of this format.
        let names = try fm.contentsOfDirectory(atPath: stage.path)
        guard Set(names).isSubset(of: ["library.json", "Wallpapers"]) else { throw LibraryError.invalidBackup }
        guard fm.fileExists(atPath: stage.appendingPathComponent("library.json").path) else { throw LibraryError.invalidBackup }
        let existed = fm.fileExists(atPath: rootURL.path)
        if existed { try fm.moveItem(at: rootURL, to: previous) }
        do { try fm.moveItem(at: stage, to: rootURL) }
        catch { if existed { try? fm.moveItem(at: previous, to: rootURL) }; throw error }
        if existed { try? removeSibling(previous, prefix: "wm-previous-") }
        return manifest
    }

    private func validate(_ manifest: LibraryManifest, at root: URL) throws {
        guard manifest.version == 1, manifest.items.count <= fileLimit,
              Set(manifest.items.map(\.id)).count == manifest.items.count else { throw LibraryError.invalidBackup }
        for item in manifest.items {
            guard item.relativePath == "Wallpapers/" + item.id.uuidString else { throw LibraryError.invalidPath(item.relativePath) }
            let folder = try AssetPath.resolve(item.relativePath, inside: root)
            let entry = try AssetPath.resolve(item.entryFile, inside: folder)
            guard fm.fileExists(atPath: entry.path) else { throw LibraryError.missingEntry }
            if let preview = item.previewFile { _ = try AssetPath.resolve(preview, inside: folder) }
        }
    }

    private func inspectTree(_ root: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, _ in false }) else { throw LibraryError.missingEntry }
        var total: Int64 = 0; var count = 0
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw LibraryError.symbolicLink }
            guard values.isDirectory == true || values.isRegularFile == true else { throw LibraryError.unsupported(url.lastPathComponent) }
            count += 1; total += Int64(values.fileSize ?? 0)
            guard count <= fileLimit, total <= byteLimit else { throw LibraryError.tooLarge }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            _ = try AssetPath.resolve(relative, inside: root)
        }
    }

    private func extractArchive(_ source: URL, to destination: URL) throws {
        #if canImport(ZIPFoundation)
        let archive = try Archive(url: source, accessMode: .read)
        var total: UInt64 = 0; var count = 0
        for entry in archive {
            let name = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            try AssetPath.validate(name)
            guard entry.type != .symlink else { throw LibraryError.symbolicLink }
            total += UInt64(entry.uncompressedSize); count += 1
            guard total <= UInt64(byteLimit), count <= fileLimit else { throw LibraryError.tooLarge }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.unzipItem(at: source, to: destination)
        try inspectTree(destination)
        #else
        throw LibraryError.unsupported("ZIPFoundation is not linked")
        #endif
    }

    private func projectRoot(in root: URL) throws -> URL {
        if fm.fileExists(atPath: root.appendingPathComponent("project.json").path) { return root }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, (try children[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { return children[0] }
        return root
    }

    private func readProject(at folder: URL, originalName: String) throws -> WallpaperItem {
        let projectURL = folder.appendingPathComponent("project.json")
        var object: [String: Any] = [:]
        if fm.fileExists(atPath: projectURL.path) {
            let data = try Data(contentsOf: projectURL)
            guard data.count < 8 * 1024 * 1024 else { throw LibraryError.tooLarge }
            object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let kind: WallpaperKind
        let entry: String
        if let file = object["file"] as? String {
            entry = file; let type = (object["type"] as? String ?? "").lowercased()
            kind = WallpaperKind(rawValue: type) ?? guessKind(file)
        } else {
            let names = try fm.contentsOfDirectory(atPath: folder.path).sorted()
            if names.contains("scene.pkg") { entry = "scene.pkg"; kind = .scene }
            else if names.contains("index.html") { entry = "index.html"; kind = .web }
            else if let name = names.first(where: { isImportable($0) }) { entry = name; kind = guessKind(name) }
            else { throw LibraryError.unsupported(originalName) }
        }
        let entryURL = try AssetPath.resolve(entry, inside: folder)
        guard fm.fileExists(atPath: entryURL.path) else { throw LibraryError.missingEntry }
        var properties: [String: WallpaperProperty] = [:]
        let general = object["general"] as? [String: Any] ?? [:]
        for (key, raw) in general["properties"] as? [String: [String: Any]] ?? [:] {
            guard let rawValue = raw["value"], JSONSerialization.isValidJSONObject(["value": rawValue]) else { continue }
            let data = try JSONSerialization.data(withJSONObject: ["value": rawValue])
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String ?? $0["label"] as? String }
            properties[key] = WallpaperProperty(label: raw["text"] as? String ?? key, type: raw["type"] as? String ?? "text",
                value: decoded["value"] ?? .null, minimum: raw["min"] as? Double, maximum: raw["max"] as? Double, options: options)
        }
        let numericID = !originalName.isEmpty && originalName.allSatisfy(\.isNumber) ? originalName : nil
        var preview = object["preview"] as? String
        if let name = preview { _ = try AssetPath.resolve(name, inside: folder) }
        if preview == nil { preview = ["preview.jpg", "preview.png", "preview.gif"].first { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } }
        return WallpaperItem(title: object["title"] as? String ?? originalName, kind: kind, relativePath: "pending", entryFile: entry,
                             previewFile: preview, workshopID: object["workshopid"] as? String ?? numericID, properties: properties)
    }
    private func guessKind(_ name: String) -> WallpaperKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext) { return .video }
        if ["html", "htm"].contains(ext) { return .web }
        if ["pkg", "json"].contains(ext) { return .scene }
        return .image
    }
    private func isImportable(_ name: String) -> Bool {
        ["mp4", "mov", "m4v", "webm", "mkv", "html", "htm", "png", "jpg", "jpeg", "heic", "gif", "pkg", "json"].contains((name as NSString).pathExtension.lowercased())
    }
    private func removeManaged(_ target: URL) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw LibraryError.invalidPath(target.path) }
        try fm.removeItem(at: target)
    }
    private func removeTemporary(_ target: URL, prefix: String) throws {
        guard target.deletingLastPathComponent().standardizedFileURL == fm.temporaryDirectory.standardizedFileURL,
              target.lastPathComponent.hasPrefix(prefix) else { throw LibraryError.invalidPath(target.path) }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    }
    private func removeSibling(_ target: URL, prefix: String) throws {
        guard target.deletingLastPathComponent().standardizedFileURL == rootURL.deletingLastPathComponent().standardizedFileURL,
              target.lastPathComponent.hasPrefix(prefix), target != rootURL else { throw LibraryError.invalidPath(target.path) }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    }
}
