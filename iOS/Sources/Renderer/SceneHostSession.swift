// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One URL's host lifetime. No filesystem access, renderer calls or readiness credit.
struct SceneHostSession {
    private(set) var url: URL
    private(set) var attempted = false
    private(set) var failure: String?

    init(url: URL) { self.url = url }

    /// Settings/property updates keep the same engine; another URL starts a new lifetime.
    @discardableResult mutating func select(_ url: URL) -> Bool {
        guard self.url != url else { return false }
        self.url = url
        attempted = false
        failure = nil
        return true
    }

    mutating func beginInitialization() -> Bool {
        guard !attempted, failure == nil else { return false }
        attempted = true
        return true
    }

    /// Preserve the first explicit host failure, even if cleanup reports another one.
    @discardableResult mutating func recordFailure(_ message: String) -> Bool {
        guard failure == nil else { return false }
        attempted = true
        failure = message
        return true
    }

    /// Dismantling before the first layout must not allow a queued layout to start it.
    mutating func stop() { attempted = true }
}
