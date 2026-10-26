// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import CoreGraphics
import CoreMedia
import Foundation
import QuartzCore

/// A separate capability from live capture: each index names one native
/// simulation frame, independent of how long readback/encoding takes.
@MainActor
protocol OfflineSceneFrameProviding: AnyObject {
    var isOfflineFrameCaptureReady: Bool { get }
    var offlineFrameRate: Int { get }
    func captureOfflineFrame(index: Int, frameRate: Int, maximumSize: CGSize) async throws -> MediaFrame
    /// Terminal, synchronous teardown. The host drains native ownership before
    /// the export controller releases the shared-assets reader lease.
    func finishOfflineCapture()
}

enum OfflineSceneCaptureError: Error, Equatable, LocalizedError {
    case invalidSequence
    case nativeFailed
    case sessionEnded

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidSequence: key = "scene.offline.invalidSequence"
        case .nativeFailed: key = "scene.offline.nativeFailed"
        case .sessionEnded: key = "scene.offline.sessionEnded"
        }
        return NSLocalizedString(key, comment: "Offline native scene export failure")
    }
}

/// Receives the private, GPU-completion-backed manual-export notification. No C
/// ABI dependency is present here: the host injects a request closure, and unit
/// tests use only CPU data plus a dummy layer identity.
@MainActor
final class OfflineSceneFrameCapture: OfflineSceneFrameProviding {
    static let readyNotification = Notification.Name("WallpaperMachine.sceneExportFrameReady")
    static let maximumFrameIndex = 17_999

    private weak var layer: CAMetalLayer?
    let offlineFrameRate: Int
    private let isReady: @MainActor () -> Bool
    private let request: @MainActor (UInt32, String) throws -> Void
    private let center: NotificationCenter
    private let timeoutNanoseconds: UInt64
    private let sleep: @MainActor (UInt64) async throws -> Void
    private var generation = UUID()
    private var ended = false
    private var nextIndex = 0
    private var activeRequest: OfflineSceneCaptureRequest?

    init(layer: CAMetalLayer, frameRate: Int, isReady: @escaping @MainActor () -> Bool,
         request: @escaping @MainActor (UInt32, String) throws -> Void,
         center: NotificationCenter = .default, timeoutNanoseconds: UInt64 = 10_000_000_000,
         sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.layer = layer
        self.offlineFrameRate = frameRate
        self.isReady = isReady
        self.request = request
        self.center = center
        self.timeoutNanoseconds = timeoutNanoseconds
        self.sleep = sleep
    }

    var isOfflineFrameCaptureReady: Bool { !ended && layer != nil && isReady() }

    func finishOfflineCapture() {
        ended = true
        generation = UUID()
        activeRequest?.cancel()
        activeRequest = nil
    }

    func captureOfflineFrame(index: Int, frameRate: Int, maximumSize: CGSize) async throws -> MediaFrame {
        try Task.checkCancellation()
        guard !ended else { throw OfflineSceneCaptureError.sessionEnded }
        guard activeRequest == nil else { throw SceneFrameCaptureError.busy }
        guard index == nextIndex, (0...Self.maximumFrameIndex).contains(index),
              frameRate == offlineFrameRate, (1...SceneCaptureLimits.maximumFrameRate).contains(frameRate) else {
            throw OfflineSceneCaptureError.invalidSequence
        }
        guard isOfflineFrameCaptureReady, let layer else { throw SceneFrameCaptureError.notReady }
        guard SceneCaptureLimits.native.validatedSize(maximumSize) == maximumSize,
              layer.drawableSize == maximumSize else { throw SceneFrameCaptureError.invalidSize }
        let session = generation
        let capture = OfflineSceneCaptureRequest(center: center)
        activeRequest = capture
        defer { if activeRequest === capture { activeRequest = nil } }
        do {
            let frame = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    capture.start(layer: layer, index: index, frameRate: frameRate, outputSize: maximumSize,
                                  timeoutNanoseconds: timeoutNanoseconds, sleep: sleep, request: request,
                                  isCurrent: { [weak self] in self?.generation == session && self?.ended == false },
                                  isReady: { [weak self] in self?.isOfflineFrameCaptureReady == true },
                                  continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor in capture.cancel() }
            }
            try Task.checkCancellation()
            guard generation == session, !ended else { throw CancellationError() }
            guard isOfflineFrameCaptureReady else { throw SceneFrameCaptureError.notReady }
            nextIndex += 1
            return frame
        } catch {
            finishOfflineCapture() // a consumed index must never be retried
            throw error
        }
    }
}

@MainActor
private final class OfflineSceneCaptureRequest {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<MediaFrame, Error>?
    private var completed = false

    init(center: NotificationCenter) { self.center = center }
    deinit {
        if let observer { center.removeObserver(observer) }
        timer?.cancel()
    }

    func start(layer: CAMetalLayer, index: Int, frameRate: Int, outputSize: CGSize,
               timeoutNanoseconds: UInt64, sleep: @escaping @MainActor (UInt64) async throws -> Void,
               request: @escaping @MainActor (UInt32, String) throws -> Void,
               isCurrent: @escaping @MainActor () -> Bool, isReady: @escaping @MainActor () -> Bool,
               continuation: CheckedContinuation<MediaFrame, Error>) {
        guard !completed else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let context = UUID().uuidString
        observer = center.addObserver(forName: OfflineSceneFrameCapture.readyNotification, object: layer, queue: .main) { [weak self, weak layer] note in
            Task { @MainActor in
                guard let self, !self.completed, let layer,
                      let target = note.object as? CAMetalLayer, target === layer,
                      let values = note.userInfo, values["context"] as? String == context else { return }
                guard isCurrent() else { self.cancel(); return }
                do {
                    guard OfflineScenePixels.integer(values["index"]) == index,
                          OfflineScenePixels.integer(values["frameRate"]) == frameRate,
                          let status = OfflineScenePixels.integer(values["status"]), status <= 0 else {
                        throw SceneFrameCaptureError.invalidResponse
                    }
                    guard status == 0 else { throw OfflineSceneCaptureError.nativeFailed }
                    guard isReady() else { throw SceneFrameCaptureError.notReady }
                    let image = try OfflineScenePixels.image(values, outputSize: outputSize)
                    self.complete(.success(MediaFrame(image: image,
                        presentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)), source: .scene)))
                } catch { self.complete(.failure(error)) }
            }
        }
        timer = Task { @MainActor [weak self] in
            do { try await sleep(timeoutNanoseconds); try Task.checkCancellation() }
            catch { return }
            self?.complete(.failure(SceneFrameCaptureError.timedOut))
        }
        do { try request(UInt32(index), context) }
        catch { complete(.failure(error)) }
    }

    func cancel() { complete(.failure(CancellationError())) }
    private func complete(_ result: Result<MediaFrame, Error>) {
        guard !completed else { return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if let observer { center.removeObserver(observer) }
        observer = nil
        timer?.cancel()
        timer = nil
        continuation?.resume(with: result)
    }
}

private enum OfflineScenePixels {
    static func integer(_ raw: Any?) -> Int? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return Int(exactly: value.doubleValue)
    }

    static func image(_ values: [AnyHashable: Any], outputSize: CGSize) throws -> CGImage {
        guard let width = integer(values["width"]), let height = integer(values["height"]),
              SceneCaptureLimits.native.validatedSize(CGSize(width: width, height: height)) == outputSize,
              let bgra = values["bgra"] as? NSNumber, CFGetTypeID(bgra) == CFBooleanGetTypeID(),
              let pixels = values["pixels"] as? Data,
              pixels.count == width * height * 4 else { throw SceneFrameCaptureError.invalidResponse }
        let owned = pixels.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        let info = CGBitmapInfo(rawValue: bgra.boolValue
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: owned as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SceneFrameCaptureError.imageUnavailable
        }
        return image
    }
}
