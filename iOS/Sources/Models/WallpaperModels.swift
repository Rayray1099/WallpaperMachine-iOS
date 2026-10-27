// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}

public enum WallpaperKind: String, Codable, CaseIterable {
    case scene, video, web, image
}

/// Attribution retained with the managed image and included in library backups.
/// These keys match the upstream Pixiv project.json metadata.
public struct PixivAttribution: Codable, Hashable, Sendable {
    public let id: String
    public let page: Int
    public let pages: Int
    public let author: String
    public let authorId: String
    public let url: URL
    public let original: URL
    public let file: String
    public let width: Int
    public let height: Int

    public var libraryID: String { "pixiv-\(id)-p\(page)" }
}

public struct WallpaperProperty: Codable, Hashable {
    public var label: String
    public var type: String
    public var value: JSONValue
    public var minimum: Double?
    public var maximum: Double?
    public var options: [String]

    public init(label: String, type: String, value: JSONValue, minimum: Double? = nil,
                maximum: Double? = nil, options: [String] = []) {
        self.label = label; self.type = type; self.value = value
        self.minimum = minimum; self.maximum = maximum; self.options = options
    }
}

public struct WallpaperItem: Identifiable, Codable, Hashable {
    public var id: UUID
    public var title: String
    public var kind: WallpaperKind
    public var relativePath: String
    public var entryFile: String
    public var previewFile: String?
    public var workshopID: String?
    public var pixiv: PixivAttribution?
    public var isFavorite: Bool
    public var collections: [String]
    public var properties: [String: WallpaperProperty]
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, kind: WallpaperKind, relativePath: String,
                entryFile: String, previewFile: String? = nil, workshopID: String? = nil, pixiv: PixivAttribution? = nil,
                isFavorite: Bool = false, collections: [String] = [],
                properties: [String: WallpaperProperty] = [:], addedAt: Date = Date()) {
        self.id = id; self.title = title; self.kind = kind; self.relativePath = relativePath
        self.entryFile = entryFile; self.previewFile = previewFile; self.workshopID = workshopID
        self.pixiv = pixiv
        self.isFavorite = isFavorite; self.collections = collections
        self.properties = properties; self.addedAt = addedAt
    }
}

public struct PlaybackSettings: Codable, Hashable {
    public var volume: Double = 0.5
    public var isMuted: Bool = true
    public var framesPerSecond: Int = 60
    public var renderScale: Double = 1
    public var scaling: String = "fit"
    public var playlistInterval: Double = 300
    public var microphoneEnabled: Bool = false
    public init() {}
}

public struct LibraryManifest: Codable {
    public var version: Int = 1
    public var items: [WallpaperItem] = []
    public var collections: [String] = []
    public var playlistIDs: [UUID] = []
    public var settings: PlaybackSettings = PlaybackSettings()
    public init() {}
}

public enum LibraryError: LocalizedError {
    case invalidPath(String), unsupported(String), invalidBackup, missingEntry, tooLarge, symbolicLink
    case backupRequiresRestore
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Unsafe imported asset path: \(path)"
        case .unsupported(let kind): return "Unsupported import: \(kind)"
        case .invalidBackup: return "The backup is invalid or uses an unsupported version."
        case .backupRequiresRestore:
            return NSLocalizedString("library.import.backupRequiresRestore", comment: "Use the confirmed Settings restore flow for library backups")
        case .missingEntry: return "The wallpaper entry file was not found."
        case .tooLarge: return "Import exceeds the 20 GB safety limit."
        case .symbolicLink: return "Symbolic links are not allowed in imported wallpaper folders."
        }
    }
}

/// Shared lexical and filesystem containment rules for imports, previews, backup and restore.
public enum AssetPath {
    public static func validate(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains(":"),
              !normalized.contains("\0"), !normalized.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw LibraryError.invalidPath(path)
        }
    }
    public static func resolve(_ path: String, inside root: URL) throws -> URL {
        try validate(path)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var componentURL = canonicalRoot
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            // Reading the link destination also detects dangling links, for which
            // ordinary resource lookup may report only a nonexistent target.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: componentURL.path)) != nil
                || (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw LibraryError.symbolicLink
            }
        }
        // Keep the canonical root when the leaf does not exist yet (for example,
        // virtual scene JSON or a new import destination). Resolving the full path
        // again from an aliased /var root can leave it different from /private/var.
        guard componentURL.path.hasPrefix(rootPrefix) else { throw LibraryError.invalidPath(path) }
        return componentURL
    }
}
