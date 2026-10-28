//
//  KeyedArchiveBuilder.swift
//  WallpaperMachineIOS
//
//  Writes the small NSKeyedArchiver-compatible property lists PosterBoard reads
//  (providerInfo.plist and the optional otherMetadata display-name record).
//
//  The archive shape follows the publicly documented NSKeyedArchiver object graph:
//  `$archiver`, `$objects`, `$top`, `$version`, class records and UID references.
//  Building it explicitly keeps the exporter free of private classes at compile
//  time and lets the metadata be unit tested on any platform. No Apple template
//  binary is redistributed; every archive is generated from user data.
//

import Foundation

public struct KeyedArchiveBuilder {
    private var objects: [Any] = ["$null"]

    public init() {}

    public var nullReference: [String: Int] { ["CF$UID": 0] }

    @discardableResult
    public mutating func add(_ object: Any) -> [String: Int] {
        objects.append(object)
        return ["CF$UID": objects.count - 1]
    }

    @discardableResult
    public mutating func addClass(_ names: [String]) -> [String: Int] {
        guard let primary = names.first else { return nullReference }
        return add(["$classname": primary, "$classes": names])
    }

    public func data(root: [String: Int],
                     format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        let plist: [String: Any] = [
            "$version": 100_000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": root],
            "$objects": objects
        ]
        if format == .binary {
            // A CF$UID dictionary written directly to binary remains a dictionary.
            // Parsing its XML representation converts it to a plist UID object;
            // serializing that object as binary preserves the keyed-archive reference.
            let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let parsed = try PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
            return try PropertyListSerialization.data(fromPropertyList: parsed, format: .binary, options: 0)
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
    }
}

public enum TendiesArchives {
    /// `providerInfo.plist`: NSMutableDictionary holding `kConfigurationLastUseDateKey`
    /// -> NSDate. Matches the key/value recorded by the documented `.tendies`
    /// templates (the value is only a cache hint).
    public static func providerInfo(date: Date = Date()) throws -> Data {
        var archive = KeyedArchiveBuilder()
        let dateClass = archive.addClass(["NSDate", "NSObject"])
        let dictionaryClass = archive.addClass(["NSMutableDictionary", "NSDictionary", "NSObject"])
        let key = archive.add("kConfigurationLastUseDateKey")
        let dateObject = archive.add([
            "$class": dateClass,
            "NS.time": date.timeIntervalSinceReferenceDate
        ])
        let root = archive.add([
            "$class": dictionaryClass,
            "NS.keys": [key],
            "NS.objects": [dateObject]
        ])
        return try archive.data(root: root, format: .binary)
    }

    /// `com.apple.posterkit.provider.contents.otherMetadata.plist`: a
    /// PRPosterMetadata record whose display name is the user's wallpaper name.
    /// This is generated from the user's own title, never copied from a template.
    public static func otherMetadata(displayName: String) throws -> Data {
        var archive = KeyedArchiveBuilder()
        let metadataClass = archive.addClass(["PRPosterMetadata", "NSObject"])
        let nameKey = archive.add(displayName)
        let root = archive.add([
            "$class": metadataClass,
            "displayNameLocalizationKey": nameKey
        ])
        return try archive.data(root: root, format: .binary)
    }

    /// `com.apple.posterkit.provider.contents.userInfo`: the mapping from a
    /// descriptor to the `.wallpaper` bundle it presents.
    public static func userInfo(wallpaperFileName: String, identifier: Int) throws -> Data {
        let dictionary: [String: Any] = [
            "posterEnvironmentOverrides": Data("{}".utf8),
            "wallpaperRepresentingFileName": wallpaperFileName,
            "wallpaperRepresentingIdentifier": String(identifier)
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    /// `com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist`:
    /// the gallery suggestion that associates the Collections provider, numeric
    /// descriptor identifier and display name. Its effect on PosterBoard discovery
    /// and playback remains subject to device validation.
    public static func suggestionMetadata(displayName: String,
                                          identifier: Int,
                                          galleryIdentifier: String,
                                          date: Date = Date()) throws -> Data {
        var archive = KeyedArchiveBuilder()
        let colorClass = archive.addClass(["BSColor", "NSObject"])
        let color = archive.add([
            "$class": colorClass,
            "a": 0.0,
            "b": 0.0,
            "g": 0.0,
            "r": 0.0
        ] as [String: Any])
        let displayNameLocalizationKey = archive.add("Collections")
        let localizedDisplayName = archive.add(displayName)
        let galleryClass = archive.addClass(["ATXFaceGalleryItem", "NSObject"])
        let extensionBundleIdentifier = archive.add("com.apple.WallpaperKit.CollectionsPoster")
        let titleFontName = archive.add("")
        let descriptorIdentifier = archive.add("\(identifier).DYNAMIC")
        let score = archive.add(20.0)
        let galleryUUID = archive.add(galleryIdentifier)
        let gallery = archive.add([
            "$class": galleryClass,
            "blankTemplate": false,
            "complications": archive.nullReference,
            "descriptiveTextLocalizationKey": archive.nullReference,
            "descriptorIdentifier": descriptorIdentifier,
            "displayNameLocalizationKey": displayNameLocalizationKey,
            "extensionBundleIdentifier": extensionBundleIdentifier,
            "identifier": galleryUUID,
            "layoutType": 0,
            "localizedDisplayName": localizedDisplayName,
            "localizedSubtitle": archive.nullReference,
            "modeSemanticType": archive.nullReference,
            "modeUUID": archive.nullReference,
            "score": score,
            "shouldShowAsShuffleStack": false,
            "source": 2,
            "spokenNameLocalizationKey": archive.nullReference,
            "subtitleComplication": archive.nullReference,
            "titleColor": color,
            "titleFontName": titleFontName
        ] as [String: Any])
        let dateClass = archive.addClass(["NSDate", "NSObject"])
        let dateObject = archive.add([
            "$class": dateClass,
            "NS.time": date.timeIntervalSinceReferenceDate
        ])
        let dictionaryClass = archive.addClass(["NSDictionary", "NSObject"])
        let emptyComplications = archive.add([
            "$class": dictionaryClass,
            "NS.keys": [],
            "NS.objects": []
        ] as [String: Any])
        let suggestionClass = archive.addClass(["PRPosterSuggestionMetadata", "NSObject"])
        let root = archive.add([
            "$class": suggestionClass,
            "lastModifiedDate": dateObject,
            "suggestedComplicationsByIdentifier": emptyComplications,
            "suggestedGalleryItem": gallery
        ])
        return try archive.data(root: root, format: .binary)
    }
}
