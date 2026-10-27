//
//  TendiesManifest.swift
//  WallpaperMachineIOS
//
//  Generates the PosterBoard `.tendies` descriptor tree for an image sequence.
//
//  Evidence (all inspected in .local references, summarised in docs/ios/EXPORT.md):
//  - mp4To.Tendies: ZIP root `descriptors/<UUID>/...`, versions/1/contents layout,
//    `Wallpaper.plist` keys, `logicalScreenClass` string, five-digit JPEG assets,
//    and the plist-style "ImageSequence" CAML document.
//  - AirCard-iOS (MIT): descriptor detection rules and providerInfo/userInfo shape.
//  - Nugget VideoCAML template: iPad screen class `810w-1080h@2x~ipad` and the
//    `<caml>` layered-animation document used for video wallpapers.
//  - Placard (GPL-3.0): a shipping video-to-tendies pipeline that writes the
//    animation to the background `.ca` bundle with a contents keyframe animation,
//    pixel-sized `index.xml`, and a blank floating bundle.
//  - Poster-Lab (MIT): keyed-archive shape for providerInfo/otherMetadata and the
//    minimal assetManifest.
//
//  No code or binary template asset from those projects is reproduced here: the
//  structures are reimplemented from their observable format and the generated
//  files contain only user data and independently written XML.
//

import Foundation

/// How the frame sequence is expressed in the animation bundle's `main.caml`.
public enum TendiesAnimationEncoding: String, Codable, CaseIterable, Sendable {
    /// `<caml>` document with a CGImage-contents keyframe animation. This mirrors a
    /// shipping video-to-tendies app and is the default.
    case contentsKeyframe
    /// Plist-style CAML whose layer contents use the private `ImageSequence` type.
    /// Mirrors the mp4To.Tendies reference implementation.
    case imageSequence
}

/// Package contract, independent of frame resolution, rate and animation encoding.
public enum TendiesPackageLayout: String, Codable, CaseIterable, Sendable {
    case legacy
    /// Published logical-space planes and matching PosterKit configuration.
    /// Opt-in until verified by the target CollectionsPoster consumer.
    case posterBoard27
}

public struct TendiesFile: Hashable, Sendable {
    /// Forward-slash path relative to the archive root.
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

public enum TendiesManifestError: Error, Equatable, CustomStringConvertible {
    case invalidDisplayName(String)
    case invalidIdentifier(Int)
    case invalidFrameCount(Int)
    case invalidFrameRate(Double)
    case invalidPixelSize(PixelSize)
    case invalidScreenClass(TendiesScreenClass)
    case frameCountExceedsArchiveCapacity(Int, Int)
    case unsupportedAnimationEncoding(TendiesAnimationEncoding, TendiesPackageLayout)

    public var description: String {
        switch self {
        case .invalidDisplayName(let value):
            return "The wallpaper name is empty after removing invalid characters (\(value.debugDescription))."
        case .invalidIdentifier(let value):
            return "The wallpaper identifier must be a positive integer (received \(value))."
        case .invalidFrameCount(let value):
            return "The frame count must be at least 1 (received \(value))."
        case .invalidFrameRate(let value):
            return "The frame rate must be positive (received \(value))."
        case .invalidPixelSize(let size):
            return "The frame size must be positive (received \(size))."
        case .invalidScreenClass(let screenClass):
            return "Invalid PosterBoard screen class: \(screenClass.name)."
        case .frameCountExceedsArchiveCapacity(let count, let capacity):
            return "\(count) frames do not fit in a .tendies archive (ZIP32 supports \(capacity) entries including the manifest)."
        case .unsupportedAnimationEncoding(let encoding, let layout):
            return "The \(encoding.rawValue) animation encoding is not supported by the \(layout.rawValue) package layout."
        }
    }
}

public struct TendiesWallpaperDescriptor: Hashable, Sendable {
    public var screenClass: TendiesScreenClass
    /// User-visible name; sanitised for file and bundle names.
    public var displayName: String
    /// PosterBoard wallpaper family. The inspected templates use "Chip".
    public var family: String
    /// Positive identifier shared by Wallpaper.plist and contents.userInfo.
    public var identifier: Int
    /// Rendered frame pixel size. Usually screenClass.pixelSize, but resolution is
    /// independently configurable so exports can be smaller or larger.
    public var pixelSize: PixelSize
    public var frameCount: Int
    public var frameRate: Double
    public var animationEncoding: TendiesAnimationEncoding
    public var packageLayout: TendiesPackageLayout
    public var descriptorUUID: UUID
    public var createdAt: Date
    public var preferredColorDark: String
    public var preferredColorDefault: String

    public init(
        screenClass: TendiesScreenClass,
        displayName: String,
        family: String = "Chip",
        identifier: Int,
        pixelSize: PixelSize,
        frameCount: Int,
        frameRate: Double,
        animationEncoding: TendiesAnimationEncoding = .contentsKeyframe,
        packageLayout: TendiesPackageLayout = .legacy,
        descriptorUUID: UUID = UUID(),
        createdAt: Date = Date(),
        preferredColorDark: String = "#000000",
        preferredColorDefault: String = "#FFFFFF"
    ) {
        self.screenClass = screenClass
        self.displayName = displayName
        self.family = family
        self.identifier = identifier
        self.pixelSize = pixelSize
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.animationEncoding = animationEncoding
        self.packageLayout = packageLayout
        self.descriptorUUID = descriptorUUID
        self.createdAt = createdAt
        self.preferredColorDark = preferredColorDark
        self.preferredColorDefault = preferredColorDefault
    }

    /// Name used for the `.wallpaper` bundle, e.g. `MyWallpaper-810w-1080h@2x~ipad.wallpaper`.
    public var wallpaperFolderName: String { "\(bundleStem)-\(screenClass.name).wallpaper" }
    public var backgroundBundleName: String { "\(bundleStem)_Background-\(screenClass.name).ca" }
    public var floatingBundleName: String { "\(bundleStem)_Floating-\(screenClass.name).ca" }
    public var foregroundBundleName: String { "\(bundleStem)_Foreground-\(screenClass.name).ca" }

    private var bundleStem: String {
        packageLayout == .posterBoard27 ? "\(identifier).Clownfish" : sanitizedName
    }

    public var sanitizedName: String { ExportNaming.sanitized(displayName) }
    public var sanitizedFamily: String { ExportNaming.sanitized(family, fallback: "Chip") }

    public var descriptorFolder: String { "descriptors/\(descriptorUUID.uuidString.uppercased())" }
    public var versionFolder: String { "\(descriptorFolder)/versions/1" }
    public var contentsFolder: String { "\(versionFolder)/contents" }
    public var wallpaperFolder: String { "\(contentsFolder)/\(wallpaperFolderName)" }
    public var backgroundFolder: String { "\(wallpaperFolder)/\(backgroundBundleName)" }
    public var floatingFolder: String { "\(wallpaperFolder)/\(floatingBundleName)" }
    public var foregroundFolder: String { "\(wallpaperFolder)/\(foregroundBundleName)" }
    public var backgroundAssetsFolder: String { "\(backgroundFolder)/assets" }

    /// Digits in the generated frame file names. At least five (matching the
    /// reference implementation) and wider automatically for long sequences, so
    /// there is no artificial frame ceiling below the archive format limit.
    public var frameNameDigits: Int {
        let highestIndex = max(0, frameCount - 1)
        return max(5, String(highestIndex).count)
    }

    public func frameFileName(at index: Int) -> String {
        let number = String(index)
        let padding = String(repeating: "0", count: max(0, frameNameDigits - number.count))
        return "\(padding)\(number).jpg"
    }

    public func frameMemberPath(at index: Int) -> String {
        "\(backgroundAssetsFolder)/\(frameFileName(at: index))"
    }

    /// printf pattern understood by the ImageSequence layer.
    public var imageNamePattern: String {
        "assets/%0\(frameNameDigits)d.jpg"
    }

    public func validated() throws -> TendiesWallpaperDescriptor {
        guard !sanitizedName.isEmpty else {
            throw TendiesManifestError.invalidDisplayName(displayName)
        }
        guard identifier > 0 else {
            throw TendiesManifestError.invalidIdentifier(identifier)
        }
        guard frameCount >= 1 else {
            throw TendiesManifestError.invalidFrameCount(frameCount)
        }
        guard frameRate > 0, frameRate.isFinite else {
            throw TendiesManifestError.invalidFrameRate(frameRate)
        }
        guard pixelSize.isPositive else {
            throw TendiesManifestError.invalidPixelSize(pixelSize)
        }
        guard screenClass.isValid else {
            throw TendiesManifestError.invalidScreenClass(screenClass)
        }
        guard packageLayout != .posterBoard27 || animationEncoding == .contentsKeyframe else {
            throw TendiesManifestError.unsupportedAnimationEncoding(animationEncoding, packageLayout)
        }
        // Reserve all metadata, including the optional display-name record. The
        // modern contract adds a third plane and two configuration archives.
        let capacity = ZipArchiveWriter.maximumEntryCount - (packageLayout == .posterBoard27 ? 17 : 12)
        guard frameCount <= capacity else {
            throw TendiesManifestError.frameCountExceedsArchiveCapacity(frameCount, ZipArchiveWriter.maximumEntryCount)
        }
        return self
    }
}

public enum TendiesManifest {
    /// Files that can be generated before any frame is rendered. The exporter
    /// writes the JPEG assets separately so memory stays bounded.
    public static func metadataFiles(
        for descriptor: TendiesWallpaperDescriptor,
        includeDisplayNameMetadata: Bool = true
    ) throws -> [TendiesFile] {
        let descriptor = try descriptor.validated()

        if descriptor.packageLayout == .posterBoard27 {
            return try TendiesPosterBoard27.metadataFiles(
                for: descriptor, includeDisplayNameMetadata: includeDisplayNameMetadata)
        }

        var files: [TendiesFile] = [
            TendiesFile(path: "\(descriptor.descriptorFolder)/com.apple.posterkit.role.identifier",
                        data: Data("PRPosterRoleLockScreen".utf8)),
            TendiesFile(path: "\(descriptor.descriptorFolder)/com.apple.posterkit.provider.descriptor.identifier",
                        data: Data(String(descriptor.identifier).utf8)),
            TendiesFile(path: "\(descriptor.descriptorFolder)/providerInfo.plist",
                        data: try TendiesArchives.providerInfo(date: descriptor.createdAt)),
            TendiesFile(path: "\(descriptor.contentsFolder)/com.apple.posterkit.provider.contents.userInfo",
                        data: try TendiesArchives.userInfo(wallpaperFileName: descriptor.wallpaperFolderName,
                                                           identifier: descriptor.identifier)),
            TendiesFile(path: "\(descriptor.wallpaperFolder)/Wallpaper.plist",
                        data: try wallpaperPlist(for: descriptor)),
            TendiesFile(path: "\(descriptor.backgroundFolder)/main.caml",
                        data: Data(backgroundCAML(for: descriptor).utf8)),
            TendiesFile(path: "\(descriptor.backgroundFolder)/index.xml",
                        data: Data(backgroundIndexXML(for: descriptor).utf8)),
            TendiesFile(path: "\(descriptor.backgroundFolder)/assetManifest.caml",
                        data: Data(assetManifestCAML.utf8)),
            TendiesFile(path: "\(descriptor.floatingFolder)/main.caml",
                        data: Data(floatingCAML.utf8)),
            TendiesFile(path: "\(descriptor.floatingFolder)/index.xml",
                        data: Data(floatingIndexXML.utf8)),
            TendiesFile(path: "\(descriptor.floatingFolder)/assetManifest.caml",
                        data: Data(assetManifestCAML.utf8))
        ]

        if includeDisplayNameMetadata {
            files.append(TendiesFile(
                path: "\(descriptor.contentsFolder)/com.apple.posterkit.provider.contents.otherMetadata.plist",
                data: try TendiesArchives.otherMetadata(displayName: descriptor.sanitizedName)))
        }

        return files
    }

    // MARK: - Wallpaper.plist

    public static func wallpaperPlist(for descriptor: TendiesWallpaperDescriptor) throws -> Data {
        if descriptor.packageLayout == .posterBoard27 {
            return try TendiesPosterBoard27.wallpaperPlist(for: descriptor)
        }
        let defaultAsset: [String: Any] = [
            "backgroundAnimationFileName": descriptor.backgroundBundleName,
            "floatingAnimationFileNameKey": descriptor.floatingBundleName,
            "identifier": descriptor.identifier,
            "name": descriptor.sanitizedName,
            "type": "LayeredAnimation"
        ]
        let plist: [String: Any] = [
            "appearanceAware": true,
            "assets": [
                "lockAndHome": [
                    "default": defaultAsset
                ]
            ],
            "contentVersion": 2.01,
            "family": descriptor.sanitizedFamily,
            "identifier": descriptor.identifier,
            "logicalScreenClass": descriptor.screenClass.name,
            "name": descriptor.sanitizedName,
            "preferredProminentColor": [
                "dark": descriptor.preferredColorDark,
                "default": descriptor.preferredColorDefault
            ],
            "version": 1
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    // MARK: - CAML documents

    public static func backgroundCAML(for descriptor: TendiesWallpaperDescriptor) -> String {
        if descriptor.packageLayout == .posterBoard27 {
            return TendiesPosterBoard27.backgroundCAML(for: descriptor)
        }
        switch descriptor.animationEncoding {
        case .contentsKeyframe:
            return contentsKeyframeCAML(for: descriptor)
        case .imageSequence:
            return imageSequenceCAML(for: descriptor)
        }
    }

    /// `<caml>` layered animation with a CGImage-contents keyframe animation.
    private static func contentsKeyframeCAML(for descriptor: TendiesWallpaperDescriptor) -> String {
        let width = Double(descriptor.pixelSize.width)
        let height = Double(descriptor.pixelSize.height)
        let centerX = width / 2
        let centerY = height / 2
        let duration = Double(descriptor.frameCount) / descriptor.frameRate
        // Each layer maps its local origin into the parent's origin:
        // parentPoint = position + localPoint - boundsOrigin - anchor * boundsSize.
        // The root uses a zero anchor; the wrapper and image use explicit centre
        // anchors/positions. An omitted wrapper position shifts the entire image
        // by -width/2, -height/2 even though its child is correctly centred.
        let frames = (0..<descriptor.frameCount)
            .map { "        <CGImage src=\"assets/\(descriptor.frameFileName(at: $0))\"/>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Generated by WallpaperMachineIOS export. User-owned content only. -->
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" anchorPoint="0 0" bounds="0 0 \(number(width)) \(number(height))" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_BACKGROUND" position="0 0">
            <sublayers>
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" anchorPoint="0.5 0.5" bounds="0 0 \(number(width)) \(number(height))" contentsFormat="RGBA8" cornerCurve="circular" name="\(descriptor.sanitizedName)" position="\(number(centerX)) \(number(centerY))">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" anchorPoint="0.5 0.5" bounds="0 0 \(number(width)) \(number(height))" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer1" position="\(number(centerX)) \(number(centerY))">
                    <contents type="CGImage" src="assets/\(descriptor.frameFileName(at: 0))"/>
                    <animations>
                      <animation type="CAKeyframeAnimation" calculationMode="linear" keyPath="contents" beginTime="1e-100" duration="\(number(duration))" removedOnCompletion="0" repeatCount="inf" repeatDuration="0" speed="1" timeOffset="0" autoreverses="0">
                        <values>
        \(frames)
                        </values>
                      </animation>
                    </animations>
                  </CALayer>
                </sublayers>
              </CATransformLayer>
            </sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    /// Plist-style CAML using the ImageSequence contents type (mp4To.Tendies).
    private static func imageSequenceCAML(for descriptor: TendiesWallpaperDescriptor) -> String {
        let width = descriptor.pixelSize.width
        let height = descriptor.pixelSize.height
        let centerX = Double(width) / 2
        let centerY = Double(height) / 2
        let frameDuration = 1.0 / descriptor.frameRate
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>view</key>
            <dict>
                <key>backgroundColor</key>
                <string>0 0 0 0</string>
                <key>drawsAsynchronously</key>
                <false/>
                <key>sublayers</key>
                <array>
                    <dict>
                        <key>bounds</key>
                        <string>{{0, 0}, {\(width), \(height)}}</string>
                        <key>contents</key>
                        <dict>
                            <key>initialImage</key>
                            <string>assets/\(descriptor.frameFileName(at: 0))</string>
                            <key>frameDuration</key>
                            <real>\(number(frameDuration))</real>
                            <key>frameCount</key>
                            <integer>\(descriptor.frameCount)</integer>
                            <key>imageFormat</key>
                            <string>jpg</string>
                            <key>imageNamePattern</key>
                            <string>\(descriptor.imageNamePattern)</string>
                            <key>loop</key>
                            <true/>
                            <key>type</key>
                            <string>ImageSequence</string>
                        </dict>
                        <key>name</key>
                        <string>ContentLayer</string>
                        <key>position</key>
                        <string>{{\(number(centerX)), \(number(centerY))}}</string>
                        <key>type</key>
                        <string>CALayer</string>
                    </dict>
                </array>
            </dict>
        </dict>
        </plist>
        """
    }

    public static let assetManifestCAML = """
    <?xml version="1.0" encoding="UTF-8"?>

    <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
      <MicaAssetManifest>
        <modules type="NSArray"/>
      </MicaAssetManifest>
    </caml>
    """

    public static let floatingCAML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
      <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" anchorPoint="0 0" bounds="0 0 3176 3176" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_BACKGROUND" position="0 0">
        <sublayers/>
        <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
        <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
      </CALayer>
    </caml>
    """

    /// Background animation index. Pixel-sized document with the player treating
    /// units as pixels, matching the shipping video template.
    public static func backgroundIndexXML(for descriptor: TendiesWallpaperDescriptor) -> String {
        if descriptor.packageLayout == .posterBoard27 {
            return TendiesPosterBoard27.indexXML(for: descriptor, role: "Background")
        }
        let width = descriptor.pixelSize.width
        let height = descriptor.pixelSize.height
        let duration = Double(descriptor.frameCount) / descriptor.frameRate
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>\(height)</real>
          <key>documentResizesToView</key><true/>
          <key>documentWidth</key><real>\(width)</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>\(number(duration))</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><true/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><true/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }

    public static let floatingIndexXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>assetManifest</key><string>assetManifest.caml</string>
      <key>documentHeight</key><real>3176</real>
      <key>documentResizesToView</key><false/>
      <key>documentWidth</key><real>3176</real>
      <key>dynamicGuidesEnabled</key><true/>
      <key>geometryFlipped</key><false/>
      <key>guidesEnabled</key><true/>
      <key>interactiveMouseEventsEnabled</key><true/>
      <key>interactiveShowsCursor</key><true/>
      <key>interactiveTouchEventsEnabled</key><false/>
      <key>loopEnd</key><real>0.0</real>
      <key>loopStart</key><real>0.0</real>
      <key>loopingEnabled</key><false/>
      <key>multitouchDisablesMouse</key><false/>
      <key>multitouchEnabled</key><false/>
      <key>presentationMouseEventsEnabled</key><true/>
      <key>presentationShowsCursor</key><true/>
      <key>presentationTouchEventsEnabled</key><false/>
      <key>rootDocument</key><string>main.caml</string>
      <key>savesWindowFrame</key><false/>
      <key>scalesToFitInPlayer</key><false/>
      <key>showsTouches</key><true/>
      <key>snappingEnabled</key><true/>
      <key>timelineMarkers</key><string>[(null)]</string>
      <key>touchesColor</key><string>1 1 0 0.8</string>
      <key>unitsInPixelsInPlayer</key><true/>
    </dict></plist>
    """

    // MARK: - Number formatting

    /// Stable decimal formatting for CAML/XML: integers without a decimal point,
    /// fractions with up to six digits and no exponent.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e12 {
            return String(format: "%.0f", value)
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
