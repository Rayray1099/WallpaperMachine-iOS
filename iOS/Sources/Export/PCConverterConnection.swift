// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An explicit, in-memory capability for one private IPv4 converter. Never persist or log it.
struct PCConverterConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let baseURL: URL
    private let token: String

    init(link: String) throws {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }), !value.contains("%"),
              let parts = URLComponents(string: value), parts.scheme == "http",
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host, Self.isPrivateIPv4(host),
              let port = parts.port, (1024...65535).contains(port),
              let fragment = parts.fragment, fragment.hasPrefix("token=") else {
            throw PCConverterError.connection
        }
        let token = String(fragment.dropFirst("token=".count))
        guard Self.isCapability(token) else { throw PCConverterError.connection }
        var base = URLComponents()
        base.scheme = "http"; base.host = host; base.port = port
        guard let baseURL = base.url else { throw PCConverterError.connection }
        self.baseURL = baseURL
        self.token = token
    }

    var displayAddress: String { baseURL.absoluteString }
    var description: String { "PCConverterConnection(\(displayAddress), capability: redacted)" }
    var debugDescription: String { description }

    func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }

    func endpoint(path: String, query: [URLQueryItem] = []) -> URL {
        // Only app-owned routes reach this helper; never accept a server-provided URL here.
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        // The Python endpoint parses form-style queries, where a literal + means a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    func downloadURL(relative: String, jobID: String) throws -> URL {
        guard Self.isJobID(jobID), !relative.contains("%"),
              let parts = URLComponents(string: relative),
              parts.scheme == nil, parts.host == nil, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.path == "/api/jobs/\(jobID)/download",
              let items = parts.queryItems, items.count == 1, items[0].name == "key",
              let key = items[0].value, Self.isCapability(key), parts.query == "key=" + key else {
            throw PCConverterError.response
        }
        return endpoint(path: parts.path, query: [URLQueryItem(name: "key", value: key)])
    }

    static func isJobID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isCapability(_ value: String) -> Bool {
        (20..<128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let numbers = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  piece.count == 1 || piece.first != "0", let number = Int(piece), number <= 255 else { return nil }
            return number
        }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1]))
            || (numbers[0] == 192 && numbers[1] == 168)
    }
}

enum PCConverterError: String, Error, LocalizedError {
    case connection, source, transport, authorization, busy, conversion, archive, response, timeout, storage

    var errorDescription: String? { NSLocalizedString("export.pc.error." + rawValue, comment: "") }
}
