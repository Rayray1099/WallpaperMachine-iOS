// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streams managed videos to an explicitly paired PC and saves only receipt-verified archives.
actor PCConverterClient {
    enum Phase: String, Sendable { case preparing, uploading, converting, downloading, verifying }
    struct Progress: Sendable {
        let phase: Phase
        var completed: Int64 = 0
        var total: Int64 = 0
        var fraction: Double? { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : nil }
    }
    struct Receipt: Sendable {
        let outputURL: URL
        let byteSize: Int64
        let sha256: String
        let sampleAspectRatioAssumed: Bool
        let requestedFrameRate: Int
        let requestedPackageLayout: PCConverterOptions.PackageLayout
    }
    struct State: Decodable { let jobs: [Job] }
    struct Job: Decodable {
        struct Progress: Decodable {
            var current: Int64?
            var total: Int64?
            var output_bytes: Int64?
        }
        let id: String
        let state: String
        var progress: Progress?
        var download_url: String?
        var bytes: Int64?
        var sha256: String?
        var sample_aspect_ratio_assumed: Bool?

        func receipt() throws -> (bytes: Int64, sha256: String) {
            guard state == "done", let bytes, bytes > 0, bytes < 1_900_000_000,
                  let sha256, sha256.utf8.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw PCConverterError.response
            }
            return (bytes, sha256)
        }
    }
    private struct CreatedJob: Decodable { let id: String }
    private let connection: PCConverterConnection
    private let outputDirectory: @Sendable () throws -> URL
    private var jobID: String?
    private var running = false

    init(connection: PCConverterConnection,
         outputDirectory: @escaping @Sendable () throws -> URL = { try WallpaperExportLocation.exportsDirectory() }) {
        self.connection = connection
        self.outputDirectory = outputDirectory
    }

    func convert(sourceURL: URL, entryFile: String, title: String,
                 options: PCConverterOptions = PCConverterOptions(),
                 progress: @escaping @Sendable (Progress) -> Void) async throws -> Receipt {
        guard !running else { throw PCConverterError.busy }
        running = true
        defer { running = false; jobID = nil }
        do {
            return try await withThrowingTaskGroup(of: Receipt.self) { group in
                group.addTask { try await self.perform(sourceURL: sourceURL, entryFile: entryFile, title: title, options: options, progress: progress) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                    throw PCConverterError.timeout
                }
                defer { group.cancelAll() }
                guard let receipt = try await group.next() else { throw CancellationError() }
                return receipt
            }
        } catch {
            // A separate task does not inherit the cancelled conversion's cancellation.
            // This only cancels the UUID returned by our upload, never other PC jobs.
            if let jobID {
                let request = request(path: "/api/jobs/\(jobID)/cancel", method: "POST", timeout: 5)
                let cleanup = Task { _ = try? await PCConverterTransfer.run(request: request, resourceTimeout: 5) }
                await cleanup.value
            }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw (error as? PCConverterError) ?? PCConverterError.transport
        }
    }

    private func perform(sourceURL: URL, entryFile: String, title: String, options: PCConverterOptions,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> Receipt {
        try Task.checkCancellation()
        progress(Progress(phase: .preparing))
        let source = try Self.managedVideo(sourceURL: sourceURL, entryFile: entryFile)
        let query = options.conversionQuery(title: title)
        var upload = request(path: "/api/jobs", method: "POST", query: query)
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.setValue(String(source.bytes), forHTTPHeaderField: "Content-Length")
        progress(Progress(phase: .uploading, total: source.bytes))
        let created = try await PCConverterTransfer.run(request: upload, uploadFile: source.url) { sent, total in
            progress(Progress(phase: .uploading, completed: sent, total: total))
        }
        try Self.validateHTTP(created.response, expected: 202)
        let identifier: String
        do { identifier = try JSONDecoder().decode(CreatedJob.self, from: created.data).id }
        catch { throw PCConverterError.response }
        guard PCConverterConnection.isJobID(identifier) else { throw PCConverterError.response }
        jobID = identifier
        try Task.checkCancellation()
        var completedJob: Job?
        while completedJob == nil {
            try Task.checkCancellation()
            let response = try await PCConverterTransfer.run(request: request(path: "/api/state"))
            try Self.validateHTTP(response.response, expected: 200)
            let state: State
            do { state = try JSONDecoder().decode(State.self, from: response.data) }
            catch { throw PCConverterError.response }
            guard state.jobs.count <= 20, let job = state.jobs.first(where: { $0.id == identifier }) else {
                throw PCConverterError.response
            }
            switch job.state {
            case "done": completedJob = job
            case "uploading", "queued", "converting":
                let total = job.progress?.total ?? 0
                let current = job.progress?.current ?? 0
                progress(Progress(phase: .converting, completed: max(0, min(current, total)),
                                  total: (1...72_000).contains(total) ? total : 0))
                try await Task.sleep(nanoseconds: 1_000_000_000)
            case "cancelled": throw CancellationError()
            case "failed": throw PCConverterError.conversion
            default: throw PCConverterError.response
            }
        }
        guard let job = completedJob, let relative = job.download_url else { throw PCConverterError.response }
        let expected = try job.receipt()
        let downloadURL = try connection.downloadURL(relative: relative, jobID: identifier)
        var download = URLRequest(url: downloadURL, timeoutInterval: 20)
        connection.authorize(&download)
        download.cachePolicy = .reloadIgnoringLocalCacheData
        progress(Progress(phase: .downloading, total: expected.bytes))
        let downloaded = try await PCConverterTransfer.run(request: download, downloadBytes: expected.bytes) { received, _ in
            progress(Progress(phase: .downloading, completed: received, total: expected.bytes))
        }
        // The transfer owns this exact UUID staging URL until it hands it to us.
        guard let temporary = downloaded.fileURL else { throw PCConverterError.archive }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validateHTTP(downloaded.response, expected: 200)
        try Task.checkCancellation()
        progress(Progress(phase: .verifying, total: expected.bytes))
        let hash = try Self.verifyArchive(at: temporary, bytes: expected.bytes, sha256: expected.sha256)
        try Task.checkCancellation()
        let destination: URL
        do {
            let directory = try outputDirectory()
            destination = WallpaperExportLocation.uniqueFileURL(baseName: title, fileExtension: "tendies", in: directory)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch { throw PCConverterError.storage }
        do { try Task.checkCancellation() }
        catch {
            // moveItem just created this path; cancellation never leaves an export behind.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return Receipt(outputURL: destination, byteSize: expected.bytes, sha256: hash,
                       sampleAspectRatioAssumed: job.sample_aspect_ratio_assumed ?? false,
                       requestedFrameRate: options.frameRate.rawValue,
                       requestedPackageLayout: options.packageLayout)
    }

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = [], timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: connection.endpoint(path: path, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        connection.authorize(&request)
        if method == "POST" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
        return request
    }

    static func managedVideo(sourceURL: URL, entryFile: String) throws -> (url: URL, bytes: Int64) {
        do {
            guard sourceURL.isFileURL else { throw PCConverterError.source }
            try AssetPath.validate(entryFile)
            let root = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard root.isSymbolicLink != true else { throw PCConverterError.source }
            let file: URL
            if root.isDirectory == true { file = try AssetPath.resolve(entryFile, inside: sourceURL) }
            else {
                guard sourceURL.lastPathComponent == entryFile else { throw PCConverterError.source }
                file = sourceURL
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
                  bytes > 0, Int64(bytes) <= 2 * 1024 * 1024 * 1024,
                  FileManager.default.isReadableFile(atPath: file.path) else { throw PCConverterError.source }
            return (file, Int64(bytes))
        } catch { throw PCConverterError.source }
    }

    static func validateHTTP(_ response: HTTPURLResponse, expected: Int) throws {
        switch response.statusCode {
        case expected: return
        case 401, 403: throw PCConverterError.authorization
        case 409: throw PCConverterError.busy
        case 413: throw PCConverterError.source
        case 507: throw PCConverterError.storage
        default: throw PCConverterError.response
        }
    }

    static func verifyArchive(at url: URL, bytes: Int64, sha256: String) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, bytes > 0, bytes < 1_900_000_000,
              Int64(values.fileSize ?? 0) == bytes else { throw PCConverterError.archive }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else { throw PCConverterError.archive }
        try handle.seek(toOffset: 0)
        var digest = SHA256()
        var read: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            read += Int64(data.count)
            guard read <= bytes else { throw PCConverterError.archive }
            digest.update(data: data)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard read == bytes, actual == sha256 else { throw PCConverterError.archive }
        return actual
    }
}

/// One bounded transfer per session: no redirects, cookies, caches, credentials or whole-archive Data.
private final class PCConverterTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Result: @unchecked Sendable {
        let response: HTTPURLResponse
        let data: Data
        let fileURL: URL?
    }
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Result, Error>?
    private var data = Data()
    private var fileURL: URL?
    private var failure: Error?
    private let downloadBytes: Int64?
    private let progress: @Sendable (Int64, Int64) -> Void
    private var lastProgress = Date.distantPast
    private static let maxJSONBytes = 256 * 1024

    private init(downloadBytes: Int64?, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.downloadBytes = downloadBytes; self.progress = progress
    }

    static func run(request: URLRequest, uploadFile: URL? = nil, downloadBytes: Int64? = nil,
                    resourceTimeout: TimeInterval = 30 * 60,
                    progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> Result {
        let transfer = PCConverterTransfer(downloadBytes: downloadBytes, progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                transfer.start(request: request, uploadFile: uploadFile, resourceTimeout: resourceTimeout, continuation: continuation)
            }
        } onCancel: { transfer.cancel() }
    }

    private func start(request: URLRequest, uploadFile: URL?, resourceTimeout: TimeInterval,
                       continuation: CheckedContinuation<Result, Error>) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task: URLSessionTask
        if let uploadFile { task = session.uploadTask(with: request, fromFile: uploadFile) }
        else if downloadBytes != nil { task = session.downloadTask(with: request) }
        else { task = session.dataTask(with: request) }
        lock.lock()
        self.continuation = continuation; self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    private func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        reportProgress(totalBytesSent, totalBytesExpectedToSend)
    }

    private func reportProgress(_ completed: Int64, _ total: Int64) {
        let now = Date()
        guard completed == total || now.timeIntervalSince(lastProgress) >= 0.2 else { return }
        lastProgress = now
        progress(completed, total)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= Int64(Self.maxJSONBytes) else {
            failure = PCConverterError.response; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= Self.maxJSONBytes - data.count else {
            failure = PCConverterError.response; dataTask.cancel(); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let expected = downloadBytes, totalBytesWritten <= expected,
              totalBytesExpectedToWrite < 0 || totalBytesExpectedToWrite == expected else {
            failure = PCConverterError.archive; downloadTask.cancel(); return
        }
        reportProgress(totalBytesWritten, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard failure == nil, let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200, let expected = downloadBytes,
              response.expectedContentLength == expected else { failure = PCConverterError.archive; return }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("PCConverter-\(UUID().uuidString).partial")
        do { try FileManager.default.moveItem(at: location, to: owned); fileURL = owned }
        catch { failure = PCConverterError.storage }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil; self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        let problem = wasCancelled ? CancellationError() : failure ?? error
        if let problem {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            continuation?.resume(throwing: problem)
        } else if let response = task.response as? HTTPURLResponse {
            continuation?.resume(returning: Result(response: response, data: data, fileURL: fileURL))
        } else {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            continuation?.resume(throwing: PCConverterError.response)
        }
    }
}
