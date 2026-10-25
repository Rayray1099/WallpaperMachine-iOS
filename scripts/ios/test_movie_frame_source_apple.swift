// SPDX-License-Identifier: GPL-3.0-only
// Headless macOS AVFoundation regression; compile the actual export sources, no stubs.
// Usage: <binary> generate|10-plain|30-plain|60-plain|10-pool|30-pool|60-pool <owned-fixture-dir>
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@main
struct MovieFrameSourceAppleRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
    }
    static func main() async {
        do {
            let args = CommandLine.arguments
            try require(args.count == 3, "Expected mode and owned fixture directory")
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            if args[1] == "generate" {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let small = directory.appendingPathComponent("vfr.mp4")
                try await writeFixture(small, side: 144, ticks: [0, 12, 42, 59], end: 60)
                try await checkVFR(small) // Fail the cheap timing contract before making the big fixture.
                try await writeFixture(directory.appendingPathComponent("square.mp4"), side: 2160,
                                       ticks: Array(0..<492), end: 492)
                print("PASS: generated original fixtures; big source 492 frames / 60 = 8.2 seconds")
            } else {
                let parts = args[1].split(separator: "-")
                try require(parts.count == 2, "Unknown sampling mode")
                let rate = Int(parts[0]) ?? 0
                try require([10, 30, 60].contains(rate) && ["plain", "pool"].contains(String(parts[1])),
                            "Unknown sampling mode")
                try await checkSequential(directory.appendingPathComponent("square.mp4"),
                                          rate: rate, pooled: parts[1] == "pool")
            }
            print("Scope: actual macOS AVAssetWriter/AVAssetReader only; no UIKit, compositor, JPEG/archive, app or iPad coverage; not a device root-cause or memory-fix verdict.")
        } catch let failure as Failure {
            fail(failure.description)
        } catch let error as MovieFrameSourceError {
            // Only readerFailed is already privacy-bounded by the actual production diagnostics.
            if case .readerFailed(let codes) = error { fail("decoder \(codes)") }
            else { fail("source setup/validation failed (no NSError text emitted)") }
        } catch {
            fail("setup \(MovieFrameSourceDiagnostics(stage: .start, readerStatus: nil, error: error as NSError))")
        }
    }
    static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: MovieFrameSource Apple: \(text)\n".utf8))
        exit(1)
    }

    // A 9-bit grayscale timestamp surrogate plus three moving RGB regions. Solid
    // cell-centre probes tolerate lossy H.264; even a one-source-frame error fails.
    static let colors: [UInt32] = [0xffc83030, 0xff30c830, 0xff3030c8]
    static func paint(_ buffer: CVPixelBuffer, index: Int) throws {
        try require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, "Fixture lock")
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(description: "Fixture pixels missing") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            let cells = y < height / 2 ? 9 : 3
            for cell in 0..<cells {
                let start = cell * width / cells, end = (cell + 1) * width / cells
                let value: UInt32 = cells == 9 ? ((index & (1 << cell)) == 0 ? 0xff282828 : 0xffd8d8d8)
                                              : colors[(index + cell) % 3]
                row.advanced(by: start).initialize(repeating: value, count: end - start)
            }
        }
    }

    static func writeFixture(_ url: URL, side: Int, ticks: [Int], end: Int) async throws {
        try require(!FileManager.default.fileExists(atPath: url.path), "Refusing to overwrite fixture")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Main52 is not a portable AVFoundation constant. AutoLevel must emit the
        // exact required profile/level at 2160²60; verify avcC before any big count.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60, AVVideoAverageBitRateKey: side == 2160 ? 32_000_000 : 1_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60, AVVideoAllowFrameReorderingKey: false
            ],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        try require(writer.canAdd(input), "Fixture writer configuration")
        writer.add(input)
        try require(writer.startWriting(), "Fixture writer start \(writerDiagnostic(writer))")
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw Failure(description: "Fixture buffer pool missing") }
        let queue = DispatchQueue(label: "MovieReaderRegression.fixture")
        // One pool, no retained image arrays. The allocation threshold bounds live
        // writer buffers; excessive retention fails setup rather than exhausting CI.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var index = 0, done = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !done else { return }
                do {
                    while input.isReadyForMoreMediaData && index < ticks.count {
                        try autoreleasepool {
                            var buffer: CVPixelBuffer?
                            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                                [kCVPixelBufferPoolAllocationThresholdKey as String: 16] as CFDictionary, &buffer)
                            try require(status == kCVReturnSuccess, "Fixture pool allocation status=\(status)")
                            guard let buffer else { throw Failure(description: "Fixture buffer missing") }
                            try paint(buffer, index: index)
                            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(ticks[index]), timescale: 60)),
                                        "Fixture append index=\(index) \(writerDiagnostic(writer))")
                        }
                        index += 1
                    }
                    if index == ticks.count {
                        done = true
                        input.markAsFinished()
                        continuation.resume()
                    } else if writer.status != .writing {
                        throw Failure(description: "Fixture stopped \(writerDiagnostic(writer))")
                    }
                } catch {
                    done = true
                    input.markAsFinished()
                    continuation.resume(throwing: error)
                }
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(end), timescale: 60))
        await writer.finishWriting()
        try require(writer.status == .completed, "Fixture finish \(writerDiagnostic(writer))")
    }
    static func writerDiagnostic(_ writer: AVAssetWriter) -> String {
        "writerStatus=\(writer.status.rawValue) \(MovieFrameSourceDiagnostics(stage: .start, readerStatus: nil, error: writer.error as NSError?))"
    }

    static func inspect(_ source: MovieFrameSource, side: Int, big: Bool) async throws {
        let tracks = try await source.asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "Fixture must have exactly one video track")
        let size = try await tracks[0].load(.naturalSize)
        let formats = try await tracks[0].load(.formatDescriptions)
        try require(size.width == CGFloat(side) && size.height == CGFloat(side), "Natural dimensions mismatch")
        try require(source.info.pixelSize == PixelSize(width: side, height: side), "Actual source info dimensions mismatch")
        try require(source.info.preferredTransform == .identity, "Unexpected fixture transform")
        try require(formats.count == 1 && CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264,
                    "Fixture codec must be H.264 / avc1")
        let dimensions = CMVideoFormatDescriptionGetDimensions(formats[0])
        try require(dimensions.width == Int32(side) && dimensions.height == Int32(side), "Format dimensions mismatch")
        guard let rawExtensions = CMFormatDescriptionGetExtensions(formats[0]) else {
            throw Failure(description: "Missing format extensions")
        }
        let extensions = rawExtensions as NSDictionary
        guard let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary,
              let avcC = atoms["avcC"] as? Data, avcC.count >= 4 else {
            throw Failure(description: "Missing avcC profile/level")
        }
        try require(avcC[0] == 1 && avcC[1] == 77, "Fixture must be H.264 Main profile (77)")
        if big {
            try require(avcC[3] == 52, "Fixture must be Main@5.2 (52); no profile/dimension fallback")
            try require(abs(source.info.nominalFrameRate - 60) < 0.01, "Fixture rate must be 60 fps")
            try require(abs(source.info.duration.seconds - 8.2) < 0.01, "Fixture duration must be 8.2 seconds")
        }
        print("INFO: codec=avc1 profile=\(avcC[1]) level=\(avcC[3]) natural=\(side)x\(side) rate=\(source.info.nominalFrameRate) duration=\(source.info.duration.seconds)")
    }

    static func checkPixels(_ source: MovieFrameSource, time: CMTime, expected: Int, side: Int) throws {
        guard let buffer = try source.frame(at: time) else {
            throw Failure(description: "Early nil at outputTime=\(time.seconds) sourceIndex=\(expected)")
        }
        try require(CVPixelBufferGetWidth(buffer) == side && CVPixelBufferGetHeight(buffer) == side,
                    "Decoder changed resolution")
        try require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, "Decoder format is not BGRA")
        try require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess, "Decoded lock")
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(description: "Decoded pixels missing") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var decodedIndex = 0
        for cell in 0..<9 {
            let pixel = base.advanced(by: (side / 4) * stride + ((2 * cell + 1) * side / 18) * 4)
                .assumingMemoryBound(to: UInt8.self)
            let gray = (expected & (1 << cell)) == 0 ? 40 : 216
            try require((0..<3).allSatisfy { abs(Int(pixel[$0]) - gray) <= 24 },
                        "Timestamp cell mismatch sourceIndex=\(expected) cell=\(cell) outputTime=\(time.seconds)")
            if pixel[0] > 128 { decodedIndex |= 1 << cell }
        }
        try require(decodedIndex == expected, "Wrong timestamp surrogate")
        for cell in 0..<3 {
            let pixel = base.advanced(by: (3 * side / 4) * stride + ((2 * cell + 1) * side / 6) * 4)
                .assumingMemoryBound(to: UInt8.self)
            let color = colors[(expected + cell) % 3]
            for channel in 0..<3 {
                let wanted = Int((color >> (channel * 8)) & 255)
                try require(abs(Int(pixel[channel]) - wanted) <= 36,
                            "Moving RGB mismatch sourceIndex=\(expected) region=\(cell) channel=\(channel)")
            }
        }
    }

    static func checkVFR(_ url: URL) async throws {
        let source = try await MovieFrameSource.open(url: url)
        defer { source.close() }
        try await inspect(source, side: 144, big: false)
        try require(abs(source.info.duration.seconds - 1) < 0.01, "Tiny VFR fixture duration must be one second")
        try source.start()
        // Exact first/lookahead transitions, repeated held frames, forward skip,
        // and final valid tick. EOF holds the last frame intentionally: no nil assertion beyond duration.
        for (tick, expected) in [(0, 0), (100, 0), (199, 0), (200, 1), (201, 1), (699, 1), (700, 2), (982, 2), (984, 3), (999, 3)] {
            try autoreleasepool { try checkPixels(source, time: CMTime(value: Int64(tick), timescale: 1000), expected: expected, side: 144) }
        }
        source.close()
        try require(try source.frame(at: .zero) == nil, "Closed source must not retain an output frame")
        try source.start()
        try checkPixels(source, time: .zero, expected: 0, side: 144)
        try checkPixels(source, time: CMTime(value: 999, timescale: 1000), expected: 3, side: 144)
        print("PASS: tiny H.264 VFR first/lookahead/hold/step/last-valid/close/restart (10 valid ticks plus restart/forward skip)")
    }

    static func checkSequential(_ url: URL, rate: Int, pooled: Bool) async throws {
        let source = try await MovieFrameSource.open(url: url)
        defer { source.close() }
        try await inspect(source, side: 2160, big: true)
        try source.start()
        let count = 8 * rate
        for tick in 0..<count {
            let time = CMTime(value: Int64(tick), timescale: Int32(rate))
            let expected = tick * (60 / rate)
            if pooled {
                try autoreleasepool { try checkPixels(source, time: time, expected: expected, side: 2160) }
            } else {
                // Match production's absence of an explicit per-tick pool. Never
                // let the pooled control alone conceal caller-side buffer retention.
                try checkPixels(source, time: time, expected: expected, side: 2160)
            }
        }
        print("PASS: sequential rate=\(rate) pool=\(pooled) count=\(count) ticks=0...\(count - 1) last=\(Double(count - 1) / Double(rate)); all timestamp cells and moving RGB regions checked; no frame arrays")
    }
}
