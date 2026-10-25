// SPDX-License-Identifier: GPL-3.0-only
// Compile with the actual SceneHostSession.swift. No UIKit, native engine or I/O fixtures.
import Foundation

@main
struct SceneHostSessionRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: SceneHostSession: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(description: label) }
            checks += 1
        }
        let first = URL(fileURLWithPath: "/isolated-fixture/first/scene.pkg")
        let second = URL(fileURLWithPath: "/isolated-fixture/second/scene.pkg")
        var session = SceneHostSession(url: first)
        try require(session.url == first && !session.attempted && session.failure == nil, "Fresh lifetime")
        try require(!session.select(first), "Same URL must not replace the engine")
        try require(session.beginInitialization(), "First layout may start once")
        try require(!session.beginInitialization(), "Repeated layout must not allocate again")
        try require(!session.select(first) && session.attempted, "Settings-only update must not restart")
        try require(session.recordFailure("specific surface failure"), "First native failure must latch")
        try require(!session.recordFailure("generic health timeout"), "Cleanup/later error must not overwrite cause")
        try require(session.failure == "specific surface failure", "Preserve first diagnostic")
        try require(!session.beginInitialization(), "Failure must not layout-retry")
        session.stop()
        try require(session.failure == "specific surface failure", "Shutdown preserves diagnostic")
        try require(!session.select(first) && !session.beginInitialization(), "Same URL cannot accidentally rearm")
        try require(session.select(second), "Different source must replace lifetime")
        try require(session.url == second && !session.attempted && session.failure == nil, "New URL clears old failure/attempt")
        try require(session.beginInitialization() && !session.beginInitialization(), "New scene gets exactly one attempt")
        try require(session.select(first) && session.beginInitialization(), "Switching back is a new lifetime")

        var neverLaidOut = SceneHostSession(url: first)
        neverLaidOut.stop()
        try require(neverLaidOut.attempted && !neverLaidOut.beginInitialization(), "Dismantle before layout prevents late engine")
        try require(!neverLaidOut.select(first), "Redundant update after stop stays stopped")
        try require(neverLaidOut.select(second) && neverLaidOut.beginInitialization(), "Only source change rearms stopped lifetime")

        var beforeStartFailure = SceneHostSession(url: first)
        try require(beforeStartFailure.recordFailure("resource directory unavailable"), "Preparation failure may precede native allocation")
        try require(!beforeStartFailure.beginInitialization(), "Preparation failure cannot retry on layout")
        try require(beforeStartFailure.select(second) && beforeStartFailure.failure == nil, "New source resets preparation error")
        print("PASS: URL replacement, same-URL retention, one initialization attempt, first-error latch and pre-layout shutdown (\(checks) checks)")
        print("Scope: actual Foundation session-state implementation only; no UIKit, app, GPU or physical-device execution.")
    }
}
