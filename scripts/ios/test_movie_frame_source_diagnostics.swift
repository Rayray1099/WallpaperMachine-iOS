// SPDX-License-Identifier: GPL-3.0-only
// Compile with the actual MovieFrameSourceDiagnostics.swift. No media or device access.
import Foundation

@main
struct MovieFrameSourceDiagnosticsRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: MovieFrameSourceDiagnostics: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(description: label) }
            checks += 1
        }
        func diagnostic(_ error: NSError?, stage: MovieFrameSourceDiagnostics.Stage = .copy,
                        status: MovieFrameSourceDiagnostics.ReaderStatus? = .failed,
                        copyStatistics: MovieFrameSourceDiagnostics.CopyStatistics? = nil,
                        frameContext: MovieFrameSourceDiagnostics.FrameContext? = nil) -> MovieFrameSourceDiagnostics {
            MovieFrameSourceDiagnostics(stage: stage, readerStatus: status, error: error,
                                        copyStatistics: copyStatistics, frameContext: frameContext)
        }

        let missing = diagnostic(nil, stage: .start, status: nil)
        try require(missing.description == "[stage=start reader=none errors=none]", "Missing error/start status")
        try require(missing.errors.isEmpty && !missing.cycleDetected && !missing.truncated, "No invented error codes")
        let leaf = NSError(domain: "NSOSStatusErrorDomain", code: -12345, userInfo: [
            NSLocalizedDescriptionKey: "credential=do-not-expose",
            NSFilePathErrorKey: "/private/author/movie.mp4",
            NSURLErrorKey: URL(string: "https://example.invalid/?token=do-not-expose")!
        ])
        let root = NSError(domain: "AVFoundationErrorDomain", code: -12000,
                           userInfo: [NSUnderlyingErrorKey: leaf, NSLocalizedDescriptionKey: "private source path"])
        let known = diagnostic(root)
        try require(known.errors == [
            .init(domain: .avFoundation, code: -12000), .init(domain: .osStatus, code: -12345)
        ], "Preserve root and underlying numeric codes in order")
        try require(known.description == "[stage=copy reader=failed errors=AVFoundationErrorDomain:-12000>NSOSStatusErrorDomain:-12345]",
                    "Only fixed labels, domains and codes are emitted")
        try require(!known.description.contains("private") && !known.description.contains("token")
                    && !known.description.contains("credential") && !known.description.contains("movie"), "Suppress all NSError text and paths")
        let unknown = diagnostic(NSError(domain: "secret://credential@author/movie", code: Int.max))
        try require(unknown.errors == [.init(domain: .unknown, code: Int.max)], "Unknown domain safely aliased; numeric code preserved")
        try require(!unknown.description.contains("secret") && !unknown.description.contains("credential"), "Unknown domain never echoed")
        for domain in ["AVFoundationErrorDomain ", "avfoundationerrordomain", "NSOSStatusErrorDomain\nprivate", "NSURLErrorDomain", ""] {
            let value = diagnostic(NSError(domain: domain, code: 7))
            try require(value.errors.first?.domain == .unknown, "Domains require an exact allowlist match")
        }
        let cocoa = diagnostic(NSError(domain: NSCocoaErrorDomain, code: 256))
        try require(cocoa.errors == [.init(domain: .cocoa, code: 256)], "Cocoa domain allowlisted")
        let minimum = diagnostic(NSError(domain: "NSOSStatusErrorDomain", code: Int.min))
        try require(minimum.description.contains(String(Int.min)), "Minimum numeric code does not overflow")

        let depth2 = NSError(domain: NSCocoaErrorDomain, code: 3, userInfo: [NSUnderlyingErrorKey: leaf])
        let depth1 = NSError(domain: "NSOSStatusErrorDomain", code: 2, userInfo: [NSUnderlyingErrorKey: depth2])
        let deep = diagnostic(NSError(domain: "AVFoundationErrorDomain", code: 1, userInfo: [NSUnderlyingErrorKey: depth1]))
        try require(deep.errors.map(\.code) == [1, 2, 3], "Root plus at most two underlying errors")
        try require(deep.truncated && !deep.cycleDetected && deep.description.hasSuffix(" chain=truncated]"), "Depth limit explicit")
        let exactDepth = diagnostic(depth1)
        try require(exactDepth.errors.count == 3 && !exactDepth.truncated, "Exactly three errors is not truncated")
        let wrongType = diagnostic(NSError(domain: NSCocoaErrorDomain, code: 4,
                                           userInfo: [NSUnderlyingErrorKey: "do-not-render-me"]))
        try require(wrongType.errors.count == 1 && !wrongType.description.contains("do-not-render"), "Non-error underlying value discarded")

        let cycle = CyclicDiagnosticError(code: 5)
        cycle.next = cycle
        let cyclic = diagnostic(cycle)
        try require(cyclic.errors.count == 1 && cyclic.cycleDetected && !cyclic.truncated, "Self-cycle terminates")
        try require(cyclic.description.hasSuffix(" chain=cycle]"), "Cycle flagged without arbitrary content")
        cycle.next = nil
        let first = CyclicDiagnosticError(code: 6)
        let second = CyclicDiagnosticError(code: 7)
        first.next = second
        second.next = first
        let pair = diagnostic(first)
        try require(pair.errors.map(\.code) == [6, 7] && pair.cycleDetected, "Two-node cycle terminates preserving order")
        first.next = nil
        second.next = nil

        for status in [MovieFrameSourceDiagnostics.ReaderStatus.unknown, .reading, .completed, .failed, .cancelled] {
            for stage in [MovieFrameSourceDiagnostics.Stage.start, .copy] {
                let value = diagnostic(nil, stage: stage, status: status)
                try require(value.description == "[stage=\(stage.rawValue) reader=\(status.rawValue) errors=none]", "Fixed stage/status labels")
            }
        }
        let duplicateLeaf = NSError(domain: NSCocoaErrorDomain, code: 8)
        let duplicateRoot = NSError(domain: NSCocoaErrorDomain, code: 8, userInfo: [NSUnderlyingErrorKey: duplicateLeaf])
        try require(diagnostic(duplicateRoot).errors.count == 2, "Equal codes on distinct NSError instances are not a cycle")

        var firstCopy = MovieFrameSourceDiagnostics.CopyStatistics()
        firstCopy.recordAttempt()
        let immediate = diagnostic(
            NSError(domain: "AVFoundationErrorDomain", code: -11819),
            copyStatistics: firstCopy,
            frameContext: .init(outputFrame: 0, targetValue: 0, targetTimescale: 60))
        try require(immediate.description ==
                    "[stage=copy reader=failed errors=AVFoundationErrorDomain:-11819 "
                    + "copyAttempts=1 successfulSamples=0 outputFrame=0 target=0/60]",
                    "First-copy failure preserves zero successful samples and output context")

        var afterLookahead = MovieFrameSourceDiagnostics.CopyStatistics()
        afterLookahead.recordAttempt()
        afterLookahead.recordSuccess()
        afterLookahead.recordAttempt()
        let later = diagnostic(
            NSError(domain: "AVFoundationErrorDomain", code: -11819),
            copyStatistics: afterLookahead,
            frameContext: .init(outputFrame: 120, targetValue: 120, targetTimescale: 60))
        try require(later.copyStatistics?.successfulSamples == 1 && later.copyStatistics?.attempts == 2,
                    "Lookahead failure retains successful sample count")
        try require(later.description.contains("copyAttempts=2 successfulSamples=1 outputFrame=120 target=120/60"),
                    "Later failure preserves output tick and copy counts")
        print("PASS: privacy-safe decoder stages/status, exact domain allowlist, numeric NSError chains, depth cap and cycles (\(checks) checks)")
        print("Scope: actual Foundation diagnostics only; no AVFoundation decoder, app, simulator or physical-device execution.")
    }
}

/// Override just the standard underlying-error slot to exercise cycles without
/// serializing or printing an NSError's potentially recursive userInfo.
private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
    var next: NSError?
    init(code: Int) { super.init(domain: NSCocoaErrorDomain, code: code, userInfo: nil) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var userInfo: [String: Any] {
        guard let next else { return [:] }
        return [NSUnderlyingErrorKey: next]
    }
}
