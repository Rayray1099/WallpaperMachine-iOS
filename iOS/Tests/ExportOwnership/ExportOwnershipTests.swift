// SPDX-License-Identifier: GPL-3.0-only
import CoreImage
import CoreVideo
import Darwin
import Foundation
import XCTest
@testable import WMExportOwnershipHarness

/// Every method is invoked in a fresh test-host process by the owning workflow.
/// Release callbacks observe actual source storage, not RSS or a runner process.
@MainActor
final class ExportOwnershipTests: XCTestCase {
    private enum Scope: String { case plain, appendPool, pipelinePool }
    private struct Failure: Error { }

    func testPlainObserve() async throws { try exercise(.plain) }
    func testAppendPoolObserve() async throws { try exercise(.appendPool) }
    func testPipelinePoolBounded() async throws { try exercise(.pipelinePool) }

    private func exercise(_ scope: Scope) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (side, output, requested) in [
            (320, PixelSize(width: 320, height: 480), 80),
            (2160, PixelSize(width: 1668, height: 2420), 240)
        ] {
            let counters = SourceLifetimes()
            var written = 0
            var stopped = false
            let initialRSS = residentBytes()
            var peakRSS = initialRSS
            // Deliberately hold one outer pool for an entire workload. The plain
            // case must not gain an implicit per-frame drain from the test runner.
            try autoreleasepool {
                let compositor = FrameCompositor(plan: ExportRenderPlan(pixelSize: output, aspectMode: .fit))
                let descriptor = TendiesWallpaperDescriptor(screenClass: .iPadPro11M4,
                    displayName: "Procedural Ownership", identifier: 12345, pixelSize: output,
                    frameCount: requested, frameRate: 30)
                let writer = try TendiesExportWriter(descriptor: descriptor,
                    outputURL: directory.appendingPathComponent("\(scope.rawValue)-\(side).tendies"),
                    compositor: compositor, jpegQuality: 0.82, includesDisplayNameMetadata: true)
                defer { writer.cancel() }
                for index in 0..<requested {
                    if scope == .pipelinePool {
                        try autoreleasepool {
                            try appendProceduralFrame(writer, compositor: compositor, side: side,
                                                      index: index, counters: counters, appendPool: false)
                        }
                    } else {
                        try appendProceduralFrame(writer, compositor: compositor, side: side,
                                                  index: index, counters: counters, appendPool: scope == .appendPool)
                    }
                    written += 1
                    peakRSS = max(peakRSS, residentBytes())
                    // Stop on actual test-host RSS growth too: source release
                    // counters cannot observe separate decoded/JPEG output copies.
                    if peakRSS > initialRSS + 384 * 1024 * 1024 {
                        stopped = true
                        break
                    }
                    // The baseline is observation, not an unbounded stress run:
                    // 16 source allocations at 2160² are about 285 MiB of pixels.
                    if counters.snapshot.live >= 16 {
                        stopped = true
                        break
                    }
                }
                XCTAssertEqual(writer.writtenFrames, written)
                if !stopped { _ = try writer.finish() }
                let sample = counters.snapshot
                print("OWNERSHIP inside scope=\(scope.rawValue) source=\(side)x\(side) output=\(output) requested=\(requested) written=\(written) created=\(sample.created) released=\(sample.released) live=\(sample.live) peak=\(sample.peak) initialRSSBytes=\(initialRSS) peakRSSBytes=\(peakRSS) stoppedAtSafetyCap=\(stopped)")
            }
            // Drain asynchronous Core Image releases too, without hiding in-loop
            // retention. Only this post-workload cleanup has an eventual deadline.
            let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let sample = counters.snapshot
                return sample.created == sample.released
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 5), .completed,
                           "Every procedural source allocation must be released after teardown")
            let final = counters.snapshot
            XCTAssertEqual(final.created, written)
            XCTAssertEqual(final.released, written)
            XCTAssertEqual(final.live, 0)
            if scope == .pipelinePool {
                XCTAssertFalse(stopped, "Whole-frame pool must complete without the source-retention safety cap")
                XCTAssertEqual(written, requested)
                XCTAssertLessThan(final.peak, 16, "Source storage must not grow with frame count")
            }
            print("OWNERSHIP final scope=\(scope.rawValue) source=\(side)x\(side) output=\(output) requested=\(requested) written=\(written) created=\(final.created) released=\(final.released) live=\(final.live) peak=\(final.peak) initialRSSBytes=\(initialRSS) peakRSSBytes=\(peakRSS) stoppedAtSafetyCap=\(stopped)")
        }
        print("Scope: actual UIKit/CoreImage/compositor/JPEG/ZIP source-buffer ownership; no AVAssetReader, source asset, device reset reproduction, total-memory bound or production-fix verdict.")
    }

    /// Native test-host process only, not the runner/device/global free-memory metric.
    /// RSS is a safety observation, not proof of a particular allocator's ownership.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        XCTAssertEqual(status, KERN_SUCCESS, "Actual host memory sample must succeed")
        return info.resident_size
    }

    @inline(never)
    private func appendProceduralFrame(_ writer: TendiesExportWriter, compositor: FrameCompositor,
                                       side: Int, index: Int, counters: SourceLifetimes, appendPool: Bool) throws {
        let buffer = try makeBuffer(side: side, index: index, counters: counters)
        let image = try compositor.render(source: buffer)
        if appendPool {
            try autoreleasepool { try writer.append(image, frameIndex: index) }
        } else {
            try writer.append(image, frameIndex: index)
        }
    }

    private func makeBuffer(side: Int, index: Int, counters: SourceLifetimes) throws -> CVPixelBuffer {
        let rowBytes = side * 4
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * side, alignment: 64)
        let pixels = pointer.bindMemory(to: UInt32.self, capacity: side * side)
        pixels.initialize(repeating: 0xff202020 | UInt32(index % 128), count: side * side)
        for y in 0..<(side / 2) {
            pixels.advanced(by: y * side).update(repeating: 0xff30c830, count: side / 2)
        }
        let allocation = SourceAllocation(pointer: pointer, counters: counters)
        let retained = Unmanaged.passRetained(allocation)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, side, side,
            kCVPixelFormatType_32BGRA, pointer, rowBytes, { refcon, _ in
                guard let refcon else { return }
                Unmanaged<SourceAllocation>.fromOpaque(refcon).takeRetainedValue().releaseStorage()
            }, retained.toOpaque(), nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            retained.takeRetainedValue().releaseStorage()
            throw Failure()
        }
        return buffer
    }
}

private final class SourceAllocation {
    let pointer: UnsafeMutableRawPointer
    let counters: SourceLifetimes
    init(pointer: UnsafeMutableRawPointer, counters: SourceLifetimes) {
        self.pointer = pointer
        self.counters = counters
        counters.created()
    }
    func releaseStorage() {
        pointer.deallocate()
        counters.released()
    }
}

private final class SourceLifetimes: @unchecked Sendable {
    struct Snapshot {
        let created: Int
        let released: Int
        let peak: Int
        var live: Int { created - released }
    }
    private let lock = NSLock()
    private var allocated = 0
    private var freed = 0
    private var highWater = 0
    func created() {
        lock.lock()
        defer { lock.unlock() }
        allocated += 1
        highWater = max(highWater, allocated - freed)
    }
    func released() {
        lock.lock()
        defer { lock.unlock() }
        freed += 1
    }
    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(created: allocated, released: freed, peak: highWater)
    }
}
