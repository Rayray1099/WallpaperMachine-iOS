// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// An immutable request preset; omitting duration preserves the complete source.
struct PCConverterOptions: Sendable, Equatable {
    enum FrameRate: Int, CaseIterable, Sendable {
        case fps30 = 30
        case fps60 = 60
    }

    enum PackageLayout: String, CaseIterable, Sendable {
        case legacy
        case posterBoard27
    }

    let frameRate: FrameRate
    let packageLayout: PackageLayout

    init(frameRate: FrameRate = .fps30, packageLayout: PackageLayout = .legacy) {
        self.frameRate = frameRate
        self.packageLayout = packageLayout
    }

    func conversionQuery(title: String) -> [URLQueryItem] {
        let clean = title.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }
        let name = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedName = String(String.UnicodeScalarView(name.unicodeScalars.prefix(120)))
        var query = [URLQueryItem(name: "title", value: name.isEmpty ? "Wallpaper" : boundedName),
                     URLQueryItem(name: "fps", value: String(frameRate.rawValue)), URLQueryItem(name: "width", value: "1668"),
                     URLQueryItem(name: "height", value: "2420"), URLQueryItem(name: "quality", value: "2")]
        if packageLayout != .legacy {
            query.append(URLQueryItem(name: "package_layout", value: packageLayout.rawValue))
        }
        return query
    }
}
