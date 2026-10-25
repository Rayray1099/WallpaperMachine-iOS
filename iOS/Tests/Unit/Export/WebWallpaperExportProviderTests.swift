// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreMedia
import XCTest
@testable import WallpaperMachineIOS

@MainActor
final class WebWallpaperExportProviderTests: XCTestCase {
    func testPrepareIsSingleCaptureAndRetainsSizeAcrossFreshSessions() async throws {
        let source = try ExportTestSource()
        var clock: UInt64 = 1_000_000_000
        var waits: [UInt64] = []
        let size = CGSize(width: 320, height: 180)
        let provider = WebWallpaperExportProvider(source: source, maximumSize: size,
            now: { clock }, sleep: { waits.append($0); clock += $0 })
        try await provider.prepareForExport()
        XCTAssertEqual(source.captureCount, 1)
        XCTAssertEqual(source.sizes, [size])
        let first = try await provider.frame(at: .zero)
        let second = try await provider.frame(at: CMTime(value: 1, timescale: 10))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(waits, [100_000_000])
        await provider.finishExport()
        clock += 10_000_000_000
        try await provider.prepareForExport()
        let restarted = try await provider.frame(at: .zero)
        XCTAssertNotNil(restarted)
        XCTAssertTrue(source.sizes.allSatisfy { $0 == size })
        await provider.finishExport()
        XCTAssertEqual(provider.frameSize, .zero)
        do {
            _ = try await provider.frame(at: .zero)
            XCTFail("Unprepared capture must fail")
        } catch { XCTAssertEqual(error as? WallpaperFrameProviderError, .notPrepared) }
    }

    func testSlowFinalSnapshotFailsRatherThanReportingSuccess() async throws {
        let source = try ExportTestSource()
        var clock: UInt64 = 1_000_000_000
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16), now: { clock })
        try await provider.prepareForExport()
        source.onCapture = { clock += 500_000_001 }
        do {
            _ = try await provider.frame(at: .zero)
            XCTFail("Even the only/final frame must fail when its snapshot is too slow")
        } catch {
            guard let failure = error as? WallpaperFrameProviderError, case .renderFailed = failure else {
                return XCTFail("Expected live drift failure, got \(error)")
            }
        }
        await provider.finishExport()
    }

    func testLateWakeFailsBeforeTakingAnotherSnapshot() async throws {
        let source = try ExportTestSource()
        var clock: UInt64 = 1_000_000_000
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16),
            now: { clock }, sleep: { clock += $0 + 500_000_001 })
        try await provider.prepareForExport()
        _ = try await provider.frame(at: .zero)
        do {
            _ = try await provider.frame(at: CMTime(value: 1, timescale: 10))
            XCTFail("A late wake must fail before taking a misleading snapshot")
        } catch { XCTAssertEqual(source.captureCount, 2) }
        await provider.finishExport()
    }

    func testRejectsInvalidAndRewindingTimestamps() async throws {
        let source = try ExportTestSource()
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16), now: { 1 })
        try await provider.prepareForExport()
        for time in [CMTime.invalid, .positiveInfinity, CMTime(value: -1, timescale: 1)] {
            do { _ = try await provider.frame(at: time); XCTFail("Invalid timestamp accepted") }
            catch { }
        }
        _ = try await provider.frame(at: .zero)
        do { _ = try await provider.frame(at: .zero); XCTFail("Repeated live timestamp accepted") }
        catch { }
        XCTAssertEqual(source.captureCount, 2)
        await provider.finishExport()
    }

    func testCancellationDoesNotWaitForUncancellableSnapshot() async throws {
        let source = try ExportTestSource()
        let started = expectation(description: "Snapshot started")
        source.onCapture = {
            await withCheckedContinuation { source.pending = $0; started.fulfill() }
        }
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16))
        let ended = expectation(description: "Cancelled without snapshot callback")
        let task = Task { @MainActor in
            do { try await provider.prepareForExport(); XCTFail("Cancelled prepare succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            ended.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [ended], timeout: 2)
        // Simulate WebKit's eventual callback; it must not resume the await twice.
        source.pending?.resume()
        source.pending = nil
        await task.value
        XCTAssertEqual(provider.frameSize, .zero)
        await provider.finishExport()
    }

    func testSnapshotTimeoutAndLateCallbackLeaveProviderUnprepared() async throws {
        let source = try ExportTestSource()
        source.onCapture = { await withCheckedContinuation { source.pending = $0 } }
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16),
                                                   snapshotTimeoutNanoseconds: 1_000_000)
        do { try await provider.prepareForExport(); XCTFail("Hung snapshot succeeded") }
        catch {
            guard let failure = error as? WallpaperFrameProviderError, case .unavailable = failure else {
                source.pending?.resume(); source.pending = nil
                return XCTFail("Expected timeout, got \(error)")
            }
        }
        source.pending?.resume()
        source.pending = nil
        XCTAssertEqual(provider.frameSize, .zero)
        await provider.finishExport()
    }

    func testCancelledTaskDoesNotStartSnapshot() async throws {
        let source = try ExportTestSource()
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await provider.prepareForExport(); XCTFail("Cancelled prepare succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        XCTAssertEqual(source.captureCount, 0)
        await provider.finishExport()
    }

    func testSurfaceMustRemainReadyUntilSnapshotCompletes() async throws {
        let source = try ExportTestSource()
        let provider = WebWallpaperExportProvider(source: source, maximumSize: CGSize(width: 16, height: 16))
        source.onCapture = { source.isFrameCaptureReady = false }
        do { try await provider.prepareForExport(); XCTFail("Detached source accepted") }
        catch { XCTAssertEqual(provider.frameSize, .zero) }
        await provider.finishExport()
    }

    func testMediaAdapterPreservesConfiguredBoundDuringServicePrepare() async throws {
        let source = try ExportTestSource()
        let provider = MediaCaptureFrameProvider(source: source)
        let size = CGSize(width: 320, height: 180)
        try await provider.prepareForExport(maximumSize: size)
        try await provider.prepareForExport()
        _ = try await provider.frame(at: .zero)
        XCTAssertEqual(source.sizes, [size, size, size])
        source.isFrameCaptureReady = false
        do { try await provider.prepareForExport(); XCTFail("Not-ready source accepted") }
        catch { XCTAssertEqual(provider.frameSize, .zero) }
        do { _ = try await provider.frame(at: .zero); XCTFail("Failed prepare retained stale readiness") }
        catch { XCTAssertEqual(error as? WallpaperFrameProviderError, .notPrepared) }
        await provider.finishExport()
    }
}

@MainActor
private final class ExportTestSource: MediaFrameProviding {
    var frameSource: MediaFrameSource { .web }
    var isFrameCaptureReady = true
    var captureCount = 0
    var sizes: [CGSize] = []
    var onCapture: (() async -> Void)?
    var pending: CheckedContinuation<Void, Never>?
    private let image: CGImage

    init() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image = try XCTUnwrap(context.makeImage())
    }

    func captureFrame(at time: CMTime?, maximumSize: CGSize) async throws -> MediaFrame {
        captureCount += 1
        sizes.append(maximumSize)
        await onCapture?()
        return MediaFrame(image: image, presentationTime: nil, source: .web)
    }
}
