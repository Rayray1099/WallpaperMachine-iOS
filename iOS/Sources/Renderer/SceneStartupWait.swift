// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Counts only eligible monotonic time while waiting for a scene's first presented frame.
struct SceneStartupWait {
    static let timeout: TimeInterval = 15

    private var accumulated: TimeInterval = 0
    private var activeSince: TimeInterval?
    private var lastUpdate: TimeInterval?

    /// Starts a new wait with no elapsed time; the caller must then supply eligibility.
    mutating func reset(now: TimeInterval) {
        accumulated = 0
        activeSince = nil
        lastUpdate = Self.valid(now) ? now : nil
    }

    /// Supply active + attached + positive-bounds eligibility at lifecycle changes.
    /// Invalid or backward samples discard the unconfirmed open interval, not prior time.
    mutating func setWaiting(eligible: Bool, now: TimeInterval) {
        guard Self.valid(now), lastUpdate.map({ now >= $0 }) ?? true else {
            // The transition may be a pause whose time is unknown. Do not charge
            // the gap when a subsequent valid sample resumes the clock.
            activeSince = nil
            return
        }
        if let activeSince {
            accumulated += min(Self.timeout - accumulated, now - activeSince)
        }
        activeSince = eligible ? now : nil
        lastUpdate = now
    }

    /// Readiness and backend errors are separate; reaching exactly 15 seconds times out.
    func hasTimedOut(now: TimeInterval) -> Bool {
        if accumulated >= Self.timeout { return true }
        guard let activeSince, Self.valid(now), now >= activeSince else { return false }
        return now - activeSince >= Self.timeout - accumulated
    }

    private static func valid(_ now: TimeInterval) -> Bool {
        now.isFinite && now >= 0
    }
}
