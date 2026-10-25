// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bounded decoder diagnostics: fixed stage/status labels and allowlisted domains
/// with numeric codes only. NSError descriptions and arbitrary userInfo never leave
/// this boundary because they can contain source paths or other private content.
struct MovieFrameSourceDiagnostics: Equatable, CustomStringConvertible {
    enum Stage: String {
        case start
        case copy
    }

    enum ReaderStatus: String {
        case unknown
        case reading
        case completed
        case failed
        case cancelled
    }

    struct ErrorCode: Equatable {
        enum Domain: String {
            case avFoundation = "AVFoundationErrorDomain"
            case osStatus = "NSOSStatusErrorDomain"
            case cocoa = "NSCocoaErrorDomain"
            case unknown = "Unknown"

            init(_ raw: String) {
                switch raw {
                case "AVFoundationErrorDomain": self = .avFoundation
                case "NSOSStatusErrorDomain": self = .osStatus
                case "NSCocoaErrorDomain": self = .cocoa
                default: self = .unknown
                }
            }
        }

        let domain: Domain
        let code: Int
    }

    let stage: Stage
    let readerStatus: ReaderStatus?
    let errors: [ErrorCode]
    let cycleDetected: Bool
    let truncated: Bool

    /// Includes the root error and at most two underlying errors. Only the standard
    /// underlying-error key is inspected; no userInfo value is rendered as text.
    init(stage: Stage, readerStatus: ReaderStatus?, error: NSError?) {
        self.stage = stage
        self.readerStatus = readerStatus
        var codes: [ErrorCode] = []
        var visited: Set<ObjectIdentifier> = []
        var next = error
        var cycle = false
        var capped = false
        while let current = next {
            guard visited.insert(ObjectIdentifier(current)).inserted else {
                cycle = true
                break
            }
            guard codes.count < 3 else {
                capped = true
                break
            }
            codes.append(ErrorCode(domain: ErrorCode.Domain(current.domain), code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.errors = codes
        self.cycleDetected = cycle
        self.truncated = capped
    }

    var description: String {
        let codes = errors.map { "\($0.domain.rawValue):\($0.code)" }.joined(separator: ">")
        let chain = cycleDetected ? " chain=cycle" : (truncated ? " chain=truncated" : "")
        return "[stage=\(stage.rawValue) reader=\(readerStatus?.rawValue ?? "none") errors=\(codes.isEmpty ? "none" : codes)\(chain)]"
    }
}
