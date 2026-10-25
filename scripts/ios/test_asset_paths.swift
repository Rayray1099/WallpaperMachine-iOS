// SPDX-License-Identifier: GPL-3.0-only
// Compile with WallpaperModels.swift; Foundation only, no app launch or XCTest.
import Foundation

@main
struct AssetPathRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("wm-asset-path-regression-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        let alias = scratch.appendingPathComponent("root-alias", isDirectory: true)
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(description: label) }
            checks += 1
        }
        func rejects(_ path: String, inside base: URL = root) throws {
            do {
                _ = try AssetPath.resolve(path, inside: base)
            } catch LibraryError.invalidPath { checks += 1; return }
            catch LibraryError.symbolicLink { checks += 1; return }
            throw Failure(description: "Unsafe path accepted: " + path)
        }
        // Compare the previous algorithm on the actual host; never infer Darwin
        // behavior from Windows or claim reproduction if Foundation resolves it.
        #if canImport(Darwin)
        print("Host: Darwin Foundation; actual filesystem alias regression")
        #else
        print("Host: non-Darwin Foundation; Darwin behavior remains unverified")
        #endif
        var previousFailures = 0
        for relative in ["scene.json", "new/parent/scene.json"] {
            let previous = alias.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            let previousContained = previous.path.hasPrefix(canonical.path + "/")
            if !previousContained { previousFailures += 1 }
            print("Previous algorithm missing child '\(relative)' passes canonical containment: \(previousContained)")
            let resolved = try AssetPath.resolve(relative, inside: alias)
            try require(resolved.path == canonical.appendingPathComponent(relative).path, "Missing leaf lost canonical root")
            try require(!fm.fileExists(atPath: resolved.path), "Regression fixture unexpectedly exists")
        }
        print("Previous algorithm false containment rejections observed: \(previousFailures)/2")
        let rawBackslash = "new\\parent\\scene.json"
        let previousBackslash = alias.appendingPathComponent(rawBackslash).standardizedFileURL.resolvingSymlinksInPath()
        let expectedBackslash = canonical.appendingPathComponent("new/parent/scene.json")
        print("Previous raw-backslash algorithm differs from normalized canonical child: \(previousBackslash.path != expectedBackslash.path)")
        let normalized = try AssetPath.resolve(rawBackslash, inside: alias)
        try require(normalized.path == expectedBackslash.path, "Backslash components not normalized")
        #if canImport(Darwin)
        if canonical.path.hasPrefix("/private/var/") {
            let varAlias = URL(fileURLWithPath: String(canonical.path.dropFirst("/private".count)), isDirectory: true)
            guard fm.fileExists(atPath: varAlias.path) else {
                throw Failure(description: "Derived /var alias does not name the existing regression root")
            }
            for relative in ["scene.json", "new/parent/scene.json"] {
                let previous = varAlias.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                print("Darwin actual /var alias previous algorithm '\(relative)' passes canonical containment: \(previous.path.hasPrefix(canonical.path + "/"))")
                let resolved = try AssetPath.resolve(relative, inside: varAlias)
                try require(resolved.path == canonical.appendingPathComponent(relative).path, "Actual /var alias missing child lost canonical root")
            }
            print("PASS: Darwin actual /var → /private/var missing-child invariants (2 checks)")
        } else {
            print("SKIP: Darwin actual /var alias variant; temporary canonical root is not under /private/var/")
        }
        #else
        print("SKIP: actual /var → /private/var alias variant requires Darwin")
        #endif
        let existing = root.appendingPathComponent("existing.json")
        try Data("{}".utf8).write(to: existing)
        let resolvedExisting = try AssetPath.resolve("existing.json", inside: alias)
        try require(resolvedExisting.path == canonical.appendingPathComponent("existing.json").path, "Existing alias entry not canonical")
        let existingData = try Data(contentsOf: resolvedExisting)
        try require(existingData == Data("{}".utf8), "Existing file bytes changed")
        for path in ["../escape", "nested/../escape", "/escape", "C:/escape", "..\\escape", "", "a//b", "a/./b", "a/\0b"] {
            try rejects(path)
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try rejects("escape/missing.json")
        try fm.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("missing"))
        try rejects("dangling")
        try rejects("dangling/missing.json")
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("internal-alias"), withDestinationURL: actual)
        try rejects("internal-alias/missing.json")
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try rejects("loop/missing.json")
        print("PASS: AssetPath canonical alias/missing leaf and ancestors, existing entry, normalized separators, traversal, escaping/internal/dangling/loop links (\(checks) checks)")
        print("Scope: Foundation filesystem regression only; no app/device/renderer verification.")
    }
}
