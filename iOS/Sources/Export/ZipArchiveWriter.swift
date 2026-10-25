//
//  ZipArchiveWriter.swift
//  WallpaperMachineIOS
//
//  Minimal ZIP writer used by the `.tendies` exporter.
//
//  Why not NSFileCoordinator(.forUploading) or an external archive library?
//  - the export core has to be testable without an Apple SDK;
//  - `.tendies` frames are JPEG files (already compressed), so ZIP "store" is the
//    right method and produces archives every unzip implementation can read;
//  - no third-party dependency and no licensing question.
//
//  Limits are the ZIP32 format limits, not product caps: at most 65535 entries and
//  offsets/entry sizes below 4 GiB. The tendies exporter turns either into a clear
//  error. Every frame is streamed to the output handle, so memory stays bounded by
//  one frame.
//

import Foundation

public final class ZipArchiveWriter {
    public enum ZipError: Error, Equatable, CustomStringConvertible {
        case cannotCreateArchive(String)
        case entryLimitExceeded(Int)
        case archiveTooLarge
        case invalidEntryName(String)
        case alreadyFinished
        case writeFailed(String)

        public var description: String {
            switch self {
            case .cannotCreateArchive(let reason):
                return "Cannot create the archive: \(reason)"
            case .entryLimitExceeded(let limit):
                return "The archive would need more than \(limit) entries, which the ZIP format used by .tendies does not support."
            case .archiveTooLarge:
                return "The archive would exceed the 4 GiB ZIP32 limit for a .tendies file."
            case .invalidEntryName(let name):
                return "Invalid archive entry name: \(name)"
            case .alreadyFinished:
                return "The archive has already been finished."
            case .writeFailed(let reason):
                return "Cannot write the archive: \(reason)"
            }
        }
    }

    private struct Entry {
        let name: String
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    public static let maximumEntryCount = 65_535

    private let outputURL: URL
    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private var finished = false

    public init(outputURL: URL) throws {
        self.outputURL = outputURL
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw ZipError.cannotCreateArchive("cannot create \(outputURL.lastPathComponent)")
        }
        do {
            self.handle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw ZipError.cannotCreateArchive(error.localizedDescription)
        }
    }

    deinit {
        if !finished {
            try? handle.close()
        }
    }

    /// Adds one file. `path` is a forward-slash relative member name, e.g.
    /// `descriptors/<uuid>/providerInfo.plist`.
    public func addFile(path: String, data: Data, modified: Date = Date()) throws {
        guard !finished else { throw ZipError.alreadyFinished }
        let name = try Self.validatedName(path)
        guard entries.count < Self.maximumEntryCount else {
            throw ZipError.entryLimitExceeded(Self.maximumEntryCount)
        }
        guard data.count <= Int(UInt32.max) else { throw ZipError.archiveTooLarge }
        guard offset <= UInt64(UInt32.max) else { throw ZipError.archiveTooLarge }

        let nameData = Data(name.utf8)
        guard nameData.count <= Int(UInt16.max) else { throw ZipError.invalidEntryName(path) }

        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        let entryOffset = UInt32(offset)
        let (dosTime, dosDate) = Self.dosDateTime(modified)

        var header = Data()
        header.appendUInt32(0x0403_4B50)      // local file header signature
        header.appendUInt16(20)               // version needed to extract (2.0)
        header.appendUInt16(0x0800)           // UTF-8 file name flag
        header.appendUInt16(0)                // method: store
        header.appendUInt16(dosTime)
        header.appendUInt16(dosDate)
        header.appendUInt32(crc)
        header.appendUInt32(size)             // compressed size
        header.appendUInt32(size)             // uncompressed size
        header.appendUInt16(UInt16(nameData.count))
        header.appendUInt16(0)                // extra field length

        try write(header)
        try write(nameData)
        try write(data)

        entries.append(Entry(name: name, crc32: crc, size: size, offset: entryOffset,
                             dosTime: dosTime, dosDate: dosDate))
    }

    /// Writes the central directory and end record, closes the file and returns it.
    @discardableResult
    public func finish() throws -> URL {
        guard !finished else { throw ZipError.alreadyFinished }
        let centralDirectoryOffset = UInt32(offset)

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            var central = Data()
            central.appendUInt32(0x0201_4B50)  // central directory header signature
            central.appendUInt16(0x0314)       // version made by (Unix, 2.0)
            central.appendUInt16(20)           // version needed
            central.appendUInt16(0x0800)       // UTF-8 flag
            central.appendUInt16(0)            // method: store
            central.appendUInt16(entry.dosTime)
            central.appendUInt16(entry.dosDate)
            central.appendUInt32(entry.crc32)
            central.appendUInt32(entry.size)
            central.appendUInt32(entry.size)
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)            // extra length
            central.appendUInt16(0)            // comment length
            central.appendUInt16(0)            // disk number start
            central.appendUInt16(0)            // internal attributes
            central.appendUInt32(UInt32(0o100644) << 16) // external attributes: regular file, 0644
            central.appendUInt32(entry.offset)
            try write(central)
            try write(nameData)
        }

        let centralDirectorySize = UInt32(offset) - centralDirectoryOffset

        var end = Data()
        end.appendUInt32(0x0605_4B50)          // end of central directory signature
        end.appendUInt16(0)                    // this disk
        end.appendUInt16(0)                    // disk with central directory
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(centralDirectorySize)
        end.appendUInt32(centralDirectoryOffset)
        end.appendUInt16(0)                    // comment length
        try write(end)

        try handle.synchronize()
        try handle.close()
        finished = true
        return outputURL
    }

    /// Closes the output without writing a central directory. Used when an export
    /// is cancelled so the partial file can be removed.
    public func abort() {
        guard !finished else { return }
        try? handle.close()
        finished = true
    }

    // MARK: - Helpers

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ZipError.writeFailed(error.localizedDescription)
        }
        offset += UInt64(data.count)
    }

    private static func validatedName(_ raw: String) throws -> String {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        while name.hasPrefix("/") { name.removeFirst() }
        guard !name.isEmpty,
              !name.contains("\0"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ZipError.invalidEntryName(raw)
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ZipError.invalidEntryName(raw)
        }
        return name
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(1980, parts.year ?? 1980), 2107)
        let month = min(max(1, parts.month ?? 1), 12)
        let day = min(max(1, parts.day ?? 1), 31)
        let hour = min(max(0, parts.hour ?? 0), 23)
        let minute = min(max(0, parts.minute ?? 0), 59)
        let second = min(max(0, parts.second ?? 0), 59)
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
        return (dosTime, dosDate)
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
