import Foundation

/// Converts the app's `[String: WallpaperProperty]` model into the flat JSON
/// object the scene engine's `PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON` and
/// `PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON` properties consume.
///
/// The engine reads a flat object of property name -> value. The UI model
/// carries metadata around the value, so a property record is encoded first and
/// only its `value` member is kept. `JSONValue` must therefore encode as the
/// natural JSON value it represents (string, number, bool, array, object or
/// null); the model's `Codable` synthesis is what supplies this.
///
/// This file deliberately imports only Foundation: it is compiled and tested on
/// a host without UIKit by `Renderer/Testing/ios_property_json/main.swift`.
enum SceneWallpaperPropertyJSON {
    /// The flat JSON text for `properties`, or nil when the model cannot be
    /// encoded as JSON. An empty property table is `{}`, which leaves every
    /// authored value in place.
    static func flatten<T: Encodable>(_ properties: [String: T]) -> String? {
        guard !properties.isEmpty else { return "{}" }
        guard let encoded = try? JSONEncoder().encode(properties) else { return nil }
        guard let flat = flattenEncoded(encoded) else { return nil }
        return String(data: flat, encoding: .utf8)
    }

    /// The testable half of `flatten`: encoded `[name: record]` JSON in, flat
    /// `{name: value}` JSON out. A record without a `value` member, or with a
    /// null value, contributes nothing (the engine treats a missing key as the
    /// authored value).
    static func flattenEncoded(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let records = object as? [String: Any] else { return nil }

        var flat: [String: Any] = [:]
        for (name, rawRecord) in records {
            guard let record = rawRecord as? [String: Any] else { continue }
            guard let value = record["value"], !(value is NSNull) else { continue }
            flat[name] = value
        }

        guard JSONSerialization.isValidJSONObject(flat) else { return nil }
        return try? JSONSerialization.data(withJSONObject: flat, options: [.sortedKeys])
    }
}
