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

    /// Counts source-reader calls, not output frames. In particular, the first
    /// output tick can request more than one sample for lookahead.
    struct CopyStatistics: Equatable {
        private(set) var attempts = 0
        private(set) var successfulSamples = 0

        mutating func recordAttempt() { attempts += 1 }
        mutating func recordSuccess() { successfulSamples += 1 }
    }

    /// The output tick requesting a sample. The failing sample itself can be
    /// lookahead and does not necessarily have this presentation time.
    struct FrameContext: Equatable {
        let outputFrame: Int?
        let targetValue: Int64
        let targetTimescale: Int32
    }

    let stage: Stage
    let readerStatus: ReaderStatus?
    let errors: [ErrorCode]
    let cycleDetected: Bool
    let truncated: Bool
    let copyStatistics: CopyStatistics?
    let frameContext: FrameContext?

    /// Includes the root error and at most two underlying errors. Only the standard
    /// underlying-error key is inspected; no userInfo value is rendered as text.
    init(stage: Stage, readerStatus: ReaderStatus?, error: NSError?,
         copyStatistics: CopyStatistics? = nil, frameContext: FrameContext? = nil) {
        self.stage = stage
        self.readerStatus = readerStatus
        self.copyStatistics = copyStatistics
        self.frameContext = frameContext
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
        let copies = copyStatistics.map {
            " copyAttempts=\($0.attempts) successfulSamples=\($0.successfulSamples)"
        } ?? ""
        let frame = frameContext.map {
            " outputFrame=\($0.outputFrame.map { String($0) } ?? "none") target=\($0.targetValue)/\($0.targetTimescale)"
        } ?? ""
        return "[stage=\(stage.rawValue) reader=\(readerStatus?.rawValue ?? "none") errors=\(codes.isEmpty ? "none" : codes)\(chain)\(copies)\(frame)]"
    }
}
