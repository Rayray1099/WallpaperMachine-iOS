// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XCTest
@testable import WallpaperMachineIOS

final class SceneSharedAssetsInstallerTests: XCTestCase {
    private struct Member {
        let path: String
        let data: Data
        var mode: UInt32 = 0o100644
    }

    @MainActor private final class PublicationProbe {
        var calls = 0
        func publish() { calls += 1 }
    }

    private let shader = "shaders/test.vert"
    private let fragment = "shaders/test.frag"

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture(_ root: URL, files: [String: Data]? = nil,
                         extra: [Member] = [], wrongHash: Bool = false,
                         wrongSize: Bool = false, schema: String = "wallpapermachine.shared-assets/v1") throws -> URL {
        let files = files ?? [shader: Data("void main() {}".utf8), fragment: Data("// self-authored fragment".utf8)]
        let records: [[String: Any]] = files.keys.sorted().map { path in
            let data = files[path]!
            return ["path": path, "bytes": data.count + (wrongSize ? 1 : 0),
                    "sha256": wrongHash ? String(repeating: "0", count: 64) : hash(data)]
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["schema": schema, "files": records], options: [.sortedKeys])
        let members = files.keys.sorted().map { Member(path: $0, data: files[$0]!) } +
            [Member(path: "wmassets-manifest.json", data: manifest)] + extra
        let archive = root.appendingPathComponent(UUID().uuidString + ".zip")
        try makeZIP(members).write(to: archive)
        return archive
    }

    /// Tiny ZIP32 fixture builder permits deliberately malicious member names and
    /// symlink metadata. Payloads are entirely self-authored; production uses ZIPFoundation.
    private func makeZIP(_ members: [Member]) -> Data {
        var data = Data()
        var central = Data()
        for member in members {
            let name = Data(member.path.utf8)
            let offset = UInt32(data.count)
            let checksum = CRC32.checksum(member.data)
            data.le32(0x04034b50); data.le16(20); data.le16(0x800); data.le16(0)
            data.le16(0); data.le16(0); data.le32(checksum)
            data.le32(UInt32(member.data.count)); data.le32(UInt32(member.data.count))
            data.le16(UInt16(name.count)); data.le16(0); data.append(name); data.append(member.data)
            central.le32(0x02014b50); central.le16(0x0314); central.le16(20); central.le16(0x800)
            central.le16(0); central.le16(0); central.le16(0); central.le32(checksum)
            central.le32(UInt32(member.data.count)); central.le32(UInt32(member.data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(member.mode << 16); central.le32(offset); central.append(name)
        }
        let offset = UInt32(data.count)
        data.append(central)
        data.le32(0x06054b50); data.le16(0); data.le16(0)
        data.le16(UInt16(members.count)); data.le16(UInt16(members.count))
        data.le32(UInt32(central.count)); data.le32(offset); data.le16(0)
        return data
    }

    private func target(_ root: URL) -> URL {
        root.appendingPathComponent("WallpaperMachine/SharedAssets", isDirectory: true)
    }

    private func assertRejected(_ archive: URL, support: URL,
                                limits: SceneSharedAssetsInstaller.Limits = .init(),
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let existing = target(support).appendingPathComponent("keep.txt")
        try IOSTestSupport.write("retained original", to: existing)
        let originalZIP = try Data(contentsOf: archive)
        let probe = await PublicationProbe()
        do {
            _ = try await SceneSharedAssetsInstaller(applicationSupport: support, limits: limits)
                .install(from: archive, willPublish: { probe.publish() })
            XCTFail("Expected rejection", file: file, line: line)
        } catch {
            XCTAssertTrue(error is SceneSharedAssetsInstaller.InstallError || error is CancellationError,
                          "Expected a safe typed error", file: file, line: line)
        }
        let calls = await probe.calls
        XCTAssertEqual(calls, 0, file: file, line: line)
        XCTAssertEqual(try String(contentsOf: existing), "retained original", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: archive), originalZIP, file: file, line: line)
        let children = try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("WallpaperMachine").path)
        XCTAssertFalse(children.contains(where: { $0.hasPrefix(".shared-assets-install-") }), file: file, line: line)
    }

    func testValidInstallVerifiesExactPayloadAndSourceUnchanged() async throws {
        let root = try makeTemporaryDirectory()
        let archive = try fixture(root)
        let original = try Data(contentsOf: archive)
        let support = root.appendingPathComponent("support")
        let probe = await PublicationProbe()
        let receipt = try await SceneSharedAssetsInstaller(applicationSupport: support)
            .install(from: archive, willPublish: { probe.publish() })
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(receipt.fileCount, 2)
        XCTAssertEqual(receipt.byteCount, UInt64("void main() {}".utf8.count + "// self-authored fragment".utf8.count))
        XCTAssertNil(receipt.retainedBackupName)
        XCTAssertEqual(try String(contentsOf: target(support).appendingPathComponent(shader)), "void main() {}")
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let manifest = try Data(contentsOf: target(support).appendingPathComponent("wmassets-manifest.json"))
        XCTAssertEqual(receipt.manifestSHA256, hash(manifest))
    }

    func testExistingAssetsAreRetainedAsSeparateBackup() async throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("support")
        try IOSTestSupport.write("previous resources", to: target(support).appendingPathComponent("old.txt"))
        let receipt = try await SceneSharedAssetsInstaller(applicationSupport: support)
            .install(from: fixture(root), willPublish: {})
        let name = try XCTUnwrap(receipt.retainedBackupName)
        XCTAssertTrue(name.hasPrefix("SharedAssets-backup-"))
        let old = support.appendingPathComponent("WallpaperMachine/" + name + "/old.txt")
        XCTAssertEqual(try String(contentsOf: old), "previous resources")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target(support).appendingPathComponent("old.txt").path))
    }

    func testUnsafeMemberNamesAreRejectedBeforePublication() async throws {
        let root = try makeTemporaryDirectory()
        for path in ["../outside", "/absolute", "C:/drive", "shaders/../escape", "shaders\\escape", "shaders//empty", "shaders/./dot", "assets/shaders/test", "shaders/a.dll", "shaders/control\u{0}x"] {
            let archive = try fixture(root, extra: [Member(path: path, data: Data("bad".utf8))])
            try await assertRejected(archive, support: root.appendingPathComponent(UUID().uuidString))
        }
    }

    func testDuplicateAndCaseFoldedEntriesAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        for path in [shader, "shaders/TEST.vert"] {
            try await assertRejected(fixture(root, extra: [Member(path: path, data: Data("bad".utf8))]),
                                     support: root.appendingPathComponent(UUID().uuidString))
        }
    }

    func testImplicitDirectoryCaseAndFilePrefixCollisionsAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        let variants: [[String: Data]] = [
            [shader: Data([1]), "shaders/Test/a": Data([2]), "shaders/test/b": Data([3])],
            [shader: Data([1]), "textures/x": Data([2]), "textures/x/y": Data([3])]
        ]
        for files in variants {
            try await assertRejected(fixture(root, files: files), support: root.appendingPathComponent(UUID().uuidString))
        }
    }

    func testSymlinkSpecialAndExecutableEntriesAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        for mode: UInt32 in [0o120777, 0o020600, 0o010600, 0o100755] {
            try await assertRejected(fixture(root, extra: [Member(path: "shaders/link", data: Data("../outside".utf8), mode: mode)]),
                                     support: root.appendingPathComponent(UUID().uuidString))
        }
    }

    func testMissingShaderWrongSchemaAndHashAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        for archive in [try fixture(root, files: ["textures/test.png": Data([1, 2, 3])]),
                        try fixture(root, wrongHash: true), try fixture(root, wrongSize: true),
                        try fixture(root, schema: "unknown")] {
            try await assertRejected(archive, support: root.appendingPathComponent(UUID().uuidString))
        }
    }

    func testAllQuotaDimensionsAreEnforcedBeforePublication() async throws {
        let root = try makeTemporaryDirectory()
        let archive = try fixture(root)
        var variants: [SceneSharedAssetsInstaller.Limits] = []
        var limits = SceneSharedAssetsInstaller.Limits(); limits.archiveBytes = 10; variants.append(limits)
        limits = .init(); limits.extractedBytes = 10; variants.append(limits)
        limits = .init(); limits.fileBytes = 10; variants.append(limits)
        limits = .init(); limits.manifestBytes = 10; variants.append(limits)
        limits = .init(); limits.fileCount = 1; variants.append(limits)
        limits = .init(); limits.reserveBytes = UInt64.max; variants.append(limits)
        for limits in variants {
            try await assertRejected(archive, support: root.appendingPathComponent(UUID().uuidString), limits: limits)
        }
    }

    func testPublicationGateFailurePreservesOldAssets() async throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("support")
        let keep = target(support).appendingPathComponent("keep")
        try IOSTestSupport.write("old", to: keep)
        do {
            _ = try await SceneSharedAssetsInstaller(applicationSupport: support)
                .install(from: fixture(root), willPublish: { throw CancellationError() })
            XCTFail("Expected gate cancellation")
        } catch is CancellationError {} catch { XCTFail("Wrong error type") }
        XCTAssertEqual(try String(contentsOf: keep), "old")
    }

    func testCorruptPayloadCRCIsRejectedWithoutPublishing() async throws {
        let root = try makeTemporaryDirectory()
        let archive = try fixture(root)
        var bytes = try Data(contentsOf: archive)
        // First local entry's data follows its 30-byte header and UTF-8 name.
        let firstPayload = 30 + fragment.utf8.count
        bytes[firstPayload] ^= 1
        try bytes.write(to: archive)
        try await assertRejected(archive, support: root.appendingPathComponent("support"))
    }

    func testFailedSecondPublicationRenameRestoresOldDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("support")
        let keep = target(support).appendingPathComponent("keep")
        try IOSTestSupport.write("previous", to: keep)
        let parent = support.appendingPathComponent("WallpaperMachine")
        do {
            _ = try await SceneSharedAssetsInstaller(applicationSupport: support).install(from: fixture(root), willPublish: {
                // Inject failure after successful validation, before publication:
                // remove only this test's NEW staged payload, never the old mount.
                let fm = FileManager.default
                let stage = try XCTUnwrap(fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                    .first(where: { $0.lastPathComponent.hasPrefix(".shared-assets-install-") }))
                let payload = stage.appendingPathComponent("payload")
                XCTAssertEqual(payload.deletingLastPathComponent(), stage)
                try fm.removeItem(at: payload)
            })
            XCTFail("Expected publication failure")
        } catch let error as SceneSharedAssetsInstaller.InstallError {
            XCTAssertEqual(error, .publication)
        }
        XCTAssertEqual(try String(contentsOf: keep), "previous")
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertEqual(names, ["SharedAssets"])
    }

    func testSymlinkMountAndParentAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        let archive = try fixture(root)
        for parentLink in [false, true] {
            let support = root.appendingPathComponent(UUID().uuidString)
            let outside = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = parentLink ? support.appendingPathComponent("WallpaperMachine") : target(support)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            do {
                _ = try await SceneSharedAssetsInstaller(applicationSupport: support)
                    .install(from: archive, willPublish: {})
                XCTFail("Symlink destination accepted")
            } catch let error as SceneSharedAssetsInstaller.InstallError {
                XCTAssertEqual(error, .unsafeDestination)
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(value & 255)); append(UInt8((value >> 8) & 255))
    }
    mutating func le32(_ value: UInt32) {
        le16(UInt16(value & 65535)); le16(UInt16((value >> 16) & 65535))
    }
}
