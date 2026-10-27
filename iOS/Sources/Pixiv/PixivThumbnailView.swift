// SPDX-License-Identifier: GPL-3.0-only
import ImageIO
import SwiftUI
import UIKit

struct PixivThumbnailView: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var thumbnail: PixivDownsampledImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(LocalizedStringKey(failed ? "pixiv.thumbnail.unavailable" : "pixiv.thumbnail")))
            }
        }
        .task(id: url) {
            thumbnail = nil
            failed = false
            guard let url, PixivService.isImageURL(url) else {
                failed = url != nil
                return
            }
            do {
                let loaded = try await PixivThumbnailLoader.shared.load(url)
                try Task.checkCancellation()
                thumbnail = loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
        .accessibilityIdentifier("pixiv.thumbnail")
    }
}

private actor PixivThumbnailLoader {
    static let shared = PixivThumbnailLoader()
    private static let byteLimit = 8 * 1024 * 1024
    private static let maximumPixelSize = 512
    private static let maximumConcurrentRequests = 6
    private static let maximumDecodedCacheBytes = 48 * 1024 * 1024

    private let session: URLSession
    private var permitsInUse = 0
    private var waitOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cache: [String: PixivDownsampledImage] = [:]
    private var cacheCosts: [String: Int] = [:]
    private var cacheOrder: [String] = []
    private var cacheCost = 0

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = Self.maximumConcurrentRequests
        session = URLSession(
            configuration: configuration,
            delegate: PixivThumbnailRedirectGuard(),
            delegateQueue: nil)
    }

    func load(_ url: URL) async throws -> PixivDownsampledImage {
        guard PixivService.isImageURL(url) else { throw PixivServiceError(code: .unreadable) }
        let cacheKey = url.absoluteString
        if let cached = cachedImage(for: cacheKey) { return cached }
        try await acquirePermit()
        defer { releasePermit() }
        try Task.checkCancellation()
        if let cached = cachedImage(for: cacheKey) { return cached }

        var request = URLRequest(url: url)
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.5",
                         forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              PixivService.isImageURL(response.url ?? url),
              http.expectedContentLength <= Int64(Self.byteLimit) || http.expectedContentLength < 0
        else { throw PixivServiceError(code: .unreadable) }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(min(http.expectedContentLength, Int64(Self.byteLimit))))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.byteLimit else { throw PixivServiceError(code: .tooLarge(megabytes: 8)) }
            data.append(byte)
        }
        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw PixivServiceError(code: .undecodable)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PixivServiceError(code: .undecodable)
        }
        let image = PixivDownsampledImage(
            image: UIImage(cgImage: cgImage),
            cost: cgImage.bytesPerRow * cgImage.height)
        cacheImage(image, for: cacheKey)
        return image
    }

    private func acquirePermit() async throws {
        try Task.checkCancellation()
        if permitsInUse < Self.maximumConcurrentRequests {
            permitsInUse += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    waitOrder.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if Task.isCancelled {
            releasePermit()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waitOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func releasePermit() {
        while !waitOrder.isEmpty {
            let id = waitOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: id) else { continue }
            continuation.resume()
            return
        }
        permitsInUse = max(0, permitsInUse - 1)
    }

    private func cachedImage(for key: String) -> PixivDownsampledImage? {
        guard let image = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return image
    }

    private func cacheImage(_ image: PixivDownsampledImage, for key: String) {
        if let oldCost = cacheCosts.removeValue(forKey: key) {
            cacheCost -= oldCost
            cache.removeValue(forKey: key)
            cacheOrder.removeAll { $0 == key }
        }
        guard image.cost <= Self.maximumDecodedCacheBytes else { return }
        cache[key] = image
        cacheCosts[key] = image.cost
        cacheOrder.append(key)
        cacheCost += image.cost
        while cacheCost > Self.maximumDecodedCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
            cacheCost -= cacheCosts.removeValue(forKey: oldest) ?? 0
        }
    }
}

private struct PixivDownsampledImage: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}

private final class PixivThumbnailRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, PixivService.isImageURL(url) else {
            completionHandler(nil)
            return
        }
        var request = request
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(request)
    }
}
