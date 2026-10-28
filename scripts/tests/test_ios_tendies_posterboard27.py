#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Execute the real portable exporter; inspect plists, archives, XML and ZIPs.

These are package-contract tests, not PosterBoard decoding or device playback proof.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
NS = "{http://www.apple.com/CoreAnimation/1.0}"
UUID = "12345678-1234-5678-9ABC-123456789ABC"
SCREEN = "834w-1210h@2x~ipad"
OTHER = "com.apple.posterkit.provider.contents.otherMetadata.plist"
CONFIG = ".com.apple.posterkit.provider.contents.configurableOptions.plist"
RENDERING = "com.apple.posterkit.provider.instance.renderingConfiguration.plist"
SUGGESTION = "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist"
BINARY_MODERN_SUFFIXES = (
    "providerInfo.plist",
    "otherMetadata.plist",
    "renderingConfiguration.plist",
    "configurableOptions.plist",
    "suggestionMetadata.plist",
)

# Captured from the pre-layout production implementation with the fixed descriptor
# in the Swift runner. Exact text bytes are stable; Foundation dictionary order is
# not, so the plist snapshots below deliberately compare semantic values instead.
LEGACY_TEXT_SHA256 = {
    "Background/assetManifest.caml": "02c7e5af229d8e5d731574e3017a24fa597ce120e58d72f9942c9b938a9d2ba0",
    "Background/index.xml": "fd6d57c0b7c655541de4b0b7d7c4622825f8fbea4bbed31477dd5b5f850af074",
    "Background/main.caml": "127f81eabf6793d583bc11e572fc172a22f330caae996e862c0909c1131e6600",
    "Floating/assetManifest.caml": "02c7e5af229d8e5d731574e3017a24fa597ce120e58d72f9942c9b938a9d2ba0",
    "Floating/index.xml": "e19790661f12d36c3a8cd11c6ca2aa36dfc5863ea678f100117b0a5e0932989a",
    "Floating/main.caml": "82120dedef8827f18c473b6ac93e5d1d733c47298ef248689cf0b86db0c285a8",
}


def read_members(folder):
    return {path.relative_to(folder).as_posix(): path.read_bytes()
            for path in folder.rglob("*") if path.is_file()}


def decode_archive(data):
    """Resolve the serialized object graph, checking UID bounds and class records."""
    archive = plistlib.loads(data)
    if archive.get("$archiver") != "NSKeyedArchiver" or archive.get("$version") != 100000:
        raise AssertionError("Not an NSKeyedArchiver object graph")
    objects = archive["$objects"]
    if not objects or objects[0] != "$null":
        raise AssertionError("Missing archive null sentinel")

    def resolve(value, seen=frozenset()):
        if isinstance(value, plistlib.UID):
            index = value.data
        elif isinstance(value, dict) and set(value) == {"CF$UID"}:
            index = value["CF$UID"]
        else:
            if isinstance(value, list):
                return [resolve(item, seen) for item in value]
            if not isinstance(value, dict):
                return value
            if "$class" in value:
                record = resolve(value["$class"], seen)
                if record["$classname"] != record["$classes"][0] or "NSObject" not in record["$classes"]:
                    raise AssertionError("Invalid archive class hierarchy")
                name = record["$classname"]
                if name in ("NSDictionary", "NSMutableDictionary"):
                    keys = resolve(value["NS.keys"], seen)
                    values = resolve(value["NS.objects"], seen)
                    if len(keys) != len(values) or len(set(keys)) != len(keys):
                        raise AssertionError("Invalid dictionary archive")
                    return dict(zip(keys, values))
                if name == "NSArray":
                    return resolve(value["NS.objects"], seen)
                return {"_class": name, **{key: resolve(item, seen) for key, item in value.items()
                                           if key != "$class"}}
            return {key: resolve(item, seen) for key, item in value.items()}
        if type(index) is not int or not 0 <= index < len(objects) or index in seen:
            raise AssertionError("Dangling or cyclic archive UID")
        return None if index == 0 else resolve(objects[index], seen | {index})

    # Validate unused objects as well: a valid root must not hide a corrupt graph.
    for item in objects[1:]:
        resolve(item)
    return resolve(archive["$top"]["root"])


class TendiesPosterBoard27Tests(unittest.TestCase):
    def assert_binary_uid_graph(self, data):
        self.assertTrue(data.startswith(b"bplist00"), "suggestion archive is not binary")
        archive = plistlib.loads(data)
        self.assertEqual(archive.get("$archiver"), "NSKeyedArchiver")
        self.assertEqual(archive.get("$version"), 100000)
        objects = archive.get("$objects")
        self.assertIsInstance(objects, list)
        self.assertTrue(objects and objects[0] == "$null")

        def visit(value):
            if isinstance(value, plistlib.UID):
                self.assertGreaterEqual(value.data, 0)
                self.assertLess(value.data, len(objects))
                return
            if isinstance(value, dict):
                self.assertNotEqual(set(value), {"CF$UID"},
                                    "binary archive contains an XML CF$UID dictionary")
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)

        visit(archive)

    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("swiftc")
        if compiler is None:
            raise unittest.SkipTest("swiftc is not installed")
        compiler = str(Path(compiler).resolve())
        environment = os.environ.copy()
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        temporary = tempfile.TemporaryDirectory(prefix="wm-tendies27-test-")
        cls.addClassCleanup(temporary.cleanup)
        cls.output = Path(temporary.name) / "fixtures"
        executable = Path(temporary.name) / ("tendies27.exe" if os.name == "nt" else "tendies27")
        sources = ("ExportGeometry", "WallpaperExportSettings", "TendiesScreenClass", "TendiesManifest",
                   "TendiesPosterBoard27", "KeyedArchiveBuilder", "ZipArchiveWriter")
        command = [compiler, "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                   *(str(ROOT / "iOS/Sources/Export" / (name + ".swift")) for name in sources),
                   str(ROOT / "scripts/ios/test_tendies_posterboard27.swift"), "-o", str(executable)]
        compiled = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                  errors="replace", env=environment, timeout=120)
        if compiled.returncode != 0:
            raise AssertionError(compiled.stdout + compiled.stderr)
        result = subprocess.run([str(executable), str(cls.output)], capture_output=True, text=True,
                                encoding="utf-8", errors="replace", env=environment, timeout=60)
        if result.returncode != 0 or "PASS: TendiesPosterBoard27" not in result.stdout:
            raise AssertionError(result.stdout + result.stderr)
        cls.fixtures = {row["name"]: row for row in json.loads((cls.output / "fixtures.json").read_text())}

    def members(self, name):
        return read_members(self.output / name)

    def test_legacy_exact_text_and_semantic_plist_snapshots(self):
        descriptor = f"descriptors/{UUID}"
        contents = f"{descriptor}/versions/1/contents"
        wallpaper = f"Synthetic Geometry-{SCREEN}.wallpaper"
        base = f"{contents}/{wallpaper}"
        expected = {
            f"{descriptor}/com.apple.posterkit.role.identifier": b"PRPosterRoleLockScreen",
            f"{descriptor}/com.apple.posterkit.provider.descriptor.identifier": b"12345",
        }
        user_info = {"wallpaperRepresentingFileName": wallpaper,
                     "wallpaperRepresentingIdentifier": "12345", "posterEnvironmentOverrides": b"{}"}
        wallpaper_plist = {
            "version": 1, "name": "Synthetic Geometry", "identifier": 12345, "contentVersion": 2.01,
            "preferredProminentColor": {"default": "#FFFFFF", "dark": "#000000"},
            "family": "Chip", "appearanceAware": True, "logicalScreenClass": SCREEN,
            "assets": {"lockAndHome": {"default": {
                "identifier": 12345, "name": "Synthetic Geometry", "type": "LayeredAnimation",
                "floatingAnimationFileNameKey": f"Synthetic Geometry_Floating-{SCREEN}.ca",
                "backgroundAnimationFileName": f"Synthetic Geometry_Background-{SCREEN}.ca"}}},
        }
        for name in ("legacy", "explicit-legacy"):
            with self.subTest(fixture=name):
                members = self.members(name)
                paths = set(expected) | {f"{descriptor}/providerInfo.plist", f"{contents}/{OTHER}",
                                         f"{contents}/com.apple.posterkit.provider.contents.userInfo",
                                         f"{base}/Wallpaper.plist"}
                for suffix, digest in LEGACY_TEXT_SHA256.items():
                    role, filename = suffix.split("/")
                    path = f"{base}/Synthetic Geometry_{role}-{SCREEN}.ca/{filename}"
                    paths.add(path)
                    self.assertEqual(hashlib.sha256(members[path]).hexdigest(), digest, path)
                self.assertEqual(set(members), paths)
                for path, value in expected.items():
                    self.assertEqual(members[path], value)
                self.assertEqual(plistlib.loads(members[f"{base}/Wallpaper.plist"]), wallpaper_plist)
                self.assertEqual(plistlib.loads(members[f"{contents}/com.apple.posterkit.provider.contents.userInfo"]), user_info)
                self.assertEqual(decode_archive(members[f"{descriptor}/providerInfo.plist"]), {
                    "kConfigurationLastUseDateKey": {"_class": "NSDate", "NS.time": 123456789.0}})
                self.assertEqual(decode_archive(members[f"{contents}/{OTHER}"]), {
                    "_class": "PRPosterMetadata", "displayNameLocalizationKey": "Synthetic Geometry"})

    def test_modern_stock_names_and_independent_gallery_identity(self):
        for name, row in self.fixtures.items():
            if row["layout"] != "posterBoard27":
                continue
            with self.subTest(fixture=name):
                members = self.members(name)
                descriptor = f"descriptors/{row['uuid']}"
                contents = f"{descriptor}/versions/1/contents"
                stem = f"{row['identifier']}.Clownfish"
                wallpaper_name = f"{stem}-{row['screenClass']}.wallpaper"
                self.assertEqual(row["wallpaperFolder"], f"{contents}/{wallpaper_name}")
                self.assertEqual(members[f"{descriptor}/com.apple.posterkit.provider.descriptor.identifier"],
                                 str(row["identifier"]).encode())
                plist = plistlib.loads(members[f"{row['wallpaperFolder']}/Wallpaper.plist"])
                self.assertEqual(plist["identifier"], row["identifier"])
                self.assertEqual(plist["name"], row["displayName"])
                self.assertEqual(plist["family"], "Clownfish")
                self.assertEqual(plist["contentVersion"], 1.01)
                self.assertEqual(plist["logicalScreenClass"], row["screenClass"])
                self.assertIs(plist["disableAdaptiveTime"], True)
                self.assertEqual(plist["maximumAdaptiveTimeMultiplier"], 2.0)
                asset = plist["assets"]["lockAndHome"]["default"]
                self.assertEqual(asset["identifier"], row["identifier"])
                self.assertEqual(asset["name"], row["displayName"])
                self.assertEqual(asset["type"], "LayeredAnimation")
                for role, key in (("Background", "backgroundAnimationFileName"),
                                  ("Floating", "floatingAnimationFileNameKey"),
                                  ("Foreground", "foregroundAnimationFileName")):
                    bundle = f"{stem}_{role}-{row['screenClass']}.ca"
                    self.assertEqual(asset[key], bundle)
                    self.assertEqual(row[role.lower() + "Folder"], f"{row['wallpaperFolder']}/{bundle}")
                self.assertEqual(plistlib.loads(members[f"{contents}/com.apple.posterkit.provider.contents.userInfo"]), {
                    "wallpaperRepresentingFileName": wallpaper_name,
                    "wallpaperRepresentingIdentifier": str(row["identifier"]), "posterEnvironmentOverrides": b"{}"})
                for suffix in BINARY_MODERN_SUFFIXES:
                    matches = [path for path in members if path.endswith(suffix)]
                    if suffix == "otherMetadata.plist" and not any(
                            path.endswith("otherMetadata.plist") for path in members):
                        continue
                    self.assertEqual(len(matches), 1, f"missing modern keyed archive: {suffix}")
                    self.assert_binary_uid_graph(members[matches[0]])
                self.assertEqual(decode_archive(members[f"{contents}/{OTHER}"])["displayNameLocalizationKey"],
                                 row["displayName"])
                suggestion_data = members[f"{descriptor}/{SUGGESTION}"]
                self.assert_binary_uid_graph(suggestion_data)
                suggestion = decode_archive(suggestion_data)
                self.assertEqual(suggestion["_class"], "PRPosterSuggestionMetadata")
                gallery = suggestion["suggestedGalleryItem"]
                self.assertEqual(gallery["_class"], "ATXFaceGalleryItem")
                self.assertEqual(gallery["descriptorIdentifier"], f"{row['identifier']}.DYNAMIC")
                self.assertEqual(gallery["displayNameLocalizationKey"], "Collections")
                self.assertEqual(gallery["localizedDisplayName"], row["displayName"])
                self.assertEqual(gallery["extensionBundleIdentifier"],
                                 "com.apple.WallpaperKit.CollectionsPoster")
                self.assertEqual(gallery["identifier"], row["galleryUUID"])
                self.assertNotEqual(gallery["identifier"], row["uuid"])
        self.assertEqual(Path(self.fixtures["uuid"]["wallpaperFolder"]).name,
                         Path(self.fixtures["modern"]["wallpaperFolder"]).name)

    def test_all_three_planes_publish_matching_logical_roots(self):
        for name, row in self.fixtures.items():
            if row["layout"] != "posterBoard27":
                continue
            members = self.members(name)
            for role in ("Background", "Floating", "Foreground"):
                with self.subTest(fixture=name, role=role):
                    folder = row[role.lower() + "Folder"]
                    index = plistlib.loads(members[f"{folder}/index.xml"])
                    self.assertEqual(index["publishedObjectNames"], [role])
                    self.assertEqual((index["documentWidth"], index["documentHeight"]),
                                     (row["pointWidth"], row["pointHeight"]))
                    self.assertIs(index["unitsInPixelsInPlayer"], False)
                    self.assertIs(index["scalesToFitInPlayer"], True)
                    self.assertIs(index["geometryFlipped"], False)
                    self.assertEqual(index["rootDocument"], "main.caml")
                    self.assertEqual(index["assetManifest"], "assetManifest.caml")
                    document = ET.fromstring(members[f"{folder}/main.caml"])
                    layers = document.findall(f"{NS}CALayer")
                    self.assertEqual(len(layers), 1)
                    layer = layers[0]
                    self.assertEqual(layer.attrib["id"], role)
                    self.assertEqual(layer.attrib["name"], role)
                    self.assertEqual(layer.attrib["anchorPoint"], "0 0")
                    self.assertEqual(layer.attrib["position"], "0 0")
                    self.assertEqual([float(v) for v in layer.attrib["bounds"].split()],
                                     [0, 0, row["pointWidth"], row["pointHeight"]])
                    self.assertEqual(len(document.findall(f".//{NS}CALayer")), 1)
                    manifest = ET.fromstring(members[f"{folder}/assetManifest.caml"])
                    self.assertIsNotNone(manifest.find(f"{NS}MicaAssetManifest"))
                    if role != "Background":
                        self.assertIsNone(layer.find(f"{NS}contents"))
                        self.assertEqual(layer.findall(f".//{NS}animation"), [])
                        self.assertEqual(layer.findall(f".//{NS}CGImage"), [])
                        self.assertNotIn("backgroundColor", layer.attrib)

    def test_custom_pixel_resolution_is_not_confused_with_logical_scale(self):
        names = ("modern", "custom-wide", "custom-small", "custom-portrait", "custom-square",
                 "logical-landscape", "scale3")
        for name in names:
            with self.subTest(fixture=name):
                row = self.fixtures[name]
                layer = ET.fromstring(self.members(name)[f"{row['backgroundFolder']}/main.caml"])[0]
                self.assertEqual(layer.attrib["contentsGravity"], "resizeAspectFill")
                self.assertEqual(float(layer.attrib["contentsScale"]), row["scale"])
                self.assertEqual(layer.attrib["masksToBounds"], "1")
                self.assertNotIn("transform", layer.attrib)
                self.assertEqual(layer.findall(f".//{NS}CATransformLayer"), [])
                # Calculate the implied CA resizeAspectFill contract independently.
                # Bitmap pixel size and backing scale are separate from point bounds.
                pw, ph = row["pixelWidth"], row["pixelHeight"]
                width, height = row["pointWidth"], row["pointHeight"]
                fit = max(width / pw, height / ph)
                drawn = pw * fit, ph * fit
                self.assertGreaterEqual(drawn[0] + 1e-9, width)
                self.assertGreaterEqual(drawn[1] + 1e-9, height)
                self.assertAlmostEqual(drawn[0] / drawn[1], pw / ph)
                self.assertTrue(math.isclose(drawn[0], width) or math.isclose(drawn[1], height))
        # Catch a future test fixture accidentally exercising only native @2 geometry.
        self.assertNotEqual(self.fixtures["custom-wide"]["pixelWidth"], 834 * 2)
        self.assertEqual(self.fixtures["scale3"]["pixelWidth"], self.fixtures["modern"]["pixelWidth"])

    def test_every_frame_and_exact_timing_survive_layout_change(self):
        for name, row in self.fixtures.items():
            if name == "legacy-sequence":
                continue
            with self.subTest(fixture=name):
                members = self.members(name)
                document = ET.fromstring(members[f"{row['backgroundFolder']}/main.caml"])
                animations = document.findall(f".//{NS}animation")
                self.assertEqual(len(animations), 1)
                animation = animations[0]
                self.assertEqual(animation.attrib["type"], "CAKeyframeAnimation")
                for key, expected in {"keyPath": "contents", "calculationMode": "linear", "speed": "1",
                                      "repeatCount": "inf", "removedOnCompletion": "0", "timeOffset": "0",
                                      "autoreverses": "0", "repeatDuration": "0", "beginTime": "1e-100"}.items():
                    self.assertEqual(animation.attrib[key], expected)
                duration = row["frameCount"] / row["frameRate"]
                self.assertAlmostEqual(float(animation.attrib["duration"]), duration, delta=0.000001)
                expected = [f"assets/{i:05d}.jpg" for i in range(row["frameCount"])]
                images = animation.findall(f"{NS}values/{NS}CGImage")
                self.assertEqual([image.attrib["src"] for image in images], expected)
                contents = document.findall(f".//{NS}contents")
                self.assertEqual(len(contents), 1)
                self.assertEqual(contents[0].attrib, {"type": "CGImage", "src": expected[0]})
                index = plistlib.loads(members[f"{row['backgroundFolder']}/index.xml"])
                self.assertEqual(index["loopStart"], 0)
                self.assertAlmostEqual(index["loopEnd"], duration, delta=0.000001)
                self.assertIs(index["loopingEnabled"], True)

    def test_configuration_archives_resolve_to_intended_objects(self):
        members = self.members("modern")
        version = f"descriptors/{UUID}/versions/1"
        rendering = {"_class": "PRPosterRenderingConfiguration",
                     "motionEffectsDisabled": False, "depthEffectDisabled": False}
        self.assertEqual(decode_archive(members[f"{version}/{RENDERING}"]), rendering)
        options = decode_archive(members[f"{version}/contents/{CONFIG}"])
        self.assertEqual(options, {
            "_class": "PRPosterConfigurableOptions", "preferredRenderingConfiguration": rendering,
            "preferredHomeScreenConfiguration": {
                "_class": "PRPosterDescriptorHomeScreenConfiguration", "preferredStyle": 0,
                "preferredSolidColors": None, "preferredGradientColors": None,
                "allowsModifyingLegibilityBlur": True},
            "ambientSupportedDataLayout": 0, "displayNameLocalizationKey": None,
            "luminance": 0.5, "role": "PRPosterRoleLockScreen",
            "preferredTimeFontConfigurations": [], "preferredTitleColors": [],
        })
        self.assertIs(options["preferredRenderingConfiguration"]["motionEffectsDisabled"], False)
        self.assertIs(options["preferredRenderingConfiguration"]["depthEffectDisabled"], False)

    def test_dynamic_metadata_member_counts_and_optional_record(self):
        for name, count in (("legacy", 12), ("modern", 18)):
            with self.subTest(layout=name):
                full, minimal = self.members(name), self.members(name + "-no-display")
                self.assertEqual(len(full), count)
                self.assertEqual(len(minimal), count - 1)
                removed = set(full) - set(minimal)
                self.assertEqual(len(removed), 1)
                self.assertEqual(Path(removed.pop()).name, OTHER)
                for path in minimal:
                    if path.endswith((".caml", "index.xml")):
                        self.assertEqual(full[path], minimal[path])
                    elif full[path].startswith((b"<?xml", b"bplist")):
                        self.assertEqual(plistlib.loads(full[path]), plistlib.loads(minimal[path]))
                    else:
                        self.assertEqual(full[path], minimal[path])

    def test_real_zip_preserves_every_opaque_source_frame_byte(self):
        for name, metadata_count in (("legacy", 12), ("modern", 18)):
            with self.subTest(layout=name), zipfile.ZipFile(self.output / (name + ".tendies")) as archive:
                row = self.fixtures[name]
                self.assertIsNone(archive.testzip())
                self.assertEqual(len(archive.namelist()), metadata_count + row["frameCount"])
                self.assertEqual(len(set(archive.namelist())), len(archive.namelist()))
                expected_frames = {f"{row['backgroundFolder']}/assets/{i:05d}.jpg":
                                   f"opaque-original-frame-{i}".encode() for i in range(row["frameCount"])}
                self.assertEqual(set(archive.namelist()), set(self.members(name)) | set(expected_frames))
                for path, value in expected_frames.items():
                    self.assertEqual(archive.read(path), value)
                    self.assertEqual(archive.getinfo(path).compress_type, zipfile.ZIP_STORED)

    def test_legacy_image_sequence_still_available_only_as_explicit_alternative(self):
        row = self.fixtures["legacy-sequence"]
        members = self.members("legacy-sequence")
        self.assertEqual(len(members), 12)
        layer = plistlib.loads(members[f"{row['backgroundFolder']}/main.caml"])["view"]["sublayers"][0]
        self.assertEqual(layer["contents"], {
            "type": "ImageSequence", "initialImage": "assets/00000.jpg", "frameCount": 60,
            "frameDuration": 0.033333, "imageFormat": "jpg", "imageNamePattern": "assets/%05d.jpg",
            "loop": True})


if __name__ == "__main__":
    unittest.main()
