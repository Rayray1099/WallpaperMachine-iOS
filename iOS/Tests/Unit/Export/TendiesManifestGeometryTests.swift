// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import WallpaperMachineIOS

final class TendiesManifestGeometryTests: XCTestCase {
    func testGeneratedLayerTransformsPreserveAllFrameCoordinates() throws {
        let sizes = [PixelSize(width: 1080, height: 1920), PixelSize(width: 1668, height: 2420),
                     PixelSize(width: 1920, height: 1080), PixelSize(width: 2420, height: 1668)]
        for size in sizes {
            for count in [1, 60, 301] {
                let descriptor = TendiesWallpaperDescriptor(screenClass: .iPadPro11M4,
                    displayName: "Synthetic Geometry", identifier: 12345, pixelSize: size,
                    frameCount: count, frameRate: 30)
                let files = try TendiesManifest.metadataFiles(for: descriptor)
                let caml = try XCTUnwrap(files.first { $0.path == "\(descriptor.backgroundFolder)/main.caml" })
                let document = CAMLGeometryReader()
                let parser = XMLParser(data: caml.data)
                parser.delegate = document
                XCTAssertTrue(parser.parse(), "\(size), \(count): \(String(describing: parser.parserError))")
                XCTAssertEqual(document.layers.map(\.name), ["CALayer", "CATransformLayer", "CALayer"])
                XCTAssertEqual(document.layers.count, 3)
                let width = Double(size.width), height = Double(size.height)
                let cornersAndCenter = [(0.0, 0.0), (width, 0), (0, height), (width, height), (width / 2, height / 2)]
                for point in cornersAndCenter {
                    var x = point.0, y = point.1
                    // Apply the leaf, wrapper and root transforms in that order.
                    for layer in document.layers.reversed() {
                        let bounds = try numbers(layer.attributes["bounds"], count: 4)
                        let anchor = try numbers(layer.attributes["anchorPoint"], count: 2)
                        let position = try numbers(layer.attributes["position"], count: 2)
                        XCTAssertEqual(bounds, [0, 0, width, height])
                        x += position[0] - bounds[0] - anchor[0] * bounds[2]
                        y += position[1] - bounds[1] - anchor[1] * bounds[3]
                    }
                    XCTAssertEqual(x, point.0, accuracy: 0.000001, "Horizontal shift: \(size), \(count)")
                    XCTAssertEqual(y, point.1, accuracy: 0.000001, "Vertical shift: \(size), \(count)")
                }
                let expected = (0..<count).map { "assets/\(descriptor.frameFileName(at: $0))" }
                XCTAssertEqual(document.animationImages, expected)
                XCTAssertEqual(document.initialImage, expected.first)
                XCTAssertEqual(document.animation?["keyPath"], "contents")
                XCTAssertEqual(document.animation?["calculationMode"], "linear") // Preserve existing format.
                let duration = try XCTUnwrap(document.animation?["duration"].flatMap(Double.init))
                XCTAssertEqual(duration, Double(count) / 30, accuracy: 0.000001)
                let index = try XCTUnwrap(files.first { $0.path == "\(descriptor.backgroundFolder)/index.xml" })
                let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: index.data, format: nil) as? [String: Any])
                XCTAssertEqual(plist["documentWidth"] as? Double, width)
                XCTAssertEqual(plist["documentHeight"] as? Double, height)
                XCTAssertEqual(try XCTUnwrap(plist["loopEnd"] as? Double), duration, accuracy: 0.000001)
                XCTAssertEqual(plist["scalesToFitInPlayer"] as? Bool, true)
                for (number, path) in expected.enumerated() {
                    XCTAssertEqual("\(descriptor.backgroundFolder)/\(path)", descriptor.frameMemberPath(at: number))
                }
            }
        }
    }

    func testOmittedWrapperPositionRegressionWouldMoveImageByHalfItsSize() {
        let width = 1080.0, height = 1920.0
        // Standard CA defaults are anchor=(.5,.5), position=(0,0).
        XCTAssertEqual(0 - 0.5 * width, -540)
        XCTAssertEqual(0 - 0.5 * height, -960)
    }

    private enum GeometryParseError: Error { case invalidNumbers }

    private func numbers(_ value: String?, count: Int) throws -> [Double] {
        let text = try XCTUnwrap(value, "All geometry must be explicit, not decoder defaults")
        let values = text.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(values.count, count)
        guard values.count == count else { throw GeometryParseError.invalidNumbers }
        return values
    }
}

private final class CAMLGeometryReader: NSObject, XMLParserDelegate {
    var layers: [(name: String, attributes: [String: String])] = []
    var animation: [String: String]?
    var animationImages: [String] = []
    var initialImage: String?
    private var inAnimation = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "CALayer" || elementName == "CATransformLayer" {
            layers.append((elementName, attributeDict))
        } else if elementName == "animation" {
            animation = attributeDict
            inAnimation = true
        } else if elementName == "CGImage", inAnimation, let path = attributeDict["src"] {
            animationImages.append(path)
        } else if elementName == "contents" {
            initialImage = attributeDict["src"]
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "animation" { inAnimation = false }
    }
}
