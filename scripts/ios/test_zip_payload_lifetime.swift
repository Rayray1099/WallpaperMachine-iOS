// SPDX-License-Identifier: GPL-3.0-only
// Compile with the unchanged production ZipArchiveWriter.swift. No Apple SDK required.
import Foundation

@main
struct ZipPayloadLifetimeRegression {
    struct Failure: Error { }
    final class Releases { var count = 0 }

    @inline(never)
    static func append(_ writer: ZipArchiveWriter, index: Int, releases: Releases) throws {
        let size = 256 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: UInt8(index), count: size)
        let data = Data(bytesNoCopy: pointer, count: size, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            releases.count += 1
        })
        try writer.addFile(path: "frame-\(index).bin", data: data)
    }

    static func main() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let releases = Releases()
            let writer = try ZipArchiveWriter(outputURL: folder.appendingPathComponent("payload.zip"))
            for index in 0..<80 {
                try append(writer, index: index, releases: releases)
                guard releases.count == index + 1 else { throw Failure() }
            }
            _ = try writer.finish()
            guard releases.count == 80 else { throw Failure() }
            print("PASS: actual ZipArchiveWriter releases each of 80 no-copy 256KiB payloads before the next append; archive remained open (81 checks)")
            print("Scope: payload ownership only; no UIKit, JPEG, decoder or target-process memory claim.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: ZIP payload lifetime (no NSError text emitted)\n".utf8))
            exit(1)
        }
    }
}
