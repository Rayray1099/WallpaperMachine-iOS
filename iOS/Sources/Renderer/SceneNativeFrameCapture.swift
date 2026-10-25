// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import CoreGraphics
import CoreMedia
import Foundation
import QuartzCore

/// Scene capture has its own native-output budget. Unlike the web snapshot
/// limit, this never silently reduces a requested iPad-sized export to 1920px.
struct SceneCaptureLimits: Equatable, Sendable {
    let maximumEdge: Int
    let maximumPixels: Int

    static let native = SceneCaptureLimits(maximumEdge: 4096, maximumPixels: 12_000_000)
    static let maximumFrameRate = 60

    func validatedSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite,
              let width = Int(exactly: size.width), let height = Int(exactly: size.height),
              maximumEdge > 0, maximumPixels > 0,
              width > 0, height > 0, width <= maximumEdge, height <= maximumEdge,
              width <= maximumPixels / height else { return nil }
        return CGSize(width: width, height: height)
    }
}

enum SceneFrameCaptureError: Error, Equatable, LocalizedError {
    case notReady
    case invalidSize
    case invalidResponse
    case imageUnavailable
    case timedOut
    case busy

    var errorDescription: String? {
        let key: String
        switch self {
        case .notReady: key = "scene.capture.notReady"
        case .invalidSize: key = "scene.capture.invalidSize"
        case .invalidResponse: key = "scene.capture.invalidResponse"
        case .imageUnavailable: key = "scene.capture.imageUnavailable"
        case .timedOut: key = "scene.capture.timeout"
        case .busy: key = "scene.capture.busy"
        }
        return NSLocalizedString(key, comment: "Native scene frame capture failure")
    }
}

/// Read-only access to the renderer's existing, layer-targeted poster mailbox.
/// The layer is borrowed: this object neither acquires a drawable nor renders a
/// UIView/CALayer. Native MetalPosterCapture composes into its own texture only
/// when requested, copies width*height*4 bytes, and posts them on the main queue.
///
/// The host MUST call invalidate() before changing the source/surface, shutting
/// down, detaching, or becoming inactive. Readiness must describe a genuinely
/// presented frame from the current native session, not a preview or old count.
@MainActor
final class SceneNativeFrameCapture: MediaFrameProviding {
    static let requestNotification = Notification.Name("WallpaperMachine.requestDesktopPoster")
    static let readyNotification = Notification.Name("WallpaperMachine.desktopPosterReady")

    private weak var layer: CAMetalLayer?
    private let isReady: @MainActor () -> Bool
    private let center: NotificationCenter
    private let limits: SceneCaptureLimits
    private let timeoutNanoseconds: UInt64
    private let sleep: @MainActor (UInt64) async throws -> Void
    private var sessionGeneration = UUID()
    private var captureGeneration = UUID()
    private var activeRequest: SceneNativeCaptureRequest?

    init(layer: CAMetalLayer, isReady: @escaping @MainActor () -> Bool,
         center: NotificationCenter = .default, limits: SceneCaptureLimits = .native,
         timeoutNanoseconds: UInt64 = 10_000_000_000,
         sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.layer = layer
        self.isReady = isReady
        self.center = center
        self.limits = limits
        self.timeoutNanoseconds = timeoutNanoseconds
        self.sleep = sleep
    }

    var frameSource: MediaFrameSource { .scene }
    var isFrameCaptureReady: Bool { layer != nil && isReady() }

    /// Invalidates queued notification Tasks as well as the currently suspended
    /// await. A later ready notification can never satisfy the next session.
    func invalidate() {
        sessionGeneration = UUID()
        captureGeneration = UUID()
        activeRequest?.cancel()
        activeRequest = nil
    }

    func captureFrame(at time: CMTime?, maximumSize: CGSize) async throws -> MediaFrame {
        try Task.checkCancellation()
        // Scene is live. `time` is deliberately not presented as a native seek.
        guard isFrameCaptureReady, let layer else { throw SceneFrameCaptureError.notReady }
        guard limits.validatedSize(layer.drawableSize) != nil,
              maximumSize == .zero || limits.validatedSize(maximumSize) != nil else {
            throw SceneFrameCaptureError.invalidSize
        }
        guard activeRequest == nil else { throw SceneFrameCaptureError.busy }
        let session = sessionGeneration
        let generation = UUID()
        captureGeneration = generation
        let request = SceneNativeCaptureRequest(center: center)
        activeRequest = request
        defer { if activeRequest === request { activeRequest = nil } }
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(layer: layer, limits: limits, maximumSize: maximumSize,
                              timeoutNanoseconds: timeoutNanoseconds, sleep: sleep,
                              isCurrent: { [weak self] in
                                  self?.sessionGeneration == session && self?.captureGeneration == generation
                              }, isReady: { [weak self] in self?.isFrameCaptureReady == true },
                              continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        guard sessionGeneration == session, captureGeneration == generation else { throw CancellationError() }
        guard isFrameCaptureReady else { throw SceneFrameCaptureError.notReady }
        return frame
    }
}

/// One continuation, observer and timer. Every terminal path removes the
/// observer, cancels the timer and resumes exactly once; cancellation does not
/// wait for an uncancellable native Metal command buffer to complete.
@MainActor
private final class SceneNativeCaptureRequest {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<MediaFrame, Error>?
    private var completed = false

    init(center: NotificationCenter) { self.center = center }

    deinit {
        if let observer { center.removeObserver(observer) }
        timeoutTask?.cancel()
    }

    func start(layer: CAMetalLayer, limits: SceneCaptureLimits, maximumSize: CGSize,
               timeoutNanoseconds: UInt64, sleep: @escaping @MainActor (UInt64) async throws -> Void,
               isCurrent: @escaping @MainActor () -> Bool, isReady: @escaping @MainActor () -> Bool,
               continuation: CheckedContinuation<MediaFrame, Error>) {
        guard !completed else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let context = UUID().uuidString
        // Register first: a synchronous test responder (or a very fast native
        // response) is safe. Check identity again rather than trusting the filter.
        observer = center.addObserver(forName: SceneNativeFrameCapture.readyNotification, object: layer, queue: .main) { [weak self, weak layer] note in
            Task { @MainActor in
                guard let self, !self.completed, let layer,
                      let target = note.object as? CAMetalLayer, target === layer,
                      let values = note.userInfo, values["context"] as? String == context else { return }
                guard isCurrent() else { self.cancel(); return }
                guard isReady() else { self.complete(.failure(SceneFrameCaptureError.notReady)); return }
                do {
                    let image = try SceneNativeCapturePixels.image(values: values, limits: limits, maximumSize: maximumSize)
                    self.complete(.success(MediaFrame(image: image, presentationTime: nil, source: .scene)))
                } catch { self.complete(.failure(error)) }
            }
        }
        timeoutTask = Task { @MainActor [weak self] in
            do { try await sleep(timeoutNanoseconds); try Task.checkCancellation() }
            catch { return }
            self?.complete(.failure(SceneFrameCaptureError.timedOut))
        }
        center.post(name: SceneNativeFrameCapture.requestNotification, object: layer, userInfo: ["context": context])
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ result: Result<MediaFrame, Error>) {
        guard !completed else { return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if let observer { center.removeObserver(observer) }
        observer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(with: result)
    }
}

private enum SceneNativeCapturePixels {
    static func image(values: [AnyHashable: Any], limits: SceneCaptureLimits, maximumSize: CGSize) throws -> CGImage {
        guard let width = integer(values["width"]), let height = integer(values["height"]),
              limits.validatedSize(CGSize(width: width, height: height)) != nil,
              let format = values["bgra"] as? NSNumber, CFGetTypeID(format) == CFBooleanGetTypeID(),
              let pixels = values["pixels"] as? Data else { throw SceneFrameCaptureError.invalidResponse }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, pixels.count == byteCount else { throw SceneFrameCaptureError.invalidResponse }
        // Do not retain a borrowed NSData/no-copy storage owned by a notifier.
        let owned = pixels.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        // The native final composition is opaque, just like its desktop encoder.
        // BGRA bytes are little-endian with the alpha slot first in the word;
        // RGBA bytes are big-endian with that slot last. No channel/row swap:
        // Metal getBytes returns the composition's top-left row first, and the
        // mailbox does not publish a separate origin flag.
        let bitmapInfo = CGBitmapInfo(rawValue: format.boolValue
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: owned as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SceneFrameCaptureError.imageUnavailable
        }
        guard maximumSize != .zero else { return image }
        let factor = min(1, maximumSize.width / CGFloat(width), maximumSize.height / CGFloat(height))
        guard factor < 1 else { return image }
        let outputWidth = max(1, Int(floor(CGFloat(width) * factor)))
        let outputHeight = max(1, Int(floor(CGFloat(height) * factor)))
        guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                                      bytesPerRow: outputWidth * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw SceneFrameCaptureError.imageUnavailable
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard let scaled = context.makeImage() else { throw SceneFrameCaptureError.imageUnavailable }
        return scaled
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return Int(exactly: value.doubleValue)
    }
}
