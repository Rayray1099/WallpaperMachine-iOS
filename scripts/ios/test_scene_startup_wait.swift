// SPDX-License-Identifier: GPL-3.0-only
// Compile with SceneStartupWait.swift; Foundation only, no app launch or XCTest.
// swiftc iOS/Sources/Renderer/SceneStartupWait.swift scripts/ios/test_scene_startup_wait.swift -o <scratch>/scene-startup-wait
import Foundation

@main
struct SceneStartupWaitRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: SceneStartupWait: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(description: label) }
            checks += 1
        }

        // No startup time is charged before eligibility, even at a zero clock
        // origin or after hours of inactive/off-window/zero-size health checks.
        var wait = SceneStartupWait()
        try require(!wait.hasTimedOut(now: 100_000), "An unarmed value accrued time")
        wait.reset(now: 0)
        wait.setWaiting(eligible: false, now: 0)
        for now: TimeInterval in [0, 15, 3_600, 86_400] {
            wait.setWaiting(eligible: false, now: now)
            try require(!wait.hasTimedOut(now: now), "Initially ineligible time consumed the deadline")
        }
        wait.setWaiting(eligible: true, now: 86_400)
        try require(!wait.hasTimedOut(now: 86_400), "Attachment inherited ineligible time")
        try require(!wait.hasTimedOut(now: 86_414.999), "Late attachment timed out before 15 active seconds")
        try require(wait.hasTimedOut(now: 86_415), "Exactly 15 eligible seconds must time out")

        // Reproduce the previous wall-time false positive without sampling Date
        // or a real clock: one hour passes while the surface cannot render.
        let previousStart: TimeInterval = 100
        let inactiveEnd: TimeInterval = previousStart + 3_600
        try require(inactiveEnd - previousStart > 15, "Old wall-time baseline did not reproduce")
        wait.reset(now: previousStart)
        wait.setWaiting(eligible: false, now: previousStart)
        try require(!wait.hasTimedOut(now: inactiveEnd), "Inactive hour reproduced the false timeout")
        wait.setWaiting(eligible: true, now: inactiveEnd)
        try require(!wait.hasTimedOut(now: inactiveEnd + 14.999), "First active interval inherited the inactive hour")
        try require(wait.hasTimedOut(now: inactiveEnd + 15), "First active interval failed its deadline")

        // Time accumulates across, rather than restarting at, pauses. Health
        // reads while paused are pure queries and cannot consume more budget.
        wait.reset(now: 0)
        wait.setWaiting(eligible: true, now: 0)
        wait.setWaiting(eligible: false, now: 10)
        try require(!wait.hasTimedOut(now: 3_610), "Paused hour consumed the remaining five seconds")
        wait.setWaiting(eligible: true, now: 3_610)
        try require(!wait.hasTimedOut(now: 3_614.999), "Resumed wait timed out before its remaining five seconds")
        try require(wait.hasTimedOut(now: 3_615), "Ten seconds plus five resumed seconds did not time out")
        wait.setWaiting(eligible: false, now: 3_615)
        try require(wait.hasTimedOut(now: 90_000), "A later pause erased an exhausted deadline")

        // Several independent eligibility interruptions stand in for inactivity,
        // detachment, and zero bounds. The helper need not import UIKit to track them.
        wait.reset(now: 100)
        for (eligible, now) in [(true, 100.0), (false, 103.0), (false, 900.0),
                                (true, 1_000.0), (true, 1_002.0), (false, 1_004.0),
                                (true, 5_000.0), (false, 5_005.0), (true, 9_000.0)] {
            wait.setWaiting(eligible: eligible, now: now)
        }
        try require(!wait.hasTimedOut(now: 9_002.999), "Repeated pauses double-counted eligible time")
        try require(wait.hasTimedOut(now: 9_003), "Multiple eligible intervals did not accumulate to 15 seconds")

        // Duplicate lifecycle updates must not restart or double-count a wait.
        wait.reset(now: 0)
        for now: TimeInterval in [0, 0, 2, 2, 7, 7, 14] {
            wait.setWaiting(eligible: true, now: now)
        }
        try require(!wait.hasTimedOut(now: 14.999), "Duplicate active events double-counted time")
        try require(wait.hasTimedOut(now: 15), "Duplicate active events restarted the deadline")
        wait.setWaiting(eligible: false, now: 15)
        wait.setWaiting(eligible: false, now: 15)
        try require(wait.hasTimedOut(now: 15), "Duplicate pause events reset an elapsed deadline")

        // Lifecycle timestamps determine elapsed time, not health timer cadence.
        // Dense polls, sparse polls, and no polls receive identical transitions.
        var dense = SceneStartupWait()
        dense.reset(now: 0)
        dense.setWaiting(eligible: true, now: 0)
        var sparse = dense
        var noPolls = dense
        for tick in 1...12 {
            let now = Double(tick) * 0.5
            dense.setWaiting(eligible: true, now: now)
            try require(!dense.hasTimedOut(now: now), "Dense health sampling expired the first interval")
        }
        try require(!sparse.hasTimedOut(now: 6), "Sparse health sampling expired the first interval")
        dense.setWaiting(eligible: false, now: 6)
        sparse.setWaiting(eligible: false, now: 6)
        noPolls.setWaiting(eligible: false, now: 6)
        for now: TimeInterval in [6.5, 7, 100, 1_000, 7_200] {
            dense.setWaiting(eligible: false, now: now)
            try require(!dense.hasTimedOut(now: now), "Dense paused polling accrued inactive time")
        }
        dense.setWaiting(eligible: true, now: 7_200)
        sparse.setWaiting(eligible: true, now: 7_200)
        noPolls.setWaiting(eligible: true, now: 7_200)
        for tick in 1...17 {
            let now = 7_200 + Double(tick) * 0.5
            dense.setWaiting(eligible: true, now: now)
            try require(!dense.hasTimedOut(now: now), "Dense polling expired before nine remaining seconds")
        }
        for now: TimeInterval in [7_208.999, 7_209, 7_210] {
            let expected = now >= 7_209
            try require(dense.hasTimedOut(now: now) == expected, "Dense cadence changed the deadline")
            try require(sparse.hasTimedOut(now: now) == expected, "Sparse cadence changed the deadline")
            try require(noPolls.hasTimedOut(now: now) == expected, "No-poll cadence changed the deadline")
        }
        try require(!noPolls.hasTimedOut(now: 7_208), "A later query mutated a pure deadline read")

        // Zero is a valid monotonic origin. Negative, nonfinite and backward
        // samples cannot manufacture elapsed time, including during reset.
        wait.reset(now: 0)
        wait.setWaiting(eligible: true, now: 0)
        try require(!wait.hasTimedOut(now: 0), "Zero origin was not accepted")
        try require(wait.hasTimedOut(now: 15), "Zero-origin active time did not count")
        for invalid: TimeInterval in [-1, -.infinity, .infinity, .nan] {
            wait.reset(now: invalid)
            wait.setWaiting(eligible: true, now: invalid)
            try require(!wait.hasTimedOut(now: 100_000), "Invalid reset or arming sample accrued time")
            wait.setWaiting(eligible: true, now: 10)
            try require(!wait.hasTimedOut(now: invalid), "Invalid query manufactured a timeout")
            try require(!wait.hasTimedOut(now: 24.999), "Invalid initial sample poisoned the recovered origin")
            try require(wait.hasTimedOut(now: 25), "Valid clock did not recover after invalid initialization")
        }
        wait.reset(now: 100)
        wait.setWaiting(eligible: true, now: 100)
        try require(!wait.hasTimedOut(now: 99), "Backward query was counted as positive elapsed time")
        try require(!wait.hasTimedOut(now: .nan), "NaN query produced a timeout")
        try require(!wait.hasTimedOut(now: .infinity), "Infinite query produced a timeout")
        try require(wait.hasTimedOut(now: 115), "Invalid queries mutated the active interval")

        // If a lifecycle transition has no usable timestamp, drop the open
        // interval rather than charging an unknowable paused gap. Preserve time
        // already confirmed by prior monotonic lifecycle events.
        for invalid: TimeInterval in [105, -1, -.infinity, .infinity, .nan] {
            wait.reset(now: 100)
            wait.setWaiting(eligible: true, now: 100)
            wait.setWaiting(eligible: true, now: 110) // Ten confirmed seconds.
            wait.setWaiting(eligible: false, now: invalid)
            try require(!wait.hasTimedOut(now: 10_000), "Rejected pause charged its unknown inactive gap")
            wait.setWaiting(eligible: true, now: 109) // Still older than high-water mark.
            try require(!wait.hasTimedOut(now: 10_000), "Backward resume bypassed the accepted high-water mark")
            wait.setWaiting(eligible: true, now: 1_000)
            try require(!wait.hasTimedOut(now: 1_004.999), "Rejected sample caused an early timeout after recovery")
            try require(wait.hasTimedOut(now: 1_005), "Rejected sample erased confirmed cumulative time")
        }
        wait.reset(now: 100)
        wait.setWaiting(eligible: true, now: 100)
        wait.setWaiting(eligible: true, now: .nan)
        try require(!wait.hasTimedOut(now: 10_000), "Invalid active event left an unconfirmed interval running")
        wait.setWaiting(eligible: true, now: 1_000)
        try require(!wait.hasTimedOut(now: 1_014.999), "Recovery charged an unconfirmed prior interval")
        try require(wait.hasTimedOut(now: 1_015), "Recovery did not arm a fresh valid interval")

        // A reset for a new host/project erases both elapsed time and eligibility.
        wait.reset(now: 20_000)
        try require(!wait.hasTimedOut(now: 100_000), "Reset retained prior eligibility or elapsed time")
        wait.setWaiting(eligible: true, now: 100_000)
        try require(!wait.hasTimedOut(now: 100_014.999), "New project inherited the previous project's deadline")
        try require(wait.hasTimedOut(now: 100_015), "New project failed its own deadline")
        wait.setWaiting(eligible: false, now: 100_015)
        wait.reset(now: 0)
        wait.setWaiting(eligible: true, now: 0)
        try require(!wait.hasTimedOut(now: 14.999), "Reset retained a previous clock's high-water mark")
        try require(wait.hasTimedOut(now: 15), "Reset did not accept a new clock origin")

        // Clamping completed intervals avoids overflow without changing the gate.
        wait.setWaiting(eligible: false, now: .greatestFiniteMagnitude)
        try require(wait.hasTimedOut(now: .greatestFiniteMagnitude), "Large finite elapsed time overflowed the deadline")
        let independent = wait
        wait.reset(now: 0)
        try require(independent.hasTimedOut(now: 0), "Reset mutated another copy of the value")
        try require(!wait.hasTimedOut(now: 1_000), "Reset retained an exhausted copied value's time")

        print("PASS: SceneStartupWait threshold, inactive/attachment/bounds pauses, cumulative resume, polling cadence, invalid/backward clocks, reset and value isolation (\(checks) checks)")
        print("Scope: deterministic Foundation value tests only; no sleeps, UI, device, renderer or real-clock sampling.")
    }
}
