// SPDX-License-Identifier: GPL-3.0-only
// Compiles the production Foundation-only options and connection; never opens a connection.
import Foundation

@main
struct PCConverterOptionsRegression {
    struct Failure: Error { let message: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func main() throws {
        let defaults = PCConverterOptions()
        try require(defaults.frameRate == .fps30, "Default must request 30 FPS")
        try require(defaults.packageLayout == .legacy, "Default layout must remain legacy")
        try require(defaults == PCConverterOptions(frameRate: .fps30), "Default preset equality")
        try require(PCConverterOptions.FrameRate.allCases.map(\.rawValue) == [30, 60], "Only explicit 30/60 presets")
        try require(Set(PCConverterOptions.FrameRate.allCases) == Set([.fps30, .fps60]), "Hashable frame rates support Picker tags")
        try require(PCConverterOptions.FrameRate(rawValue: 24) == nil, "No implicit FPS fallback")
        try require(PCConverterOptions.PackageLayout.allCases.map(\.rawValue) == ["legacy", "posterBoard27"], "Exact layout API values")
        try require(Set(PCConverterOptions.PackageLayout.allCases) == Set([.legacy, .posterBoard27]), "Hashable layouts support Picker tags")
        try require(PCConverterOptions.PackageLayout(rawValue: "modern") == nil, "No implicit layout fallback")
        let connection = try PCConverterConnection(link: "http://192.168.1.2:57351/#token=" + String(repeating: "a", count: 43))
        for rate in PCConverterOptions.FrameRate.allCases {
            for layout in PCConverterOptions.PackageLayout.allCases {
                let options = PCConverterOptions(frameRate: rate, packageLayout: layout)
                let query = options.conversionQuery(title: " A & 桌布\nname\u{0}\u{7f} ")
                let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                var expectedValues = ["title": "A & 桌布name", "fps": String(rate.rawValue),
                                      "width": "1668", "height": "2420", "quality": "2"]
                if layout == .posterBoard27 { expectedValues["package_layout"] = "posterBoard27" }
                try require(values == expectedValues, "Exact request fields for each rate and layout")
                try require(query.count == expectedValues.count && values["duration"] == nil, "Full source: no trim or extra options")
                try require(options.conversionQuery(title: " \n\u{7f} ").first?.value == "Wallpaper", "Empty sanitized title fallback")
                let title = String(repeating: "👩‍💻", count: 120)
                let bounded = options.conversionQuery(title: title).first?.value
                let expected = String(String.UnicodeScalarView(title.unicodeScalars.prefix(120)))
                try require(bounded == expected && bounded?.unicodeScalars.count == 120, "120-scalar title bound")
                let contentTitle = "A+B & C?=#% 桌布"
                let url = connection.endpoint(path: "/api/jobs", query: options.conversionQuery(title: contentTitle))
                try require(url.absoluteString.contains("title=A%2BB%20%26%20C"), "Form-safe title escaping")
                let roundTrip = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try require(roundTrip.first?.value == contentTitle, "Content title round trips without query injection")
                try require(roundTrip.count == expectedValues.count && url.fragment == nil, "Escaped title cannot add fields or fragments")
                try require(roundTrip.first(where: { $0.name == "package_layout" })?.value ==
                            (layout == .legacy ? nil : "posterBoard27"), "URL carries only explicitly selected modern layout")
            }
        }
        try require(defaults.conversionQuery(title: "Default") == PCConverterOptions(frameRate: .fps30, packageLayout: .legacy).conversionQuery(title: "Default"),
                    "Default query is exactly the legacy 30 FPS preset")
        try require(defaults != PCConverterOptions(frameRate: .fps60), "Preset equality distinguishes frame rate")
        try require(defaults != PCConverterOptions(packageLayout: .posterBoard27), "Preset equality distinguishes layout")
        print("PASS: PCConverterOptions default30/legacy, both frame rates and layouts, fixed1668x2420/quality2, full source/no duration, sanitized/bounded/escaped content title")
    }
}
