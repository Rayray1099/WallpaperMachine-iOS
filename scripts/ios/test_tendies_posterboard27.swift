// SPDX-License-Identifier: GPL-3.0-only
// Portable production-manifest fixture runner. No Apple SDK, device or private decoder.
import Foundation

#if canImport(Darwin)
private enum WMDecodedValue: Equatable {
    case string(String)
    case object(String)
    case boolean(Bool)
    case integer(Int)
    case number(Double)
}

private struct WMDecodedEvent {
    let className: String
    let values: [String: WMDecodedValue]
}

private enum WMArchiveProbe {
    static var events: [WMDecodedEvent] = []

    static func className(of value: Any?) -> String {
        guard let value else { return "nil" }
        if value is WMPosterSuggestionMetadataProxy { return "PRPosterSuggestionMetadata" }
        if value is WMFaceGalleryItemProxy { return "ATXFaceGalleryItem" }
        if value is WMColorProxy { return "BSColor" }
        if value is NSDictionary { return "NSDictionary" }
        if value is NSDate { return "NSDate" }
        return String(describing: type(of: value))
    }
}

private class WMKeyedArchiveProxy: NSObject, NSCoding {
    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}

private final class WMPosterSuggestionMetadataProxy: WMKeyedArchiveProxy {
    required init?(coder: NSCoder) {
        let gallery = coder.decodeObject(forKey: "suggestedGalleryItem")
        let complications = coder.decodeObject(forKey: "suggestedComplicationsByIdentifier")
        let date = coder.decodeObject(forKey: "lastModifiedDate")
        super.init(coder: coder)
        WMArchiveProbe.events.append(WMDecodedEvent(className: "PRPosterSuggestionMetadata", values: [
            "suggestedGalleryItem": .object(WMArchiveProbe.className(of: gallery)),
            "suggestedComplicationsByIdentifier": .object(WMArchiveProbe.className(of: complications)),
            "lastModifiedDate": .object(WMArchiveProbe.className(of: date))
        ]))
    }
}

private final class WMFaceGalleryItemProxy: WMKeyedArchiveProxy {
    required init?(coder: NSCoder) {
        let descriptorIdentifier = coder.decodeObject(forKey: "descriptorIdentifier") as? String
        let displayNameLocalizationKey = coder.decodeObject(forKey: "displayNameLocalizationKey") as? String
        let localizedDisplayName = coder.decodeObject(forKey: "localizedDisplayName") as? String
        let extensionBundleIdentifier = coder.decodeObject(forKey: "extensionBundleIdentifier") as? String
        let identifier = coder.decodeObject(forKey: "identifier") as? String
        let titleColor = coder.decodeObject(forKey: "titleColor")
        let blankTemplate = coder.decodeBool(forKey: "blankTemplate")
        let shouldShowAsShuffleStack = coder.decodeBool(forKey: "shouldShowAsShuffleStack")
        let layoutType = coder.decodeInteger(forKey: "layoutType")
        let source = coder.decodeInteger(forKey: "source")
        let score = (coder.decodeObject(forKey: "score") as? NSNumber)?.doubleValue
        super.init(coder: coder)
        var values: [String: WMDecodedValue] = [
            "blankTemplate": .boolean(blankTemplate),
            "shouldShowAsShuffleStack": .boolean(shouldShowAsShuffleStack),
            "layoutType": .integer(layoutType),
            "source": .integer(source),
            "titleColor": .object(WMArchiveProbe.className(of: titleColor))
        ]
        if let descriptorIdentifier { values["descriptorIdentifier"] = .string(descriptorIdentifier) }
        if let displayNameLocalizationKey { values["displayNameLocalizationKey"] = .string(displayNameLocalizationKey) }
        if let localizedDisplayName { values["localizedDisplayName"] = .string(localizedDisplayName) }
        if let extensionBundleIdentifier { values["extensionBundleIdentifier"] = .string(extensionBundleIdentifier) }
        if let identifier { values["identifier"] = .string(identifier) }
        if let score { values["score"] = .number(score) }
        WMArchiveProbe.events.append(WMDecodedEvent(className: "ATXFaceGalleryItem", values: values))
    }
}

private final class WMColorProxy: WMKeyedArchiveProxy {
    required init?(coder: NSCoder) {
        let values: [String: WMDecodedValue] = [
            "r": .number(coder.decodeDouble(forKey: "r")),
            "g": .number(coder.decodeDouble(forKey: "g")),
            "b": .number(coder.decodeDouble(forKey: "b")),
            "a": .number(coder.decodeDouble(forKey: "a"))
        ]
        super.init(coder: coder)
        WMArchiveProbe.events.append(WMDecodedEvent(className: "BSColor", values: values))
    }
}
#endif

@main
struct TendiesPosterBoard27Regression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func verifyNativeUnarchiver(_ data: Data, identifier: Int,
                                       displayName: String) throws {
        #if canImport(Darwin)
        WMArchiveProbe.events.removeAll()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(WMPosterSuggestionMetadataProxy.self,
                            forClassName: "PRPosterSuggestionMetadata")
        unarchiver.setClass(WMFaceGalleryItemProxy.self,
                            forClassName: "ATXFaceGalleryItem")
        unarchiver.setClass(WMColorProxy.self, forClassName: "BSColor")
        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        try require(root is WMPosterSuggestionMetadataProxy,
                    "NSKeyedUnarchiver did not decode the suggestion root")
        let rootEvent = try requireValue(
            WMArchiveProbe.events.first { $0.className == "PRPosterSuggestionMetadata" },
            "NSKeyedUnarchiver did not decode the suggestion root graph")
        let gallery = try requireValue(
            WMArchiveProbe.events.first { event in
                guard event.className == "ATXFaceGalleryItem",
                      case .string(let value) = event.values["descriptorIdentifier"] else { return false }
                return value == "\(identifier).DYNAMIC"
            },
            "NSKeyedUnarchiver did not decode the gallery object")
        try require(rootEvent.values["suggestedGalleryItem"] == .object("ATXFaceGalleryItem"),
                    "Root did not traverse suggestedGalleryItem")
        try require(rootEvent.values["suggestedComplicationsByIdentifier"] == .object("NSDictionary"),
                    "Root did not decode suggested complications")
        try require(rootEvent.values["lastModifiedDate"] == .object("NSDate"),
                    "Root did not decode lastModifiedDate")
        try require(gallery.values["displayNameLocalizationKey"] == .string("Collections"),
                    "Native decode changed the stock localization key")
        try require(gallery.values["localizedDisplayName"] == .string(displayName),
                    "Native decode lost the localized display name")
        try require(gallery.values["extensionBundleIdentifier"] == .string("com.apple.WallpaperKit.CollectionsPoster"),
                    "Native decode lost the Collections provider")
        try require(gallery.values["titleColor"] == .object("BSColor"),
                    "Native decode lost the typed title color object")
        try require(gallery.values["blankTemplate"] == .boolean(false),
                    "Native decode changed blankTemplate type/value")
        try require(gallery.values["layoutType"] == .integer(0),
                    "Native decode changed layoutType type/value")
        #endif
    }

    static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }

    static func verifyBinaryKeyedArchive(_ data: Data, label: String) throws {
        try require(data.starts(with: Data("bplist00".utf8)),
                    "\(label) must use binary plist encoding")
        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let archive = try requireValue(decoded as? [String: Any], "\(label) root is not a dictionary")
        try require(archive["$archiver"] as? String == "NSKeyedArchiver" &&
                    archive["$objects"] is [Any] && archive["$top"] is [String: Any],
                    "\(label) is not an NSKeyedArchiver graph")
        func containsUIDDictionary(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if dictionary.count == 1 && dictionary["CF$UID"] != nil { return true }
                return dictionary.values.contains(where: containsUIDDictionary)
            }
            if let array = value as? [Any] { return array.contains(where: containsUIDDictionary) }
            return false
        }
        try require(!containsUIDDictionary(decoded),
                    "\(label) contains a CF$UID dictionary instead of a binary UID")
    }

    static func descriptor() -> TendiesWallpaperDescriptor {
        TendiesWallpaperDescriptor(screenClass: .iPadPro11M4,
            displayName: "Synthetic Geometry", identifier: 12345,
            pixelSize: PixelSize(width: 1668, height: 2420), frameCount: 60, frameRate: 30,
            descriptorUUID: UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!,
            suggestionGalleryUUID: UUID(uuidString: "87654321-4321-8765-CBA9-CBA987654321")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 123456789))
    }

    static func write(_ descriptor: TendiesWallpaperDescriptor, at root: URL,
                      includeDisplayName: Bool = true) throws {
        let files = try TendiesManifest.metadataFiles(for: descriptor,
            includeDisplayNameMetadata: includeDisplayName)
        try require(Set(files.map(\.path)).count == files.count, "Duplicate metadata members")
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
    }

    static func archive(_ descriptor: TendiesWallpaperDescriptor, at url: URL) throws {
        let writer = try ZipArchiveWriter(outputURL: url)
        for file in try TendiesManifest.metadataFiles(for: descriptor) {
            try writer.addFile(path: file.path, data: file.data, modified: descriptor.createdAt)
        }
        // Deliberately opaque bytes: verify transport, not a JPEG codec or Apple renderer.
        for index in 0..<descriptor.frameCount {
            try writer.addFile(path: descriptor.frameMemberPath(at: index),
                data: Data("opaque-original-frame-\(index)".utf8), modified: descriptor.createdAt)
        }
        _ = try writer.finish()
    }

    static func validation() throws {
        try require(TendiesPackageLayout.allCases == [.legacy, .posterBoard27], "Explicit opt-in layouts")
        for layout in TendiesPackageLayout.allCases {
            let data = try JSONEncoder().encode(layout)
            let decoded = try JSONDecoder().decode(TendiesPackageLayout.self, from: data)
            try require(decoded == layout, "Package layout Codable round trip")
            var value = descriptor()
            value.packageLayout = layout
            let reserved = layout == .legacy ? 12 : 18
            for includeDisplayName in [false, true] {
                let files = try TendiesManifest.metadataFiles(for: value,
                    includeDisplayNameMetadata: includeDisplayName)
                try require(files.count == reserved - (includeDisplayName ? 0 : 1),
                    "Actual metadata entry count for \(layout), display metadata \(includeDisplayName)")
                if layout == .posterBoard27 {
                    for suffix in ["providerInfo.plist",
                                   "renderingConfiguration.plist",
                                   "configurableOptions.plist"] {
                        let matches = files.filter { $0.path.hasSuffix(suffix) }
                        try require(matches.count == 1, "Missing modern keyed archive \(suffix)")
                        try verifyBinaryKeyedArchive(matches[0].data, label: suffix)
                    }
                    if includeDisplayName {
                        let matches = files.filter { $0.path.hasSuffix("otherMetadata.plist") }
                        try require(matches.count == 1, "Missing modern otherMetadata archive")
                        try verifyBinaryKeyedArchive(matches[0].data, label: "otherMetadata.plist")
                    }
                    let suggestion = files.first { $0.path.hasSuffix("suggestionMetadata.plist") }
                    try require(suggestion != nil, "PosterBoard 27 metadata must include suggestionMetadata")
                    try require(suggestion!.data.starts(with: Data("bplist00".utf8)),
                        "Suggestion metadata must use the binary keyed archive format")
                    let decoded = try PropertyListSerialization.propertyList(
                        from: suggestion!.data, options: [], format: nil)
                    let text = String(describing: decoded)
                    try require(text.contains("PRPosterSuggestionMetadata"),
                        "Suggestion metadata class missing")
                    try require(text.contains("ATXFaceGalleryItem"),
                        "Suggestion gallery class missing")
                    try require(text.contains("12345.DYNAMIC"),
                        "Suggestion descriptor identifier missing")
                    try require(text.contains("Collections"),
                        "Suggestion localization key missing")
                    try require(text.contains("com.apple.WallpaperKit.CollectionsPoster"),
                        "Suggestion provider identifier missing")
                    try require(text.contains("Synthetic Geometry"),
                        "Suggestion display name missing")
                    try verifyNativeUnarchiver(suggestion!.data, identifier: 12345,
                                               displayName: "Synthetic Geometry")
                }
            }
            value.frameCount = ZipArchiveWriter.maximumEntryCount - reserved
            let validated = try value.validated()
            try require(validated.frameCount == value.frameCount, "Highest safe ZIP frame count unchanged")
            for includeDisplayName in [false, true] {
                let files = try TendiesManifest.metadataFiles(for: value,
                    includeDisplayNameMetadata: includeDisplayName)
                try require(files.count + value.frameCount <= ZipArchiveWriter.maximumEntryCount,
                    "Manifest and frames exceed ZIP entry budget")
            }
            value.frameCount += 1
            do {
                _ = try value.validated()
                throw Failure(description: "ZIP metadata reservation was ignored")
            } catch let error as TendiesManifestError {
                try require(error == .frameCountExceedsArchiveCapacity(value.frameCount,
                    ZipArchiveWriter.maximumEntryCount), "Explicit ZIP capacity error")
            }
            do {
                _ = try TendiesManifest.metadataFiles(for: value)
                throw Failure(description: "Metadata generation bypassed ZIP validation")
            } catch let error as TendiesManifestError {
                try require(error == .frameCountExceedsArchiveCapacity(value.frameCount,
                    ZipArchiveWriter.maximumEntryCount), "Metadata ZIP capacity error")
            }
        }
        var unsupported = descriptor()
        unsupported.packageLayout = .posterBoard27
        unsupported.animationEncoding = .imageSequence
        do {
            _ = try unsupported.validated()
            throw Failure(description: "Unsupported ImageSequence accepted")
        } catch let error as TendiesManifestError {
            try require(error == .unsupportedAnimationEncoding(.imageSequence, .posterBoard27),
                "Explicit unsupported layout/encoding error")
        }
        do {
            _ = try TendiesManifest.metadataFiles(for: unsupported)
            throw Failure(description: "Unsupported ImageSequence document emitted")
        } catch let error as TendiesManifestError {
            try require(error == .unsupportedAnimationEncoding(.imageSequence, .posterBoard27),
                "Metadata must reject unsupported layout/encoding")
        }
    }

    static func main() throws {
        try require(CommandLine.arguments.count == 2, "Pass an isolated fixture output directory")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let legacy = descriptor()
        try require(legacy.packageLayout == .legacy, "Layout must remain opt-in")
        try require(legacy.animationEncoding == .contentsKeyframe, "Contents-keyframe default unchanged")
        var explicitLegacy = legacy
        explicitLegacy.packageLayout = .legacy
        try require(legacy == explicitLegacy, "Default and explicit legacy descriptors differ")
        try validation()
        var fixtures: [(String, TendiesWallpaperDescriptor)] = [("legacy", legacy), ("explicit-legacy", explicitLegacy)]
        var modern = legacy
        modern.packageLayout = .posterBoard27
        try require(modern != legacy, "Hashable/equality must distinguish layout")
        try require(Set([legacy, modern]).count == 2, "Hashable layouts collapsed")
        fixtures.append(("modern", modern))
        var variant = modern
        variant.descriptorUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        fixtures.append(("uuid", variant))
        variant = modern
        variant.identifier = 67890
        fixtures.append(("identifier", variant))
        variant = modern
        variant.displayName = "Another Title"
        variant.family = "Must Not Leak Into Modern Family"
        fixtures.append(("title", variant))
        for (name, size) in [("custom-wide", PixelSize(width: 1920, height: 1080)),
                             ("custom-small", PixelSize(width: 320, height: 480)),
                             ("custom-portrait", PixelSize(width: 1080, height: 1920)),
                             ("custom-square", PixelSize(width: 2048, height: 2048))] {
            variant = modern
            variant.pixelSize = size
            fixtures.append((name, variant))
        }
        variant = modern
        variant.screenClass = TendiesScreenClass(widthPoints: 1210, heightPoints: 834, scale: 2, idiom: .pad)
        fixtures.append(("logical-landscape", variant))
        variant = modern
        variant.screenClass.scale = 3
        fixtures.append(("scale3", variant))
        for (name, count, rate) in [("one", 1, 30.0), ("timing60", 301, 60.0),
                                     ("fractional", 67, 29.97), ("full-length", 988, 30.0)] {
            variant = modern
            variant.frameCount = count
            variant.frameRate = rate
            fixtures.append((name, variant))
        }
        variant = legacy
        variant.animationEncoding = .imageSequence
        fixtures.append(("legacy-sequence", variant))
        var summaries: [[String: Any]] = []
        for (name, value) in fixtures {
            try write(value, at: root.appendingPathComponent(name))
            summaries.append(["name": name, "pixelWidth": value.pixelSize.width,
                "pixelHeight": value.pixelSize.height, "pointWidth": value.screenClass.widthPoints,
                "pointHeight": value.screenClass.heightPoints, "scale": value.screenClass.scale,
                "frameCount": value.frameCount, "frameRate": value.frameRate,
                "identifier": value.identifier, "uuid": value.descriptorUUID.uuidString.uppercased(),
                "galleryUUID": value.suggestionGalleryUUID.uuidString.uppercased(),
                "screenClass": value.screenClass.name, "displayName": value.sanitizedName,
                "layout": value.packageLayout.rawValue, "wallpaperFolder": value.wallpaperFolder,
                "backgroundFolder": value.backgroundFolder, "floatingFolder": value.floatingFolder,
                "foregroundFolder": value.foregroundFolder])
        }
        for (name, value) in [("legacy", legacy), ("modern", modern)] {
            try write(value, at: root.appendingPathComponent(name + "-no-display"), includeDisplayName: false)
            try archive(value, at: root.appendingPathComponent(name + ".tendies"))
        }
        try JSONSerialization.data(withJSONObject: summaries, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("fixtures.json"))
        print("PASS: TendiesPosterBoard27 legacy/default, semantic fixtures, encodings, dynamic ZIP budgets")
    }
}
