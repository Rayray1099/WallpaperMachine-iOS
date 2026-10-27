// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import XCTest
@testable import WallpaperMachineIOS

final class PCConverterClientTests: XCTestCase {
    private let token = String(repeating: "a", count: 43)
    private let jobID = "4f98dc42-8568-452d-875c-a106c824ad40"

    func testAcceptsOnlyExplicitPrivateIPv4ConnectionCapabilities() throws {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.2"] {
            let connection = try PCConverterConnection(link: "http://\(host):57351/#token=\(token)")
            XCTAssertEqual(connection.displayAddress, "http://\(host):57351")
            var request = URLRequest(url: connection.baseURL)
            connection.authorize(&request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            XCTAssertFalse(connection.description.contains(token))
            XCTAssertFalse(connection.debugDescription.contains(token))
        }
        _ = try PCConverterConnection(link: " \nhttp://192.168.1.2:1024#token=\(token)\n")
        _ = try PCConverterConnection(link: "http://192.168.1.2:65535/#token=\(token)")
    }

    func testRejectsPublicAmbiguousAndCredentialBearingConnectionURLs() {
        let invalid = [
            "https://192.168.1.2:57351/#token=\(token)",
            "http://8.8.8.8:57351/#token=\(token)", "http://127.0.0.1:57351/#token=\(token)",
            "http://169.254.1.2:57351/#token=\(token)", "http://172.15.1.2:57351/#token=\(token)",
            "http://172.32.1.2:57351/#token=\(token)", "http://192.169.1.2:57351/#token=\(token)",
            "http://converter.local:57351/#token=\(token)", "http://[fd00::1]:57351/#token=\(token)",
            "http://192.168.01.2:57351/#token=\(token)", "http://3232235778:57351/#token=\(token)",
            "http://0xc0a80102:57351/#token=\(token)", "http://192.168.1.256:57351/#token=\(token)",
            "http://192.168.1.2/#token=\(token)", "http://192.168.1.2:80/#token=\(token)",
            "http://192.168.1.2:65536/#token=\(token)", "http://u:p@192.168.1.2:57351/#token=\(token)",
            "http://192.168.1.2:57351/path#token=\(token)", "http://192.168.1.2:57351/?x=1#token=\(token)",
            "http://192.168.1.2:57351/#token=short", "http://192.168.1.2:57351/#token=\(token)&x=1",
            "http://192.168.1.2:57351/#token=\(token)%20", "http://192.168.1.2:57351/#token=" + String(repeating: "x", count: 128),
            "http://192.168.1.2:57351/#token=\(token)\nInjected"
        ]
        for link in invalid { XCTAssertThrowsError(try PCConverterConnection(link: link)) }
    }

    func testDownloadCapabilityNeverChangesOriginJobOrRoute() throws {
        let connection = try PCConverterConnection(link: "http://192.168.1.2:57351/#token=\(token)")
        let route = "/api/jobs/\(jobID)/download?key=\(token)"
        let url = try connection.downloadURL(relative: route, jobID: jobID)
        XCTAssertEqual(url.host, "192.168.1.2")
        XCTAssertEqual(url.port, 57351)
        XCTAssertEqual(url.path, "/api/jobs/\(jobID)/download")
        for invalid in [
            "http://192.168.1.2:57351" + route, "http://8.8.8.8" + route, "//192.168.1.2:57351" + route,
            route + "&key=" + token, route + "&x=1", route + "#fragment",
            "/api/jobs/\(UUID().uuidString.lowercased())/download?key=\(token)",
            "/api/jobs/\(jobID)/../download?key=\(token)",
            "/api/jobs/\(jobID)/download?key=%61" + token, "/api/jobs/\(jobID)/download?key=short"
        ] { XCTAssertThrowsError(try connection.downloadURL(relative: invalid, jobID: jobID)) }
        XCTAssertFalse(PCConverterConnection.isJobID(jobID.uppercased()))
        XCTAssertFalse(PCConverterConnection.isJobID("../" + jobID))
    }

    func testConversionKeepsFullDurationAndFixedNativeFitOptions() throws {
        XCTAssertEqual(PCConverterOptions().frameRate, .fps30)
        XCTAssertEqual(PCConverterOptions().packageLayout, .legacy)
        XCTAssertEqual(PCConverterOptions(), PCConverterOptions(frameRate: .fps30))
        XCTAssertEqual(PCConverterOptions.FrameRate.allCases.map(\.rawValue), [30, 60])
        XCTAssertEqual(PCConverterOptions.PackageLayout.allCases.map(\.rawValue), ["legacy", "posterBoard27"])
        let connection = try PCConverterConnection(link: "http://192.168.1.2:57351/#token=\(token)")
        for rate in PCConverterOptions.FrameRate.allCases {
            for layout in PCConverterOptions.PackageLayout.allCases {
                let options = PCConverterOptions(frameRate: rate, packageLayout: layout)
                let query = options.conversionQuery(title: " A & 桌布\nname ")
                let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                var expected = ["title": "A & 桌布name", "fps": String(rate.rawValue),
                                "width": "1668", "height": "2420", "quality": "2"]
                if layout == .posterBoard27 { expected["package_layout"] = "posterBoard27" }
                XCTAssertEqual(values, expected)
                XCTAssertNil(values["duration"])
                let titledURL = connection.endpoint(path: "/api/jobs", query: options.conversionQuery(title: "A+B & C"))
                XCTAssertTrue(titledURL.absoluteString.contains("title=A%2BB%20%26%20C"))
                let roundTrip = URLComponents(url: titledURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(roundTrip.first(where: { $0.name == "package_layout" })?.value,
                               layout == .legacy ? nil : "posterBoard27")
                let longName = String(repeating: "👩‍💻", count: 120)
                let bounded = options.conversionQuery(title: longName)
                XCTAssertEqual(bounded.first?.value?.unicodeScalars.count, 120)
                XCTAssertEqual(options.conversionQuery(title: " \n\u{7f} ").first?.value, "Wallpaper")
            }
        }
        XCTAssertEqual(PCConverterOptions().conversionQuery(title: "Default"),
                       PCConverterOptions(frameRate: .fps30, packageLayout: .legacy).conversionQuery(title: "Default"))
        XCTAssertNotEqual(PCConverterOptions(), PCConverterOptions(packageLayout: .posterBoard27))
    }

    func testManagedVideoResolutionRejectsEscapesEmptyAndSymlinks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mp4")
        try Data([1, 2, 3]).write(to: video)
        let source = try PCConverterClient.managedVideo(sourceURL: directory, entryFile: "video.mp4")
        XCTAssertEqual(source.url.standardizedFileURL, video.standardizedFileURL)
        XCTAssertEqual(source.bytes, 3)
        for entry in ["../video.mp4", "/video.mp4", "missing.mp4", "", "a/../../video.mp4"] {
            do { _ = try PCConverterClient.managedVideo(sourceURL: directory, entryFile: entry); XCTFail("Accepted unsafe input") }
            catch { XCTAssertEqual(error as? PCConverterError, .source) }
        }
        let empty = directory.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        do { _ = try PCConverterClient.managedVideo(sourceURL: directory, entryFile: "empty.mp4"); XCTFail("Accepted empty video") }
        catch { XCTAssertEqual(error as? PCConverterError, .source) }
        let link = directory.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: video)
        do { _ = try PCConverterClient.managedVideo(sourceURL: directory, entryFile: "link.mp4"); XCTFail("Accepted symbolic link") }
        catch { XCTAssertEqual(error as? PCConverterError, .source) }
    }

    func testReceiptRequiresDoneStateBoundedBytesAndLowercaseSHA256() throws {
        let digest = String(repeating: "a", count: 64)
        let good = PCConverterClient.Job(id: jobID, state: "done", bytes: 100, sha256: digest)
        XCTAssertEqual(try good.receipt().bytes, 100)
        for job in [
            PCConverterClient.Job(id: jobID, state: "converting", bytes: 100, sha256: digest),
            PCConverterClient.Job(id: jobID, state: "done", bytes: 0, sha256: digest),
            PCConverterClient.Job(id: jobID, state: "done", bytes: 1_900_000_000, sha256: digest),
            PCConverterClient.Job(id: jobID, state: "done", bytes: 100, sha256: digest.uppercased()),
            PCConverterClient.Job(id: jobID, state: "done", bytes: 100),
            PCConverterClient.Job(id: jobID, state: "done", sha256: digest)
        ] { XCTAssertThrowsError(try job.receipt()) }
    }

    func testArchiveVerificationChecksSignatureSizeAndStreamingDigest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.partial")
        var data = Data([0x50, 0x4b, 0x03, 0x04])
        data.append(Data(repeating: 42, count: 2 * 1024 * 1024 + 7))
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let actual = try PCConverterClient.verifyArchive(at: url, bytes: Int64(data.count), sha256: digest)
        XCTAssertEqual(actual, digest)
        for (size, hash) in [(Int64(data.count - 1), digest), (Int64(data.count), String(repeating: "0", count: 64))] {
            do { _ = try PCConverterClient.verifyArchive(at: url, bytes: size, sha256: hash); XCTFail("Accepted mismatched receipt") }
            catch { XCTAssertEqual(error as? PCConverterError, .archive) }
        }
        data[0] = 0
        try data.write(to: url)
        do { _ = try PCConverterClient.verifyArchive(at: url, bytes: Int64(data.count), sha256: digest); XCTFail("Accepted non-ZIP") }
        catch { XCTAssertEqual(error as? PCConverterError, .archive) }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PCConverterClientTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
