// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import WallpaperMachineIOS

/// The shared model contract from docs/ios/ARCHITECTURE.md: raw enum values,
/// natural JSON values, Codable round-trips and value semantics. Persistence is
/// covered separately against LibraryStore.
final class WallpaperModelContractTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(value))
    }

    func testWallpaperKindRawValuesAreStable() {
        XCTAssertEqual(WallpaperKind.scene.rawValue, "scene")
        XCTAssertEqual(WallpaperKind.video.rawValue, "video")
        XCTAssertEqual(WallpaperKind.web.rawValue, "web")
        XCTAssertEqual(WallpaperKind.image.rawValue, "image")
        XCTAssertEqual(WallpaperKind.allCases, [.scene, .video, .web, .image])
    }

    func testJSONValueRoundTripsEveryCase() throws {
        let values: [JSONValue] = [
            .string("text"), .number(12.5), .bool(true), .null,
            .array([.number(1), .string("two"), .bool(false)]),
            .object(["nested": .object(["deep": .null])]),
        ]
        for value in values {
            XCTAssertEqual(try roundTrip(value), value)
        }
    }

    func testJSONValueDecodesNaturalJSONTypes() throws {
        let json = Data(#"{"bool":true,"number":2,"string":"2","null":null,"array":[1,false]}"#.utf8)
        XCTAssertEqual(try decoder.decode(JSONValue.self, from: json), .object([
            "bool": .bool(true),
            "number": .number(2),
            "string": .string("2"),
            "null": .null,
            "array": .array([.number(1), .bool(false)]),
        ]))
    }

    func testWallpaperItemRoundTripsAllFields() throws {
        let item = WallpaperItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Aurora",
            kind: .web,
            relativePath: "Aurora-7f9a",
            entryFile: "index.html",
            previewFile: "preview.png",
            workshopID: "123456789",
            isFavorite: true,
            collections: ["Favourites", "Night"],
            properties: [
                "schemecolor": WallpaperProperty(
                    label: "Scheme colour", type: "color", value: .string("0.1 0.2 0.3"),
                    minimum: nil, maximum: nil, options: []),
                "speed": WallpaperProperty(
                    label: "Speed", type: "slider", value: .number(1.5),
                    minimum: 0.1, maximum: 4, options: []),
            ],
            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let decoded = try roundTrip(item)
        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.title, item.title)
        XCTAssertEqual(decoded.kind, item.kind)
        XCTAssertEqual(decoded.relativePath, item.relativePath)
        XCTAssertEqual(decoded.entryFile, item.entryFile)
        XCTAssertEqual(decoded.previewFile, item.previewFile)
        XCTAssertEqual(decoded.workshopID, item.workshopID)
        XCTAssertEqual(decoded.isFavorite, item.isFavorite)
        XCTAssertEqual(decoded.collections, item.collections)
        XCTAssertEqual(decoded.properties, item.properties)
        XCTAssertEqual(decoded.addedAt.timeIntervalSince1970,
                       item.addedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded, item)
    }

    func testWallpaperPropertyRoundTripsOptionalBoundsAndOptions() throws {
        let property = WallpaperProperty(
            label: "Quality", type: "combo", value: .string("high"),
            minimum: 1, maximum: 3, options: ["low", "medium", "high"])
        XCTAssertEqual(try roundTrip(property), property)
    }

    func testPlaybackSettingsRoundTripsCustomValues() throws {
        var settings = PlaybackSettings()
        settings.volume = 0.25
        settings.isMuted = false
        settings.framesPerSecond = 30
        settings.renderScale = 0.75
        settings.scaling = "fill"
        settings.playlistInterval = 42
        settings.microphoneEnabled = true
        XCTAssertEqual(try roundTrip(settings), settings)
    }

    func testLibraryManifestRoundTripsItemsCollectionsPlaylistsAndSettings() throws {
        var manifest = LibraryManifest()
        manifest.items = [IOSTestSupport.makeItem(relativePath: "One")]
        manifest.collections = ["Night"]
        manifest.playlistIDs = [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!]
        manifest.settings.volume = 0.9
        XCTAssertEqual(try roundTrip(manifest).items, manifest.items)
        XCTAssertEqual(try roundTrip(manifest).collections, manifest.collections)
        XCTAssertEqual(try roundTrip(manifest).playlistIDs, manifest.playlistIDs)
        XCTAssertEqual(try roundTrip(manifest).settings, manifest.settings)
    }

    func testValueSemanticsAndHashingFollowFields() {
        let item = IOSTestSupport.makeItem()
        var copy = item
        XCTAssertEqual(copy, item)
        XCTAssertEqual(copy.hashValue, item.hashValue)
        copy.isFavorite.toggle()
        XCTAssertNotEqual(copy, item)
    }
}
