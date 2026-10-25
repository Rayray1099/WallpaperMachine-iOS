// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import ZIPFoundation

/// Imports only explicitly selected, user-owned resources into the native /assets
/// mount. No resource is bundled, downloaded, executed or substituted by this store.
actor SceneSharedAssetsInstaller {
    struct Limits: Sendable {
        var archiveBytes: UInt64 = 512 * 1024 * 1024
        var extractedBytes: UInt64 = 512 * 1024 * 1024
        var fileBytes: UInt64 = 64 * 1024 * 1024
        var manifestBytes: UInt64 = 1024 * 1024
        var fileCount: Int = 20_000
        var reserveBytes: UInt64 = 64 * 1024 * 1024
    }

    struct Receipt: Equatable, Sendable {
        let fileCount: Int
        let byteCount: UInt64
        let manifestSHA256: String
        /// The previous owned resource directory is retained, never deleted.
        let retainedBackupName: String?
    }

    enum InstallError: String, Error, LocalizedError, Sendable {
        case busy, invalidArchive, invalidManifest, unsupportedPath, limits
        case hashMismatch, unsafeDestination, insufficientSpace, publication, rollback

        var localizationKey: String { "scene.assets.error." + rawValue }
        var errorDescription: String? { NSLocalizedString(localizationKey, comment: "Shared assets import failure") }
    }

    private struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let bytes: UInt64
            let sha256: String
        }
        let schema: String
        let files: [File]
    }

    private struct Plan {
        let files: [Manifest.File]
        let entries: [String: Entry]
        let total: UInt64
        let digest: String
    }

    private static let manifestName = "wmassets-manifest.json"
    private static let schema = "wallpapermachine.shared-assets/v1"
    private static let roots: Set<String> = ["shaders", "materials", "textures", "models", "scripts", "particles"]
    private static let forbiddenExtensions: Set<String> = ["exe", "dll", "dylib", "so", "app", "com", "bat", "cmd", "ps1", "msi", "sh"]
    private let applicationSupport: URL?
    private let limits: Limits
    private var installing = false
    /// Publication and extraction stay exclusive even across independently created
    /// Settings views/installer actors, including while the lifecycle gate awaits.
    private static let ownership = Ownership()

    private actor Ownership {
        private var held = false
        func acquire() throws {
            guard !held else { throw InstallError.busy }
            held = true
        }
        func release() { held = false }
    }

    init(applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
         limits: Limits = Limits()) {
        self.applicationSupport = applicationSupport
        self.limits = limits
    }

    /// All validation and streaming extraction precede `willPublish`. The callback
    /// must suspend/destroy every reader of the shared mount and prevent new ones
    /// until its owner handles success OR failure. It must throw if export is active.
    /// There is no suspension point between the two publication renames/rollback.
    func install(from archiveURL: URL,
                 willPublish: @MainActor @Sendable () async throws -> Void) async throws -> Receipt {
        guard !installing else { throw InstallError.busy }
        installing = true
        defer { installing = false }
        try await Self.ownership.acquire()
        do {
            let receipt = try await installExclusively(from: archiveURL, willPublish: willPublish)
            await Self.ownership.release()
            return receipt
        } catch {
            await Self.ownership.release()
            throw error
        }
    }

    private func installExclusively(from archiveURL: URL,
                                    willPublish: @MainActor @Sendable () async throws -> Void) async throws -> Receipt {
        let fm = FileManager.default
        let granted = archiveURL.startAccessingSecurityScopedResource()
        defer { if granted { archiveURL.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            guard archiveURL.isFileURL else { throw InstallError.invalidArchive }
            let sourceValues = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true,
                  let sourceBytes = sourceValues.fileSize, sourceBytes > 0,
                  UInt64(sourceBytes) <= limits.archiveBytes else { throw InstallError.invalidArchive }
            let parent = try prepareParent()
            let target = parent.appendingPathComponent("SharedAssets", isDirectory: true)
            try validateTarget(target)
            let stage = parent.appendingPathComponent(".shared-assets-install-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) } // Only this freshly created owned path.
            let snapshot = stage.appendingPathComponent("input.zip")
            try copySnapshot(from: archiveURL, to: snapshot)
            try validateZIPHeaders(snapshot)
            let archive = try Archive(url: snapshot, accessMode: .read)
            let plan = try preflight(archive)
            try checkSpace(at: parent, needed: plan.total)
            let payload = stage.appendingPathComponent("payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: false)
            var extracted: UInt64 = 0
            for file in plan.files {
                try Task.checkCancellation()
                guard let entry = plan.entries[file.path] else { throw InstallError.invalidManifest }
                let destination = payload.appendingPathComponent(file.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: destination.path, contents: nil) else { throw InstallError.invalidArchive }
                let handle = try FileHandle(forWritingTo: destination)
                var hasher = SHA256()
                var written: UInt64 = 0
                do {
                    let crc = try archive.extract(entry, bufferSize: 65_536, skipCRC32: false) { data in
                        try Task.checkCancellation()
                        let size = UInt64(data.count)
                        guard written <= file.bytes, size <= file.bytes - written,
                              extracted <= self.limits.extractedBytes,
                              size <= self.limits.extractedBytes - extracted else { throw InstallError.limits }
                        try handle.write(contentsOf: data)
                        hasher.update(data: data)
                        written += size
                        extracted += size
                    }
                    try handle.close()
                    guard crc == entry.checksum, written == file.bytes,
                          Self.hex(hasher.finalize()) == file.sha256 else { throw InstallError.hashMismatch }
                } catch {
                    try? handle.close()
                    throw error
                }
            }
            guard extracted == plan.total else { throw InstallError.invalidManifest }
            // Retain the provenance alongside installed resources, but do not mount
            // the input ZIP. The manifest cannot declare or overwrite itself.
            let manifestData = try read(entry: plan.entries[Self.manifestName]!, from: archive, limit: limits.manifestBytes)
            try manifestData.write(to: payload.appendingPathComponent(Self.manifestName), options: .withoutOverwriting)
            try Task.checkCancellation()
            do { try await willPublish() }
            catch is CancellationError { throw CancellationError() }
            catch { throw InstallError.publication }
            try Task.checkCancellation()
            guard try prepareParent() == parent else { throw InstallError.unsafeDestination }
            try validateTarget(target)
            let backupName = fm.fileExists(atPath: target.path) ? "SharedAssets-backup-" + UUID().uuidString : nil
            let backup = backupName.map { parent.appendingPathComponent($0, isDirectory: true) }
            if let backup {
                do { try fm.moveItem(at: target, to: backup) }
                catch { throw InstallError.publication }
            }
            do {
                try fm.moveItem(at: payload, to: target)
            } catch {
                if let backup {
                    do { try fm.moveItem(at: backup, to: target) }
                    catch { throw InstallError.rollback }
                }
                throw InstallError.publication
            }
            // No throwing/cancellation work after publication: this receipt is the
            // commit point. The old directory remains untouched in its backup.
            return Receipt(fileCount: plan.files.count, byteCount: plan.total,
                           manifestSHA256: plan.digest, retainedBackupName: backupName)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as InstallError {
            throw error
        } catch {
            // Never expose Foundation/ZIP diagnostics containing paths.
            throw InstallError.invalidArchive
        }
    }

    private func prepareParent() throws -> URL {
        let fm = FileManager.default
        guard let applicationSupport, applicationSupport.isFileURL else { throw InstallError.unsafeDestination }
        // Darwin's system-owned /var alias is legitimate. Reject links below the
        // trusted container root, not the canonical system alias itself.
        let root = applicationSupport.standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("WallpaperMachine", isDirectory: true)
        if (try? fm.destinationOfSymbolicLink(atPath: parent.path)) != nil { throw InstallError.unsafeDestination }
        var directory: ObjCBool = false
        if fm.fileExists(atPath: parent.path, isDirectory: &directory) {
            guard directory.boolValue else { throw InstallError.unsafeDestination }
        } else {
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        return parent
    }

    private func validateTarget(_ target: URL) throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { throw InstallError.unsafeDestination }
        var directory: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &directory), !directory.boolValue {
            throw InstallError.unsafeDestination
        }
    }

    private func copySnapshot(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try checkSpace(at: destination.deletingLastPathComponent(), needed: UInt64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw InstallError.invalidArchive }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var size: UInt64 = 0
        while let data = try input.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            guard UInt64(data.count) <= limits.archiveBytes - size else { throw InstallError.limits }
            try output.write(contentsOf: data)
            size += UInt64(data.count)
        }
        guard size > 0 else { throw InstallError.invalidArchive }
    }

    private func checkSpace(at url: URL, needed: UInt64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              needed <= UInt64.max - limits.reserveBytes,
              free.uint64Value >= needed + limits.reserveBytes else { throw InstallError.insufficientSpace }
    }

    /// ZIPFoundation intentionally maps Unix special-file modes to ordinary file
    /// entries. Validate raw central metadata first so FIFOs/devices/executables,
    /// encryption and ZIP64 cannot be smuggled through that normalized entry type.
    private func validateZIPHeaders(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw InstallError.invalidArchive }
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count >= 22 else { throw InstallError.invalidArchive }
        func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        func u32(_ data: Data, _ at: Int) -> UInt32 { UInt32(u16(data, at)) | UInt32(u16(data, at + 2)) << 16 }
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, index) == 0x06054b50, index + 22 + Int(u16(tail, index + 20)) == tail.count {
                end = index
                break
            }
        }
        guard let end, u16(tail, end + 4) == 0, u16(tail, end + 6) == 0 else { throw InstallError.invalidArchive }
        let count = Int(u16(tail, end + 10))
        let centralBytes = UInt64(u32(tail, end + 12))
        let offset = UInt64(u32(tail, end + 16))
        guard count > 0, count <= limits.fileCount * 2 + 1,
              count == Int(u16(tail, end + 8)), count < 65_535,
              centralBytes <= 32 * 1024 * 1024, offset + centralBytes == size - tailSize + UInt64(end) else { throw InstallError.invalidArchive }
        try handle.seek(toOffset: offset)
        guard let central = try handle.read(upToCount: Int(centralBytes)), UInt64(central.count) == centralBytes else { throw InstallError.invalidArchive }
        var cursor = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor <= central.count - 46, u32(central, cursor) == 0x02014b50 else { throw InstallError.invalidArchive }
            let flags = u16(central, cursor + 8)
            let method = u16(central, cursor + 10)
            let attributes = u32(central, cursor + 38)
            let mode = (attributes >> 16) & 0xffff
            let kind = mode & 0xf000
            let system = central[cursor + 5]
            guard flags & 0x41 == 0, method == 0 || method == 8, u16(central, cursor + 34) == 0,
                  u32(central, cursor + 20) != UInt32.max, u32(central, cursor + 24) != UInt32.max,
                  u32(central, cursor + 42) != UInt32.max, attributes & 0x400 == 0,
                  (system != 3 && system != 19) || ((kind == 0 || kind == 0x8000 || kind == 0x4000) && (kind != 0x8000 || mode & 0o111 == 0)) else { throw InstallError.unsupportedPath }
            let nameBytes = Int(u16(central, cursor + 28))
            let extraBytes = Int(u16(central, cursor + 30))
            let commentBytes = Int(u16(central, cursor + 32))
            let length = 46 + nameBytes + extraBytes + commentBytes
            guard length <= central.count - cursor,
                  let name = String(data: central.subdata(in: cursor + 46..<cursor + 46 + nameBytes), encoding: .utf8) else { throw InstallError.invalidArchive }
            let directory = name.hasSuffix("/")
            guard kind != 0x4000 || directory, kind != 0x8000 || !directory else { throw InstallError.unsupportedPath }
            try Self.validate(path: directory ? String(name.dropLast()) : name, directory: directory)
            cursor += length
        }
        guard cursor == central.count else { throw InstallError.invalidArchive }
    }

    private func preflight(_ archive: Archive) throws -> Plan {
        var entries: [String: Entry] = [:]
        var normalized: Set<String> = []
        var files: Set<String> = []
        var directories: Set<String> = []
        var nodeKinds: [String: Bool] = [:]
        var nodeSpellings: [String: String] = [:]
        var total: UInt64 = 0
        var entryCount = 0
        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= limits.fileCount * 2 + 1 else { throw InstallError.limits }
            guard entry.type == .file || entry.type == .directory else { throw InstallError.unsupportedPath }
            let directory = entry.type == .directory
            let path = directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            try Self.validate(path: path, directory: directory)
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard normalized.insert(key).inserted else { throw InstallError.unsupportedPath }
            let components = path.split(separator: "/")
            for depth in 1...components.count {
                let prefix = components.prefix(depth).joined(separator: "/")
                let prefixKey = prefix.precomposedStringWithCanonicalMapping.lowercased()
                let isDirectory = depth < components.count || directory
                if let prior = nodeKinds[prefixKey] {
                    guard prior == isDirectory, nodeSpellings[prefixKey] == prefix else { throw InstallError.unsupportedPath }
                } else {
                    nodeKinds[prefixKey] = isDirectory
                    nodeSpellings[prefixKey] = prefix
                }
            }
            if directory {
                guard entry.uncompressedSize == 0 else { throw InstallError.invalidArchive }
                directories.insert(path)
            } else {
                guard UInt64(entry.uncompressedSize) <= (path == Self.manifestName ? limits.manifestBytes : limits.fileBytes) else { throw InstallError.limits }
                entries[path] = entry
                if path != Self.manifestName {
                    guard files.count < limits.fileCount,
                          UInt64(entry.uncompressedSize) <= limits.extractedBytes - total else { throw InstallError.limits }
                    files.insert(path)
                    total += UInt64(entry.uncompressedSize)
                }
            }
        }
        guard let manifestEntry = entries[Self.manifestName], !files.isEmpty,
              files.contains(where: { $0.hasPrefix("shaders/") }) else { throw InstallError.invalidManifest }
        let data = try read(entry: manifestEntry, from: archive, limit: limits.manifestBytes)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw InstallError.invalidManifest }
        guard manifest.schema == Self.schema, manifest.files.count == files.count else { throw InstallError.invalidManifest }
        var declared: Set<String> = []
        var parents: Set<String> = []
        var declaredTotal: UInt64 = 0
        for file in manifest.files {
            try Self.validate(path: file.path, directory: false)
            guard file.path != Self.manifestName, declared.insert(file.path).inserted,
                  let entry = entries[file.path], file.bytes == UInt64(entry.uncompressedSize),
                  file.bytes <= limits.fileBytes, file.sha256.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  file.bytes <= limits.extractedBytes - declaredTotal else { throw InstallError.invalidManifest }
            declaredTotal += file.bytes
            let parts = file.path.split(separator: "/")
            for depth in 1..<parts.count { parents.insert(parts.prefix(depth).joined(separator: "/")) }
        }
        guard declared == files, declaredTotal == total, directories.isSubset(of: parents),
              files.isDisjoint(with: parents) else { throw InstallError.invalidManifest }
        return Plan(files: manifest.files, entries: entries, total: total, digest: Self.hex(SHA256.hash(data: data)))
    }

    private func read(entry: Entry, from archive: Archive, limit: UInt64) throws -> Data {
        var result = Data()
        let crc = try archive.extract(entry, bufferSize: 65_536, skipCRC32: false) { data in
            try Task.checkCancellation()
            guard UInt64(result.count) <= limit, UInt64(data.count) <= limit - UInt64(result.count) else { throw InstallError.limits }
            result.append(data)
        }
        guard crc == entry.checksum, result.count == Int(entry.uncompressedSize) else { throw InstallError.hashMismatch }
        return result
    }

    private static func validate(path: String, directory: Bool) throws {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InstallError.unsupportedPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") || $0.hasSuffix(".") || $0.hasSuffix(" ") }) else { throw InstallError.unsupportedPath }
        if path == manifestName, !directory { return }
        guard let first = parts.first, roots.contains(String(first)), directory || parts.count >= 2,
              !forbiddenExtensions.contains((path as NSString).pathExtension.lowercased()) else { throw InstallError.unsupportedPath }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
