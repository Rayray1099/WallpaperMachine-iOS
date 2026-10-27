// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Generates an opt-in published-plane package without rewriting image assets.
/// The contract is reverse engineered, not an Apple-supported streaming format.
enum TendiesPosterBoard27 {
    static func metadataFiles(for descriptor: TendiesWallpaperDescriptor,
                              includeDisplayNameMetadata: Bool) throws -> [TendiesFile] {
        var files = [
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
            TendiesFile(path: "\(descriptor.versionFolder)/com.apple.posterkit.provider.instance.renderingConfiguration.plist",
                        data: try renderingConfiguration()),
            TendiesFile(path: "\(descriptor.contentsFolder)/.com.apple.posterkit.provider.contents.configurableOptions.plist",
                        data: try configurableOptions())
        ]
        for (role, folder) in [("Background", descriptor.backgroundFolder),
                               ("Floating", descriptor.floatingFolder),
                               ("Foreground", descriptor.foregroundFolder)] {
            let caml = role == "Background" ? backgroundCAML(for: descriptor) : emptyCAML(for: descriptor, role: role)
            files.append(TendiesFile(path: "\(folder)/main.caml", data: Data(caml.utf8)))
            files.append(TendiesFile(path: "\(folder)/index.xml", data: Data(indexXML(for: descriptor, role: role).utf8)))
            files.append(TendiesFile(path: "\(folder)/assetManifest.caml", data: Data(TendiesManifest.assetManifestCAML.utf8)))
        }
        if includeDisplayNameMetadata {
            files.append(TendiesFile(
                path: "\(descriptor.contentsFolder)/com.apple.posterkit.provider.contents.otherMetadata.plist",
                data: try TendiesArchives.otherMetadata(displayName: descriptor.sanitizedName)))
        }
        return files
    }

    static func wallpaperPlist(for descriptor: TendiesWallpaperDescriptor) throws -> Data {
        let asset: [String: Any] = [
            "backgroundAnimationFileName": descriptor.backgroundBundleName,
            "floatingAnimationFileNameKey": descriptor.floatingBundleName,
            "foregroundAnimationFileName": descriptor.foregroundBundleName,
            "identifier": descriptor.identifier,
            "name": descriptor.sanitizedName,
            "type": "LayeredAnimation"
        ]
        return try PropertyListSerialization.data(fromPropertyList: [
            "appearanceAware": true,
            "assets": ["lockAndHome": ["default": asset]],
            "contentVersion": 1.01,
            "disableAdaptiveTime": true,
            "maximumAdaptiveTimeMultiplier": 2.0,
            "family": "Clownfish",
            "identifier": descriptor.identifier,
            "logicalScreenClass": descriptor.screenClass.name,
            "name": descriptor.sanitizedName,
            "preferredProminentColor": ["dark": descriptor.preferredColorDark,
                                        "default": descriptor.preferredColorDefault],
            "version": 1
        ], format: .binary, options: 0)
    }

    private static func rootAttributes(for descriptor: TendiesWallpaperDescriptor, role: String) -> String {
        // Layer bounds are points; CGImage dimensions stay pixels. Core Animation
        // fits the original bitmap without resampling it in the exporter. This
        // avoids an implicit extra backing-scale transform on a published plane.
        "id=\"\(role)\" name=\"\(role)\" anchorPoint=\"0 0\" position=\"0 0\" bounds=\"0 0 \(descriptor.screenClass.widthPoints) \(descriptor.screenClass.heightPoints)\" contentsScale=\"\(descriptor.screenClass.scale)\" contentsGravity=\"resizeAspectFill\" contentsFormat=\"RGBA8\" masksToBounds=\"1\" hidden=\"0\""
    }

    static func backgroundCAML(for descriptor: TendiesWallpaperDescriptor) -> String {
        let frames = (0..<descriptor.frameCount).map {
            "          <CGImage src=\"assets/\(descriptor.frameFileName(at: $0))\"/>"
        }.joined(separator: "\n")
        let duration = TendiesManifest.number(Double(descriptor.frameCount) / descriptor.frameRate)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer \(rootAttributes(for: descriptor, role: "Background"))>
            <contents type="CGImage" src="assets/\(descriptor.frameFileName(at: 0))"/>
            <animations>
              <animation type="CAKeyframeAnimation" calculationMode="linear" keyPath="contents" beginTime="1e-100" duration="\(duration)" removedOnCompletion="0" repeatCount="inf" repeatDuration="0" speed="1" timeOffset="0" autoreverses="0">
                <values>
        \(frames)
                </values>
              </animation>
            </animations>
          </CALayer>
        </caml>
        """
    }

    private static func emptyCAML(for descriptor: TendiesWallpaperDescriptor, role: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer \(rootAttributes(for: descriptor, role: role))><sublayers/></CALayer>
        </caml>
        """
    }

    static func indexXML(for descriptor: TendiesWallpaperDescriptor, role: String) -> String {
        let duration = TendiesManifest.number(Double(descriptor.frameCount) / descriptor.frameRate)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>\(descriptor.screenClass.heightPoints)</real>
          <key>documentWidth</key><real>\(descriptor.screenClass.widthPoints)</real>
          <key>documentResizesToView</key><false/>
          <key>geometryFlipped</key><false/>
          <key>loopEnd</key><real>\(duration)</real>
          <key>loopStart</key><real>0</real>
          <key>loopingEnabled</key><true/>
          <key>publishedObjectNames</key><array><string>\(role)</string></array>
          <key>rootDocument</key><string>main.caml</string>
          <key>scalesToFitInPlayer</key><true/>
          <key>unitsInPixelsInPlayer</key><false/>
        </dict></plist>
        """
    }

    private static func renderingObject(in archive: inout KeyedArchiveBuilder) -> [String: Int] {
        let recordClass = archive.addClass(["PRPosterRenderingConfiguration", "NSObject"])
        return archive.add(["$class": recordClass,
                            "motionEffectsDisabled": false, "depthEffectDisabled": false])
    }

    private static func renderingConfiguration() throws -> Data {
        var archive = KeyedArchiveBuilder()
        let root = renderingObject(in: &archive)
        return try archive.data(root: root)
    }

    private static func configurableOptions() throws -> Data {
        var archive = KeyedArchiveBuilder()
        let optionsClass = archive.addClass(["PRPosterConfigurableOptions", "NSObject"])
        let homeClass = archive.addClass(["PRPosterDescriptorHomeScreenConfiguration", "NSObject"])
        let arrayClass = archive.addClass(["NSArray", "NSObject"])
        let emptyArray = archive.add(["$class": arrayClass, "NS.objects": []] as [String: Any])
        let style = archive.add(0)
        let home = archive.add(["$class": homeClass, "preferredStyle": style,
                                "preferredSolidColors": archive.nullReference,
                                "preferredGradientColors": archive.nullReference,
                                "allowsModifyingLegibilityBlur": true] as [String: Any])
        let luminance = archive.add(0.5)
        let role = archive.add("PRPosterRoleLockScreen")
        let rendering = renderingObject(in: &archive)
        let root = archive.add(["$class": optionsClass,
                                "preferredHomeScreenConfiguration": home,
                                "ambientSupportedDataLayout": 0,
                                "displayNameLocalizationKey": archive.nullReference,
                                "luminance": luminance,
                                "role": role,
                                "preferredRenderingConfiguration": rendering,
                                "preferredTimeFontConfigurations": emptyArray,
                                "preferredTitleColors": emptyArray] as [String: Any])
        return try archive.data(root: root)
    }
}
