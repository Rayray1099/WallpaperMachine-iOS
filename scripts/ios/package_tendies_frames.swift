// CPU converter entry point. Compile with the unchanged iOS Export core, -O.
import Foundation

private struct Request: Decodable {
    let framesDir: String
    let output: String
    let width: Int
    let height: Int
    let fps: Int
    let count: Int
    let name: String
    /// Explicit compatibility experiment; omitted requests retain the legacy format.
    let packageLayout: TendiesPackageLayout?
}

private enum PackageError: Error { case invalidRequest, invalidFrames, sizeLimit }

@main
private enum PackageTendiesFrames {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw PackageError.invalidRequest }
            let requestURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let manager = FileManager.default
            let attributes = try manager.attributesOfItem(atPath: requestURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else {
                throw PackageError.invalidRequest
            }
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
            let job = requestURL.deletingLastPathComponent().resolvingSymlinksInPath()
            let frames = URL(fileURLWithPath: request.framesDir).standardizedFileURL.resolvingSymlinksInPath()
            let output = URL(fileURLWithPath: request.output).standardizedFileURL
            let partial = job.appendingPathComponent("output.tendies.partial")
            guard frames == job.appendingPathComponent("frames"),
                  output == job.appendingPathComponent("output.tendies"),
                  !manager.fileExists(atPath: output.path), !manager.fileExists(atPath: partial.path),
                  (1...18_000).contains(request.count), (1...120).contains(request.fps),
                  (64...4096).contains(request.width), (64...4096).contains(request.height),
                  request.width % 2 == 0, request.height % 2 == 0,
                  request.width * request.height <= 12_000_000,
                  request.name.utf8.count <= 256 else { throw PackageError.invalidRequest }
            let descriptor = try TendiesWallpaperDescriptor(
                screenClass: .iPadPro11M4, displayName: request.name,
                identifier: Int.random(in: 10_000...99_999),
                pixelSize: PixelSize(width: request.width, height: request.height),
                frameCount: request.count, frameRate: Double(request.fps),
                packageLayout: request.packageLayout ?? .legacy
            ).validated()
            let expected = Set((0..<request.count).map { "frame-" + descriptor.frameFileName(at: $0) })
            let children = try manager.contentsOfDirectory(atPath: frames.path)
            guard Set(children) == expected else { throw PackageError.invalidFrames }
            let metadata = try TendiesManifest.metadataFiles(for: descriptor)
            // Include both headers, UTF-8 names, central directory and an ample reserve.
            var archiveBytes = UInt64(1_048_576)
            for file in metadata { archiveBytes += UInt64(file.data.count + file.path.utf8.count * 2 + 76) }
            var urls: [URL] = []
            for index in 0..<request.count {
                let url = frames.appendingPathComponent("frame-" + descriptor.frameFileName(at: index))
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size >= 4, size <= 64 * 1024 * 1024 else {
                    throw PackageError.invalidFrames
                }
                archiveBytes += UInt64(size + descriptor.frameMemberPath(at: index).utf8.count * 2 + 76)
                guard archiveBytes < 1_900_000_000 else { throw PackageError.sizeLimit }
                urls.append(url)
            }
            let writer = try ZipArchiveWriter(outputURL: partial)
            do {
                for file in metadata { try writer.addFile(path: file.path, data: file.data) }
                for (index, url) in urls.enumerated() {
                    let data = try Data(contentsOf: url)
                    guard data.starts(with: [0xff, 0xd8]), data.suffix(2) == Data([0xff, 0xd9]) else {
                        throw PackageError.invalidFrames
                    }
                    try writer.addFile(path: descriptor.frameMemberPath(at: index), data: data)
                }
                try writer.finish()
                try manager.moveItem(at: partial, to: output)
            } catch {
                writer.abort()
                throw error
            }
            let bytes = try manager.attributesOfItem(atPath: output.path)[.size] as? NSNumber
            let result: [String: Any] = ["ok": true, "frames": request.count, "bytes": bytes?.int64Value ?? 0]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
        } catch {
            // Diagnostics from Foundation may contain private paths: never forward them.
            FileHandle.standardError.write(Data("Packaging failed.\n".utf8))
            exit(1)
        }
    }
}
