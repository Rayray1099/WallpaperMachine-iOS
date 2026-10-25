//
//  ExportDevice.swift
//  WallpaperMachineIOS
//
//  Device metrics used to derive default export resolutions and PosterBoard
//  screen classes. Kept in the Export module so the exporter has no dependency on
//  the library/UI layers.
//

import Foundation
import UIKit

public enum ExportDevice {
    public struct Metrics: Sendable, Equatable {
        /// Native portrait pixel size of the current screen.
        public let pixelSize: PixelSize
        /// PosterBoard screen class for the current screen (logical points).
        public let screenClass: TendiesScreenClass
        public let isPad: Bool

        public init(pixelSize: PixelSize, screenClass: TendiesScreenClass, isPad: Bool) {
            self.pixelSize = pixelSize
            self.screenClass = screenClass
            self.isPad = isPad
        }
    }

    /// Reads the screen of the first connected window scene. `UIScreen.main` is
    /// only used as a fallback because it is deprecated for multi-window apps.
    @MainActor
    public static var metrics: Metrics {
        let screen: UIScreen
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen {
            screen = scene
        } else {
            screen = UIScreen.main
        }

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let idiom: TendiesScreenClass.Idiom = isPad ? .pad : .phone
        let canonicalScale = idiom.canonicalScale

        var native = screen.nativeBounds.size
        if native.width <= 0 || native.height <= 0 {
            native = CGSize(width: 1620, height: 2160)
        }
        var widthPoints = Int((native.width / CGFloat(canonicalScale)).rounded())
        var heightPoints = Int((native.height / CGFloat(canonicalScale)).rounded())
        if widthPoints > heightPoints { swap(&widthPoints, &heightPoints) }
        if widthPoints <= 0 || heightPoints <= 0 {
            widthPoints = 810
            heightPoints = 1080
        }

        let screenClass = TendiesScreenClass(widthPoints: widthPoints,
                                             heightPoints: heightPoints,
                                             scale: canonicalScale,
                                             idiom: idiom)
        return Metrics(pixelSize: screenClass.pixelSize, screenClass: screenClass, isPad: isPad)
    }

    @MainActor
    public static var screenPixelSize: PixelSize { metrics.pixelSize }

    @MainActor
    public static var screenClass: TendiesScreenClass { metrics.screenClass }
}

public enum WallpaperExportLocation {
    /// User-visible exports live in Documents/Exports so Files.app and the share
    /// sheet can reach them.
    public static func exportsDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        let directory = documents.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A per-export temporary directory for staged frames.
    public static func temporaryWorkingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Returns a URL that does not exist yet, suffixing `-2`, `-3`, ... as needed.
    public static func uniqueFileURL(baseName: String, fileExtension: String, in directory: URL) -> URL {
        let safeBase = ExportNaming.sanitized(baseName, fallback: "Wallpaper")
        var candidate = directory.appendingPathComponent("\(safeBase).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeBase)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }

    public static func uniqueDirectoryURL(baseName: String, in directory: URL) -> URL {
        let safeBase = ExportNaming.sanitized(baseName, fallback: "Wallpaper")
        var candidate = directory.appendingPathComponent(safeBase, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeBase)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    public static func byteSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url,
                                                           includingPropertiesForKeys: Array(keys),
                                                           options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let fileValues = try? fileURL.resourceValues(forKeys: keys)
                if fileValues?.isRegularFile == true {
                    total += Int64(fileValues?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
