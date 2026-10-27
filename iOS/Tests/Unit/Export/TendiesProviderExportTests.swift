// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import XCTest
import ZIPFoundation
@testable import WallpaperMachineIOS

/// Exercises real pixel-buffer/compositor/JPEG/writer code with synthetic frames.
/// Uses a temporary directory, never the service's user Documents/Exports path.
@MainActor
final class TendiesProviderExportTests: XCTestCase {
    func testInvalidFirstIndexesRejectAndCannotBeFinished() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for index in [-1, 1, 3] {
            let (writer, image) = try makeSequenceWriter(in: temporary)
            defer { writer.cancel() }
            let expected = TendiesExportError.frameIndexOutOfRange(index, 3)
            XCTAssertThrowsError(try writer.append(image, frameIndex: index)) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertThrowsError(try writer.append(image, frameIndex: 0)) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertThrowsError(try writer.finish()) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertEqual(writer.writtenFrames, 0)
            XCTAssertEqual(writer.writtenFrameBytes, 0)
            writer.cancel()
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.outputURL.path))
        }
    }

    func testSkippedDuplicateAndOverrunRejectWithoutChangingAccountingOrCompleting() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for (accepted, rejected) in [([0], 2), ([0], 0), ([0, 1], 0), ([0, 1], 1), ([0, 1, 2], 3)] {
            let (writer, image) = try makeSequenceWriter(in: temporary)
            defer { writer.cancel() }
            for index in accepted { try writer.append(image, frameIndex: index) }
            let bytesBeforeRejection = writer.writtenFrameBytes
            XCTAssertGreaterThan(bytesBeforeRejection, 0)
            let expected = TendiesExportError.frameIndexOutOfRange(rejected, 3)
            XCTAssertThrowsError(try writer.append(image, frameIndex: rejected)) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            if accepted.count < 3 {
                XCTAssertThrowsError(try writer.append(image, frameIndex: accepted.count)) {
                    XCTAssertEqual($0 as? TendiesExportError, expected)
                }
            }
            XCTAssertThrowsError(try writer.finish()) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertEqual(writer.writtenFrames, accepted.count)
            XCTAssertEqual(writer.writtenFrameBytes, bytesBeforeRejection)
            writer.cancel()
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.outputURL.path))
        }
    }

    func testMissingFramesCannotFinishAndCancellationRemovesPartialArchive() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for count in 0..<3 {
            let (writer, image) = try makeSequenceWriter(in: temporary)
            defer { writer.cancel() }
            for index in 0..<count { try writer.append(image, frameIndex: index) }
            let bytesBeforeFinish = writer.writtenFrameBytes
            let expected = TendiesExportError.incompleteFrames(count, 3)
            XCTAssertThrowsError(try writer.finish()) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertThrowsError(try writer.append(image, frameIndex: count)) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertThrowsError(try writer.finish()) {
                XCTAssertEqual($0 as? TendiesExportError, expected)
            }
            XCTAssertEqual(writer.writtenFrames, count)
            XCTAssertEqual(writer.writtenFrameBytes, bytesBeforeFinish)
            writer.cancel()
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.outputURL.path))
        }
    }

    func testExactSequenceFinishesOnceWithCompleteFrameAccounting() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (writer, image) = try makeSequenceWriter(in: temporary)
        defer { writer.cancel() }
        for index in 0..<3 { try writer.append(image, frameIndex: index) }

        let url = try writer.finish()
        XCTAssertEqual(url, writer.outputURL)
        XCTAssertThrowsError(try writer.finish())
        let archive = try Archive(data: Data(contentsOf: url), accessMode: .read)
        var bytes: Int64 = 0
        for index in 0..<3 {
            let entry = try XCTUnwrap(archive[writer.descriptor.frameMemberPath(at: index)])
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            bytes += Int64(data.count)
        }
        XCTAssertEqual(archive.filter { $0.path.hasSuffix(".jpg") }.count, 3)
        XCTAssertEqual(writer.writtenFrames, 3)
        XCTAssertEqual(writer.writtenFrameBytes, bytes)
    }

    private func makeSequenceWriter(in directory: URL) throws -> (TendiesExportWriter, CIImage) {
        let size = PixelSize(width: 64, height: 96)
        let descriptor = TendiesWallpaperDescriptor(screenClass: .iPadPro11M4,
            displayName: "Sequence Regression", identifier: 12345,
            pixelSize: size, frameCount: 3, frameRate: 30)
        let compositor = FrameCompositor(plan: ExportRenderPlan(pixelSize: size, aspectMode: .stretch))
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let writer = try TendiesExportWriter(descriptor: descriptor,
            outputURL: directory.appendingPathComponent("\(UUID().uuidString).tendies"),
            compositor: compositor, jpegQuality: 0.9, includesDisplayNameMetadata: true)
        return (writer, try compositor.render(source: image))
    }

    func testSyntheticProviderWritesEveryFrameWithCorrectDimensionsAndReferences() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Small JPEGs keep a 301-frame native regression bounded; the manifest
        // geometry suite separately covers full device/1080p coordinates.
        for size in [PixelSize(width: 64, height: 96), PixelSize(width: 96, height: 64)] {
            for count in [1, 60, 301] {
                let provider = try SyntheticTendiesProvider()
                try await provider.prepareForExport()
                let descriptor = TendiesWallpaperDescriptor(screenClass: .iPadPro11M4,
                    displayName: "Synthetic Four Corners", identifier: 12345,
                    pixelSize: size, frameCount: count, frameRate: 30)
                let compositor = FrameCompositor(plan: ExportRenderPlan(pixelSize: size, aspectMode: .stretch))
                let url = temporary.appendingPathComponent("\(size)-\(count).tendies")
                let writer = try TendiesExportWriter(descriptor: descriptor, outputURL: url,
                    compositor: compositor, jpegQuality: 0.9, includesDisplayNameMetadata: true)
                do {
                    for index in 0..<count {
                        let frame = try await provider.frame(at: CMTime(value: Int64(index), timescale: 30))
                        let buffer = try XCTUnwrap(frame)
                        try writer.append(compositor.render(source: buffer), frameIndex: index)
                    }
                    _ = try writer.finish()
                } catch {
                    writer.cancel()
                    await provider.finishExport()
                    throw error
                }
                await provider.finishExport()
                XCTAssertEqual(provider.requestedTimes.count, count)
                XCTAssertEqual(writer.writtenFrames, count)
                let archive = try Archive(data: Data(contentsOf: url), accessMode: .read)
                var files: [String: Data] = [:]
                for entry in archive {
                    var content = Data()
                    _ = try archive.extract(entry) { content.append($0) }
                    XCTAssertNil(files.updateValue(content, forKey: entry.path), "Duplicate ZIP member")
                }
                XCTAssertEqual(files.count, count + 12)
                let caml = try XCTUnwrap(files["\(descriptor.backgroundFolder)/main.caml"])
                let text = try XCTUnwrap(String(data: caml, encoding: .utf8))
                for index in 0..<count {
                    let path = descriptor.frameMemberPath(at: index)
                    let jpeg = try XCTUnwrap(files[path])
                    let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
                    XCTAssertEqual(image.width, size.width)
                    XCTAssertEqual(image.height, size.height)
                    XCTAssertTrue(text.contains("<CGImage src=\"assets/\(descriptor.frameFileName(at: index))\"/>"))
                }
                XCTAssertEqual(files.keys.filter { $0.hasSuffix(".jpg") }.count, count)
                // A changing real source must not silently become one repeated preview.
                if count > 1 {
                    XCTAssertNotEqual(files[descriptor.frameMemberPath(at: 0)], files[descriptor.frameMemberPath(at: count - 1)])
                }
            }
        }
    }

    func testMaximumQualityAppendLeavesCompleteFramesAcrossAutoreleaseBoundaries() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = PixelSize(width: 64, height: 96)
        let count = 61
        let descriptor = TendiesWallpaperDescriptor(screenClass: .iPadPro11M4,
            displayName: "Maximum Quality Pool Regression", identifier: 12345,
            pixelSize: size, frameCount: count, frameRate: 60)
        let compositor = FrameCompositor(plan: ExportRenderPlan(pixelSize: size, aspectMode: .stretch))
        let url = temporary.appendingPathComponent("MaximumQuality.tendies")
        let writer = try TendiesExportWriter(descriptor: descriptor, outputURL: url,
            compositor: compositor, jpegQuality: 1, includesDisplayNameMetadata: true)
        do {
            for index in 0..<count {
                try autoreleasepool {
                    let color = index.isMultiple(of: 2) ? CIColor(red: 1, green: 0, blue: 0)
                        : CIColor(red: 0, green: 0, blue: 1)
                    let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                    try writer.append(compositor.render(source: image), frameIndex: index)
                }
                XCTAssertEqual(writer.writtenFrames, index + 1)
            }
            _ = try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        let archive = try Archive(data: Data(contentsOf: url), accessMode: .read)
        var jpegByteCount: Int64 = 0
        for index in 0..<count {
            let entry = try XCTUnwrap(archive[descriptor.frameMemberPath(at: index)])
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            jpegByteCount += Int64(data.count)
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(image.width, size.width)
            XCTAssertEqual(image.height, size.height)
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(Double(pixel[0]), index.isMultiple(of: 2) ? 255.0 : 0.0, accuracy: 5)
            XCTAssertEqual(Double(pixel[1]), 0, accuracy: 5)
            XCTAssertEqual(Double(pixel[2]), index.isMultiple(of: 2) ? 0.0 : 255.0, accuracy: 5)
        }
        XCTAssertEqual(writer.writtenFrames, count)
        XCTAssertEqual(writer.writtenFrameBytes, jpegByteCount)
        XCTAssertEqual(archive.filter { $0.path.hasSuffix(".jpg") }.count, count)
    }
}

@MainActor
private final class SyntheticTendiesProvider: WallpaperFrameProvider {
    var frameSize: CGSize { CGSize(width: 16, height: 24) }
    var duration: CMTime? { nil }
    var requestedTimes: [CMTime] = []
    private var prepared = false

    func prepareForExport() async throws { prepared = true; requestedTimes = [] }

    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        guard prepared else { throw WallpaperFrameProviderError.notPrepared }
        requestedTimes.append(time)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 24, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: (index % 2) * 8, y: (index / 2) * 12, width: 8, height: 12))
        }
        let marker = CGFloat(min(1, Double(requestedTimes.count - 1) / 300))
        context.setFillColor(CGColor(red: marker, green: marker, blue: marker, alpha: 1))
        context.fill(CGRect(x: 4, y: 6, width: 8, height: 12))
        let image = try XCTUnwrap(context.makeImage())
        return try MediaCaptureFrameProvider.pixelBuffer(from: image)
    }

    func finishExport() async { prepared = false }
}
