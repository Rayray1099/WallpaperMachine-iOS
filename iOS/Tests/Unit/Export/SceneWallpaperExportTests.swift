// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import XCTest
@testable import WallpaperMachineIOS

/// CPU-only mailbox/adapter regressions. The layer is an identity token, not a
/// GPU surface: these tests do not claim real Metal rendering or device export.
@MainActor
final class SceneWallpaperExportTests: XCTestCase {
    func testBGRAAndRGBAAreDecodedByCoreGraphicsWithoutSwappingChannelsOrRows() async throws {
        for bgra in [true, false] {
            let mailbox = SceneTestMailbox()
            defer { mailbox.onRequest = nil }
            let capture = mailbox.capture()
            // Two different rows catch a gratuitous vertical flip as well as an
            // R/B swap. Native posters are opaque; the alpha slot is ignored.
            let rgba: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
            let bytes: [UInt8] = bgra ? [0, 0, 255, 255, 255, 0, 0, 255] : rgba
            mailbox.onRequest = { context in mailbox.respond(context, pixels: Data(bytes), bgra: bgra) }
            let frame = try await capture.captureFrame(at: CMTime(value: 42, timescale: 1), maximumSize: .zero)
            XCTAssertEqual(frame.source, .scene)
            XCTAssertNil(frame.presentationTime, "A live readback must not claim it sought to the requested time")
            XCTAssertEqual(frame.pixelSize, CGSize(width: 1, height: 2))
            XCTAssertEqual(try decodedRGBA(frame.image), rgba)
        }
    }

    func testUnrelatedLayerAndContextResponsesAreIgnored() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let otherLayer = CAMetalLayer()
        let capture = mailbox.capture()
        mailbox.onRequest = { context in
            mailbox.respond(context, layer: otherLayer, pixels: Data())
            mailbox.respond("unrelated-context", pixels: Data())
            mailbox.center.post(name: SceneNativeFrameCapture.readyNotification, object: mailbox.layer,
                                userInfo: ["context": 123, "pixels": Data()])
            mailbox.respond(context)
        }
        let frame = try await capture.captureFrame()
        XCTAssertEqual(try decodedRGBA(frame.image), SceneTestMailbox.redBlueRGBA)
        XCTAssertEqual(mailbox.contexts.count, 1)
    }

    func testSynchronousResponseIsSafeAndEveryCaptureUsesUniqueContext() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        mailbox.onRequest = { context in mailbox.respond(context) }
        _ = try await capture.captureFrame()
        _ = try await capture.captureFrame()
        XCTAssertEqual(mailbox.contexts.count, 2)
        XCTAssertEqual(Set(mailbox.contexts).count, 2)
        XCTAssertTrue(mailbox.contexts.allSatisfy { UUID(uuidString: $0) != nil })
    }

    func testQueuedResponseCannotSurviveSessionInvalidation() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        mailbox.onRequest = { context in
            mailbox.respond(context) // ready handler has queued a MainActor Task
            capture.invalidate()     // synchronous host teardown wins that race
        }
        do { _ = try await capture.captureFrame(); XCTFail("Invalidated capture succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let oldContext = try XCTUnwrap(mailbox.contexts.first)
        mailbox.onRequest = { context in
            mailbox.respond(oldContext, pixels: Data())
            mailbox.respond(context)
        }
        let frame = try await capture.captureFrame()
        XCTAssertEqual(try decodedRGBA(frame.image), SceneTestMailbox.redBlueRGBA)
    }

    func testCancellationEndsPromptlyAndLateResponseCannotAnswerNextRequest() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        let requested = expectation(description: "Native request observed")
        mailbox.onRequest = { _ in requested.fulfill() }
        let task = Task { @MainActor in try await capture.captureFrame() }
        await fulfillment(of: [requested], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled native await succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let oldContext = try XCTUnwrap(mailbox.contexts.first)
        mailbox.onRequest = { context in
            mailbox.respond(oldContext, pixels: Data())
            mailbox.respond(context)
            mailbox.respond(context) // duplicate response must not resume twice
        }
        _ = try await capture.captureFrame()
        XCTAssertEqual(mailbox.contexts.count, 2)
    }

    func testTimeoutCleansRequestAndAllowsSubsequentCapture() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        var timerCount = 0
        let capture = mailbox.capture(sleep: { _ in
            timerCount += 1
            if timerCount == 1 { return } // deterministic immediate timeout
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        do { _ = try await capture.captureFrame(); XCTFail("Unanswered mailbox did not time out") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .timedOut) }
        let oldContext = try XCTUnwrap(mailbox.contexts.first)
        mailbox.onRequest = { context in
            mailbox.respond(oldContext, pixels: Data())
            mailbox.respond(context)
        }
        _ = try await capture.captureFrame()
        XCTAssertEqual(mailbox.contexts.count, 2)
    }

    func testReadinessLossWhileWaitingDoesNotReturnFrame() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        mailbox.onRequest = { context in
            mailbox.ready = false
            mailbox.respond(context)
        }
        do { _ = try await capture.captureFrame(); XCTFail("Inactive source returned a frame") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .notReady) }
        mailbox.ready = true
        mailbox.onRequest = { context in mailbox.respond(context) }
        _ = try await capture.captureFrame()
    }

    func testNotReadyAndAlreadyCancelledCallsDoNotPostReadback() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        mailbox.ready = false
        do { _ = try await capture.captureFrame(); XCTFail("Unready scene accepted") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .notReady) }
        mailbox.ready = true
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await capture.captureFrame(); XCTFail("Pre-cancelled capture accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        XCTAssertTrue(mailbox.contexts.isEmpty)
    }

    func testConcurrentRequestIsRejectedWithoutStealingFirstContinuation() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        let requested = expectation(description: "First request pending")
        mailbox.onRequest = { _ in requested.fulfill() }
        let first = Task { @MainActor in try await capture.captureFrame() }
        await fulfillment(of: [requested], timeout: 2)
        do { _ = try await capture.captureFrame(); XCTFail("Concurrent capture accepted") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .busy) }
        mailbox.respond(try XCTUnwrap(mailbox.contexts.first))
        _ = try await first.value
        XCTAssertEqual(mailbox.contexts.count, 1)
    }

    func testMalformedAndOversizedMatchingPayloadsAreRejectedAndReset() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        let valid: [AnyHashable: Any] = ["width": 1, "height": 2, "bgra": true,
                                        "pixels": Data(SceneTestMailbox.redBlueBGRA)]
        var cases: [[AnyHashable: Any]] = []
        for width: Any in [0, -1, 4097, NSNumber(value: Double.nan), NSNumber(value: Double.infinity), 1.5, true, "1"] {
            var values = valid; values["width"] = width; cases.append(values)
        }
        for update: [AnyHashable: Any] in [
            ["width": 4096, "height": 4096], ["pixels": Data(count: 7)],
            ["pixels": Data(count: 9)], ["pixels": "not bytes"], ["bgra": 1], ["bgra": "true"]
        ] { cases.append(valid.merging(update) { _, replacement in replacement }) }
        for payload in cases {
            mailbox.onRequest = { context in
                var values = payload; values["context"] = context
                mailbox.center.post(name: SceneNativeFrameCapture.readyNotification, object: mailbox.layer, userInfo: values)
            }
            do { _ = try await capture.captureFrame(); XCTFail("Invalid payload accepted: \(payload)") }
            catch { XCTAssertEqual(error as? SceneFrameCaptureError, .invalidResponse) }
        }
        mailbox.onRequest = { context in mailbox.respond(context) }
        _ = try await capture.captureFrame()
    }

    func testCaptureBoundsDoNotUpscaleAndRejectUnsafeSurfaceBeforePosting() async throws {
        let mailbox = SceneTestMailbox()
        defer { mailbox.onRequest = nil }
        let capture = mailbox.capture()
        mailbox.onRequest = { context in mailbox.respond(context) }
        let bounded = try await capture.captureFrame(maximumSize: CGSize(width: 1, height: 1))
        XCTAssertEqual(bounded.pixelSize, CGSize(width: 1, height: 1))
        let native = try await capture.captureFrame(maximumSize: CGSize(width: 1668, height: 2420))
        XCTAssertEqual(native.pixelSize, CGSize(width: 1, height: 2), "Readback must not invent native pixels by upscaling")
        let count = mailbox.contexts.count
        mailbox.layer.drawableSize = CGSize(width: 4096, height: 4096)
        do { _ = try await capture.captureFrame(); XCTFail("Unsafe surface triggered native allocation") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .invalidSize) }
        mailbox.layer.drawableSize = CGSize(width: 1, height: 2)
        for size in [CGSize(width: 4097, height: 1), CGSize(width: 1.5, height: 1),
                     CGSize(width: CGFloat.nan, height: 1)] {
            do { _ = try await capture.captureFrame(maximumSize: size); XCTFail("Invalid bound accepted") }
            catch { XCTAssertEqual(error as? SceneFrameCaptureError, .invalidSize) }
        }
        XCTAssertEqual(mailbox.contexts.count, count)
    }

    func testNativeResolutionBudgetDoesNotSilentlyInheritWebLimit() {
        let limits = SceneCaptureLimits.native
        XCTAssertEqual(limits.validatedSize(CGSize(width: 1668, height: 2420)), CGSize(width: 1668, height: 2420))
        XCTAssertEqual(limits.validatedSize(CGSize(width: 4096, height: 2048)), CGSize(width: 4096, height: 2048))
        for size in [CGSize.zero, CGSize(width: -1, height: 2), CGSize(width: 4097, height: 1),
                     CGSize(width: 4096, height: 4096), CGSize(width: .infinity, height: 1),
                     CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1)] {
            XCTAssertNil(limits.validatedSize(size))
        }
    }

    func testProviderUsesLiveNilSourceTimeAndMonotonicPacingAcrossSessions() async throws {
        let source = try SceneTestSource()
        var clock: UInt64 = 1_000_000_000
        var waits: [UInt64] = []
        let size = CGSize(width: 16, height: 16)
        let provider = SceneWallpaperExportProvider(source: source, outputSize: size,
            now: { clock }, sleep: { waits.append($0); clock += $0 })
        try await provider.prepareForExport()
        XCTAssertEqual(source.captureCount, 1)
        XCTAssertEqual(provider.frameSize, size)
        XCTAssertNil(provider.duration)
        let firstResult = try await provider.frame(at: .zero)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(CVPixelBufferGetWidth(first), 16)
        _ = try await provider.frame(at: CMTime(value: 1, timescale: 10))
        XCTAssertEqual(waits, [100_000_000])
        XCTAssertTrue(source.times.allSatisfy { $0 == nil })
        XCTAssertTrue(source.sizes.allSatisfy { $0 == size })
        await provider.finishExport()
        XCTAssertEqual(provider.frameSize, .zero)
        clock += 10_000_000_000
        try await provider.prepareForExport()
        _ = try await provider.frame(at: .zero)
        await provider.finishExport()
    }

    func testProviderRejectsWrongSourceFakeTimelineAndResolutionMismatch() async throws {
        for mode in 0..<5 {
            let source = try SceneTestSource()
            var output = CGSize(width: 16, height: 16)
            switch mode {
            case 0: source.frameSource = .web
            case 1: source.returnedSource = .image
            case 2: source.presentationTime = .zero
            case 3: output = CGSize(width: 1668, height: 2420)
            default: output = CGSize(width: 4096, height: 4096)
            }
            let provider = SceneWallpaperExportProvider(source: source, outputSize: output)
            do { try await provider.prepareForExport(); XCTFail("Misleading native frame accepted: \(mode)") }
            catch { XCTAssertEqual(provider.frameSize, .zero) }
            do { _ = try await provider.frame(at: .zero); XCTFail("Failed prepare left provider ready") }
            catch { XCTAssertEqual(error as? WallpaperFrameProviderError, .notPrepared) }
            await provider.finishExport()
        }
    }

    func testProviderFailsSlowFinalCaptureAndDoesNotLowerFPSOrStayPrepared() async throws {
        let source = try SceneTestSource()
        var clock: UInt64 = 1_000_000_000
        let provider = SceneWallpaperExportProvider(source: source, outputSize: CGSize(width: 16, height: 16), now: { clock })
        try await provider.prepareForExport()
        source.onCapture = { clock += 500_000_001 }
        do { _ = try await provider.frame(at: .zero); XCTFail("Slow final native readback succeeded") }
        catch { assertRenderFailure(error) }
        XCTAssertEqual(source.captureCount, 2)
        XCTAssertEqual(provider.frameSize, .zero)
        do { _ = try await provider.frame(at: CMTime(value: 1, timescale: 60)); XCTFail("Failed live session stayed prepared") }
        catch { XCTAssertEqual(error as? WallpaperFrameProviderError, .notPrepared) }
        await provider.finishExport()
    }

    func testProviderRejectsLateWakeBeforeAnotherNativeReadback() async throws {
        let source = try SceneTestSource()
        var clock: UInt64 = 1_000_000_000
        let provider = SceneWallpaperExportProvider(source: source, outputSize: CGSize(width: 16, height: 16),
            now: { clock }, sleep: { clock += $0 + 500_000_001 })
        try await provider.prepareForExport()
        _ = try await provider.frame(at: .zero)
        do { _ = try await provider.frame(at: CMTime(value: 1, timescale: 10)); XCTFail("Late wake captured a false timeline") }
        catch { assertRenderFailure(error) }
        XCTAssertEqual(source.captureCount, 2)
        XCTAssertEqual(provider.frameSize, .zero)
        await provider.finishExport()
    }

    func testProviderRejectsInvalidRepeatedAndRewindingTimestamps() async throws {
        let source = try SceneTestSource()
        let provider = SceneWallpaperExportProvider(source: source, outputSize: CGSize(width: 16, height: 16), now: { 1 })
        for time in [CMTime.invalid, .positiveInfinity, CMTime(value: -1, timescale: 1)] {
            try await provider.prepareForExport()
            let count = source.captureCount
            do { _ = try await provider.frame(at: time); XCTFail("Invalid timestamp accepted") }
            catch { XCTAssertEqual(source.captureCount, count) }
            XCTAssertEqual(provider.frameSize, .zero)
        }
        for time in [CMTime.zero, CMTime(value: -1, timescale: 1)] {
            try await provider.prepareForExport()
            _ = try await provider.frame(at: .zero)
            let count = source.captureCount
            do { _ = try await provider.frame(at: time); XCTFail("Repeated/rewinding timestamp accepted") }
            catch { XCTAssertEqual(source.captureCount, count) }
        }
        await provider.finishExport()
    }

    func testProviderCancellationAndFinishDoNotWaitForUncancellableSource() async throws {
        for cancelTask in [true, false] {
            let source = try SceneTestSource()
            defer { source.onCapture = nil; source.pending?.resume(); source.pending = nil }
            let started = expectation(description: "Native source suspended")
            source.onCapture = {
                await withCheckedContinuation { source.pending = $0; started.fulfill() }
            }
            let provider = SceneWallpaperExportProvider(source: source, outputSize: CGSize(width: 16, height: 16))
            let ended = expectation(description: "Provider promptly ended")
            let task = Task { @MainActor in
                do { try await provider.prepareForExport(); XCTFail("Cancelled prepare succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                ended.fulfill()
            }
            await fulfillment(of: [started], timeout: 2)
            if cancelTask { task.cancel() } else { await provider.finishExport() }
            await fulfillment(of: [ended], timeout: 2)
            source.pending?.resume(); source.pending = nil
            await task.value
            XCTAssertEqual(provider.frameSize, .zero)
            source.onCapture = nil
            try await provider.prepareForExport()
            _ = try await provider.frame(at: .zero)
            await provider.finishExport()
        }
    }

    func testProviderFinishInterruptsPacingAndOldWakeCannotReviveSession() async throws {
        let source = try SceneTestSource()
        var clock: UInt64 = 1
        var pending: CheckedContinuation<Void, Never>?
        let sleeping = expectation(description: "Waiting for future live tick")
        let provider = SceneWallpaperExportProvider(source: source, outputSize: CGSize(width: 16, height: 16), now: { clock }, sleep: { _ in
            await withCheckedContinuation { pending = $0; sleeping.fulfill() }
        })
        try await provider.prepareForExport()
        _ = try await provider.frame(at: .zero)
        let ended = expectation(description: "Finish cancelled pacing")
        let task = Task { @MainActor in
            do { _ = try await provider.frame(at: CMTime(value: 60, timescale: 1)); XCTFail("Finished pacing returned a frame") }
            catch { XCTAssertTrue(error is CancellationError) }
            ended.fulfill()
        }
        await fulfillment(of: [sleeping], timeout: 2)
        await provider.finishExport()
        await fulfillment(of: [ended], timeout: 2)
        clock += 60_000_000_000
        try await provider.prepareForExport()
        pending?.resume(); pending = nil
        await task.value
        _ = try await provider.frame(at: .zero)
        XCTAssertEqual(source.captureCount, 4)
        await provider.finishExport()
    }

    func testProviderLossOfReadinessAfterCaptureResetsSession() async throws {
        let source = try SceneTestSource()
        let provider = SceneWallpaperExportProvider(source: source, outputSize: CGSize(width: 16, height: 16))
        try await provider.prepareForExport()
        source.onCapture = { source.isFrameCaptureReady = false }
        do { _ = try await provider.frame(at: .zero); XCTFail("Unready scene returned frame") }
        catch { XCTAssertEqual(error as? SceneFrameCaptureError, .notReady) }
        XCTAssertEqual(provider.frameSize, .zero)
        await provider.finishExport()
    }

    private func decodedRGBA(_ image: CGImage) throws -> [UInt8] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data)
        return Array(UnsafeRawBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func assertRenderFailure(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? WallpaperFrameProviderError, case .renderFailed = failure else {
            return XCTFail("Expected live timing failure, got \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class SceneTestMailbox {
    static let redBlueRGBA: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
    static let redBlueBGRA: [UInt8] = [0, 0, 255, 255, 255, 0, 0, 255]
    let center = NotificationCenter()
    let layer = CAMetalLayer()
    var ready = true
    var contexts: [String] = []
    var onRequest: ((String) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        layer.drawableSize = CGSize(width: 1, height: 2)
        observer = center.addObserver(forName: SceneNativeFrameCapture.requestNotification, object: layer, queue: .main) { [weak self] note in
            // The observer, like native's mailbox, may synchronously post ready.
            // MainActor.assumeIsolated is safe because the observer queue is main.
            MainActor.assumeIsolated {
                guard let self, let context = note.userInfo?["context"] as? String else { return }
                self.contexts.append(context)
                self.onRequest?(context)
            }
        }
    }

    deinit { if let observer { center.removeObserver(observer) } }

    func capture(sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) -> SceneNativeFrameCapture {
        SceneNativeFrameCapture(layer: layer, isReady: { [weak self] in self?.ready == true }, center: center, sleep: sleep)
    }

    func respond(_ context: String, layer: CAMetalLayer? = nil, pixels: Data? = nil, bgra: Bool = true) {
        center.post(name: SceneNativeFrameCapture.readyNotification, object: layer ?? self.layer,
                    userInfo: ["context": context, "width": 1, "height": 2, "bgra": bgra,
                               "pixels": pixels ?? Data(Self.redBlueBGRA)])
    }
}

@MainActor
private final class SceneTestSource: MediaFrameProviding {
    var frameSource: MediaFrameSource = .scene
    var returnedSource: MediaFrameSource = .scene
    var presentationTime: CMTime?
    var isFrameCaptureReady = true
    var captureCount = 0
    var sizes: [CGSize] = []
    var times: [CMTime?] = []
    var onCapture: (() async -> Void)?
    var pending: CheckedContinuation<Void, Never>?
    private let image: CGImage

    init() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        image = try XCTUnwrap(context.makeImage())
    }

    func captureFrame(at time: CMTime?, maximumSize: CGSize) async throws -> MediaFrame {
        captureCount += 1
        sizes.append(maximumSize)
        times.append(time)
        await onCapture?()
        return MediaFrame(image: image, presentationTime: presentationTime, source: returnedSource)
    }
}
