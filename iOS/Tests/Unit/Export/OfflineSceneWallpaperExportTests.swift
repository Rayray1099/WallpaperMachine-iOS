// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import XCTest
@testable import WallpaperMachineIOS

/// CPU-only protocol tests. Notifications are fake; these tests do not claim a
/// GPU render, native simulation advance, throughput, or a device installation.
@MainActor
final class OfflineSceneWallpaperExportTests: XCTestCase {
    func testMailboxDecodesNativeChannelsAndAnnotatesVerifiedRationalTimestamp() async throws {
        for bgra in [true, false] {
            let box = OfflineTestMailbox()
            defer { box.onRequest = nil }
            let capture = box.capture()
            box.onRequest = { index, context in box.respond(index, context, bgra: bgra) }
            let first = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size)
            let second = try await capture.captureOfflineFrame(index: 1, frameRate: 60, maximumSize: box.size)
            XCTAssertEqual(first.source, .scene)
            XCTAssertEqual(first.presentationTime, CMTime.zero)
            XCTAssertEqual(second.presentationTime, CMTime(value: 1, timescale: 60))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(first.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [255, 0, 0, 255])
            XCTAssertEqual(box.indices, [0, 1])
            XCTAssertEqual(Set(box.contexts).count, 2)
        }
    }

    func testMailboxIgnoresUnrelatedContextAndLayerAndRejectsWrongFrameIdentity() async throws {
        let box = OfflineTestMailbox()
        defer { box.onRequest = nil }
        let capture = box.capture()
        box.onRequest = { index, context in
            box.respond(index, "old-context", updates: ["pixels": Data()])
            box.respond(index, context, layer: CAMetalLayer(), updates: ["pixels": Data()])
            box.respond(index, context)
        }
        _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size)
        box.onRequest = { index, context in box.respond(index, context, updates: ["index": 0]) }
        do { _ = try await capture.captureOfflineFrame(index: 1, frameRate: 60, maximumSize: box.size); XCTFail("Wrong native index accepted") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .invalidResponse) }
        XCTAssertFalse(capture.isOfflineFrameCaptureReady)
    }

    func testMailboxRejectsMalformedMatchingCompletionAndNativeFailure() async throws {
        for update: [AnyHashable: Any] in [
            ["status": true], ["status": "0"], ["status": 1], ["index": true], ["index": "0"],
            ["frameRate": 30], ["width": CGFloat.infinity], ["width": 4097], ["pixels": Data(count: 3)],
            ["bgra": 1], ["status": -1]
        ] {
            let box = OfflineTestMailbox()
            defer { box.onRequest = nil }
            let capture = box.capture()
            box.onRequest = { index, context in box.respond(index, context, updates: update) }
            do { _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size); XCTFail("Malformed completion accepted: \(update)") }
            catch {
                if update["status"] as? Int == -1 { XCTAssertEqual(error as? OfflineSceneCaptureError, .nativeFailed) }
                else { XCTAssertEqual(error as? SceneFrameCaptureError, .invalidResponse) }
            }
            XCTAssertFalse(capture.isOfflineFrameCaptureReady)
        }
    }

    func testMailboxValidatesSequenceRateAndNativeSizeBeforeRequest() async throws {
        let box = OfflineTestMailbox()
        defer { box.onRequest = nil }
        let capture = box.capture()
        for (index, rate) in [(1, 60), (-1, 60), (18_000, 60), (0, 30)] {
            do { _ = try await capture.captureOfflineFrame(index: index, frameRate: rate, maximumSize: box.size); XCTFail("Invalid request accepted") }
            catch { XCTAssertEqual(error as? OfflineSceneCaptureError, .invalidSequence) }
        }
        do { _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: CGSize(width: 2, height: 2)); XCTFail("Upscaled native size accepted") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .invalidSize) }
        XCTAssertTrue(box.indices.isEmpty)
        box.onRequest = { index, context in box.respond(index, context) }
        _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size)
    }

    func testMailboxSynchronousNativeRejectionDoesNotWaitForNotification() async throws {
        let box = OfflineTestMailbox()
        box.reject = true
        let capture = box.capture()
        do { _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size); XCTFail("Rejected native request succeeded") }
        catch { XCTAssertEqual(error as? OfflineSceneCaptureError, .nativeFailed) }
        XCTAssertFalse(capture.isOfflineFrameCaptureReady)
    }

    func testMailboxTimeoutAndQueuedGenerationInvalidationAreTerminal() async throws {
        for timeout in [true, false] {
            let box = OfflineTestMailbox()
            defer { box.onRequest = nil }
            let capture = box.capture(sleep: { _ in
                if timeout { return }
                try await Task.sleep(nanoseconds: 10_000_000_000)
            })
            if !timeout {
                box.onRequest = { index, context in
                    box.respond(index, context)
                    capture.finishOfflineCapture()
                }
            }
            do { _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size); XCTFail("Stale/timeout capture succeeded") }
            catch {
                if timeout { XCTAssertEqual(error as? SceneFrameCaptureError, .timedOut) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            box.respond(0, try XCTUnwrap(box.contexts.first)) // late callback is harmless
            XCTAssertFalse(capture.isOfflineFrameCaptureReady)
        }
    }

    func testMailboxCancellationAndBusyNeverConsumeAnotherIndex() async throws {
        let box = OfflineTestMailbox()
        defer { box.onRequest = nil }
        let capture = box.capture()
        let requested = expectation(description: "Manual request pending")
        box.onRequest = { _, _ in requested.fulfill() }
        let task = Task { @MainActor in try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size) }
        await fulfillment(of: [requested], timeout: 2)
        do { _ = try await capture.captureOfflineFrame(index: 0, frameRate: 60, maximumSize: box.size); XCTFail("Concurrent request accepted") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled capture succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        box.respond(0, try XCTUnwrap(box.contexts.first))
        XCTAssertEqual(box.indices, [0])
        XCTAssertFalse(capture.isOfflineFrameCaptureReady)
    }

    func testProviderPrimesFrameZeroExactlyOnceAndAcceptsEquivalentRationalTimes() async throws {
        let source = try OfflineTestSource()
        let provider = OfflineSceneWallpaperExportProvider(source: source, outputSize: source.size, frameRate: 60)
        try await provider.prepareForExport()
        XCTAssertEqual(source.indices, [0])
        XCTAssertEqual(provider.frameSize, source.size)
        let first = try await provider.frame(at: .zero)
        XCTAssertNotNil(first)
        XCTAssertEqual(source.indices, [0], "Primed zero must not advance the native scene twice")
        _ = try await provider.frame(at: CMTime(value: 2, timescale: 120))
        _ = try await provider.frame(at: CMTime(value: 1, timescale: 30))
        XCTAssertEqual(source.indices, [0, 1, 2])
        await provider.finishExport()
        await provider.finishExport()
        XCTAssertEqual(source.finishCount, 1)
        XCTAssertEqual(provider.frameSize, .zero)
    }

    func testProviderEncodingDelayDoesNotChangeSimulationFrameIndices() async throws {
        let source = try OfflineTestSource()
        source.onCapture = {
            // Deliberately exceeds the live provider's 0.5s drift budget: a
            // manual frame remains index/fps even when producing it is slow.
            if source.indices.last == 1 { try? await Task.sleep(nanoseconds: 600_000_001) }
        }
        defer { source.onCapture = nil }
        let provider = OfflineSceneWallpaperExportProvider(source: source, outputSize: source.size, frameRate: 60)
        try await provider.prepareForExport()
        for index in 0..<4 {
            // Arbitrary CPU/encoding delay is not read as a live-source seek.
            try await Task.sleep(nanoseconds: 1_000_000)
            _ = try await provider.frame(at: CMTime(value: CMTimeValue(index), timescale: 60))
        }
        XCTAssertEqual(source.indices, [0, 1, 2, 3])
        await provider.finishExport()
    }

    func testProviderRejectsSkippedRepeatedAndInvalidTimestampsWithoutNativeRequest() async throws {
        for time in [CMTime.invalid, .positiveInfinity, CMTime(value: -1, timescale: 60), CMTime(value: 1, timescale: 60)] {
            let source = try OfflineTestSource()
            let provider = OfflineSceneWallpaperExportProvider(source: source, outputSize: source.size, frameRate: 60)
            try await provider.prepareForExport()
            do { _ = try await provider.frame(at: time); XCTFail("Nonsequential timestamp accepted") }
            catch { XCTAssertEqual(error as? OfflineSceneCaptureError, .invalidSequence) }
            XCTAssertEqual(source.indices, [0])
            XCTAssertEqual(source.finishCount, 1)
        }
        let source = try OfflineTestSource()
        let provider = OfflineSceneWallpaperExportProvider(source: source, outputSize: source.size, frameRate: 60)
        try await provider.prepareForExport()
        _ = try await provider.frame(at: .zero)
        do { _ = try await provider.frame(at: .zero); XCTFail("Repeated timestamp accepted") }
        catch { XCTAssertEqual(error as? OfflineSceneCaptureError, .invalidSequence) }
        XCTAssertEqual(source.indices, [0])
    }

    func testProviderRejectsWrongSourceTimestampSizeAndUnreadyNativeFrame() async throws {
        for mode in 0..<5 {
            let source = try OfflineTestSource()
            var size = source.size
            switch mode {
            case 0: source.returnedSource = .web
            case 1: source.returnedTime = .zero; source.omitTime = true
            case 2: source.returnedTime = CMTime(value: 1, timescale: 60)
            case 3: size = CGSize(width: 1668, height: 2420)
            default: source.onCapture = { source.isOfflineFrameCaptureReady = false }
            }
            let provider = OfflineSceneWallpaperExportProvider(source: source, outputSize: size, frameRate: 60)
            do { try await provider.prepareForExport(); XCTFail("Invalid manual source accepted: \(mode)") }
            catch { XCTAssertEqual(provider.frameSize, .zero) }
            XCTAssertEqual(source.finishCount, 1)
        }
    }

    func testProviderCancellationAndFinishEndPendingRequestAndIgnoreLateReturn() async throws {
        for cancel in [true, false] {
            let source = try OfflineTestSource()
            defer { source.onCapture = nil; source.pending?.resume(); source.pending = nil }
            let started = expectation(description: "Offline source pending")
            source.onCapture = { await withCheckedContinuation { source.pending = $0; started.fulfill() } }
            let provider = OfflineSceneWallpaperExportProvider(source: source, outputSize: source.size, frameRate: 60)
            let ended = expectation(description: "Cancelled prepare ended promptly")
            let task = Task { @MainActor in
                do { try await provider.prepareForExport(); XCTFail("Cancelled offline prepare succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                ended.fulfill()
            }
            await fulfillment(of: [started], timeout: 2)
            if cancel { task.cancel() } else { await provider.finishExport() }
            await fulfillment(of: [ended], timeout: 2)
            source.pending?.resume(); source.pending = nil
            await task.value
            XCTAssertEqual(provider.frameSize, .zero)
            XCTAssertEqual(source.finishCount, 1)
            do { try await provider.prepareForExport(); XCTFail("Terminal manual session restarted") }
            catch { XCTAssertEqual(error as? OfflineSceneCaptureError, .sessionEnded) }
        }
    }
}

@MainActor
private final class OfflineTestMailbox {
    let center = NotificationCenter()
    let layer = CAMetalLayer()
    let size = CGSize(width: 1, height: 1)
    var ready = true
    var reject = false
    var indices: [Int] = []
    var contexts: [String] = []
    var onRequest: ((Int, String) -> Void)?
    init() { layer.drawableSize = size }

    func capture(sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) -> OfflineSceneFrameCapture {
        OfflineSceneFrameCapture(layer: layer, frameRate: 60, isReady: { [weak self] in self?.ready == true },
            request: { [weak self] index, context in
                guard let self else { throw OfflineSceneCaptureError.nativeFailed }
                self.indices.append(Int(index)); self.contexts.append(context)
                if self.reject { throw OfflineSceneCaptureError.nativeFailed }
                self.onRequest?(Int(index), context)
            }, center: center, sleep: sleep)
    }

    func respond(_ index: Int, _ context: String, layer: CAMetalLayer? = nil, bgra: Bool = true,
                 updates: [AnyHashable: Any] = [:]) {
        var values: [AnyHashable: Any] = ["context": context, "index": index, "frameRate": 60, "status": 0,
            "width": 1, "height": 1, "bgra": bgra, "pixels": Data(bgra ? [0, 0, 255, 255] : [255, 0, 0, 255])]
        values.merge(updates) { _, replacement in replacement }
        center.post(name: OfflineSceneFrameCapture.readyNotification, object: layer ?? self.layer, userInfo: values)
    }
}

@MainActor
private final class OfflineTestSource: OfflineSceneFrameProviding {
    let size = CGSize(width: 16, height: 16)
    var isOfflineFrameCaptureReady = true
    let offlineFrameRate = 60
    var indices: [Int] = []
    var finishCount = 0
    var returnedSource: MediaFrameSource = .scene
    var returnedTime: CMTime?
    var omitTime = false
    var onCapture: (() async -> Void)?
    var pending: CheckedContinuation<Void, Never>?
    private let image: CGImage

    init() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        image = try XCTUnwrap(context.makeImage())
    }
    func captureOfflineFrame(index: Int, frameRate: Int, maximumSize: CGSize) async throws -> MediaFrame {
        indices.append(index)
        await onCapture?()
        return MediaFrame(image: image, presentationTime: omitTime ? nil : (returnedTime ?? CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))), source: returnedSource)
    }
    func finishOfflineCapture() { finishCount += 1; isOfflineFrameCaptureReady = false }
}
