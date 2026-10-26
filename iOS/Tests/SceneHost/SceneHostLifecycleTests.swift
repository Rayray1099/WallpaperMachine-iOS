// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import WMSceneHostHarness
import QuartzCore
import UIKit

final class SceneHostLifecycleTests: XCTestCase {
    @MainActor
    func testPositiveBoundsWithoutWindowDoNotAllocateAnEngine() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.layout(view, size: CGSize(width: 320, height: 200))
            view.readHealth()
            XCTAssertNil(view.window)
            XCTAssertTrue(harness.events.isEmpty)
            XCTAssertFalse(try harness.status(in: view).isHidden)
        }
    }

    @MainActor
    func testAttachmentUsesPhysicalPixelsAndSetsQualityBeforeConfig() async throws {
        try await withHarness { harness in
            let view = harness.makeView(settings: playback(renderScale: 0.5))
            harness.attach(view)

            let surface = try XCTUnwrap(harness.events("init_metal").first)
            let quality = try XCTUnwrap(harness.events("render_scale").first)
            let config = try XCTUnwrap(harness.events("apply_config").first)
            XCTAssertEqual(surface.outputSize, CGSize(width: 640, height: 400))
            XCTAssertEqual(surface.renderSize, CGSize(width: 320, height: 200))
            XCTAssertEqual(surface.displayScale, 2)
            XCTAssertEqual(surface.layer, Unmanaged.passUnretained(view.layer).toOpaque())
            XCTAssertEqual(try harness.layer(in: view).drawableSize, surface.outputSize)
            XCTAssertEqual(try harness.layer(in: view).contentsScale, 2)
            XCTAssertEqual(quality.renderScale, 0.5)
            let operations = harness.events.map(\.operation)
            XCTAssertLessThan(try XCTUnwrap(operations.firstIndex(of: "init")),
                              try XCTUnwrap(operations.firstIndex(of: "init_metal")))
            XCTAssertLessThan(try XCTUnwrap(operations.firstIndex(of: "init_metal")),
                              try XCTUnwrap(operations.firstIndex(of: "render_scale")))
            XCTAssertLessThan(try XCTUnwrap(operations.firstIndex(of: "render_scale")),
                              try XCTUnwrap(operations.firstIndex(of: "apply_config")))
            XCTAssertEqual(config.source, harness.projectJSON.path)
            XCTAssertEqual(config.assets, harness.assets.path)
            XCTAssertEqual(config.cachePath, "")
            XCTAssertFalse(config.paused)
            XCTAssertEqual(harness.events("new").count, 1)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
        }
    }

    @MainActor
    func testSameURLSettingsAndQualityReuseTheEngineAndDrawable() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let serial = try XCTUnwrap(harness.events("new").first).serial
            let drawable = try harness.layer(in: view).drawableSize
            let baseline = harness.events.count
            var settings = playback(renderScale: 0.5)
            settings.framesPerSecond = 30
            settings.volume = 0.25
            settings.isMuted = false
            settings.scaling = "fill"
            settings.microphoneEnabled = true
            let properties = ["speed": WallpaperProperty(label: "Speed", type: "slider", value: .number(2))]

            view.apply(url: harness.urlA, settings: settings, properties: properties)
            harness.layout(view)

            let changes = Array(harness.events.dropFirst(baseline))
            XCTAssertTrue(changes.allSatisfy { $0.serial == serial })
            XCTAssertEqual(changes.filter { $0.operation == "render_scale" }.map(\.renderScale), [0.5])
            XCTAssertEqual(changes.last { $0.operation == "fps" }?.fps, 30)
            XCTAssertEqual(changes.last { $0.operation == "volume" }?.volume, 0.25)
            XCTAssertEqual(changes.last { $0.operation == "muted" }?.muted, false)
            XCTAssertEqual(changes.last { $0.operation == "set_property_int32" }?.int32Value, 3)
            XCTAssertEqual(changes.last { $0.operation == "set_property_bool" }?.boolValue, true)
            let json = try XCTUnwrap(changes.last { $0.operation == "set_property_string" }?.stringValue)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber])
            XCTAssertEqual(object["speed"]?.doubleValue, 2)
            XCTAssertEqual(try harness.layer(in: view).drawableSize, drawable)
            XCTAssertEqual(harness.events("new").count, 1)
            XCTAssertEqual(harness.events("apply_config").count, 1)
            XCTAssertTrue(harness.events("delete").isEmpty)
            XCTAssertTrue(harness.events("begin").isEmpty)
            XCTAssertTrue(harness.events("finish").isEmpty)
        }
    }

    @MainActor
    func testNewURLDeletesOldEngineOnceAndResetsQualityAndReadiness() async throws {
        try await withHarness { harness in
            let settings = playback(renderScale: 0.5)
            let view = harness.makeView(settings: settings)
            harness.attach(view)
            let first = try XCTUnwrap(harness.events("new").first).serial
            harness.presentedFrames(1)
            view.readHealth()
            XCTAssertTrue(try harness.status(in: view).isHidden)
            harness.presentedFrames(0)
            let baseline = harness.events.count

            view.apply(url: harness.urlB, settings: settings, properties: [:])
            harness.layout(view)

            let second = try XCTUnwrap(harness.events("new").last).serial
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(harness.events("shutdown").map(\.serial), [first])
            XCTAssertEqual(harness.events("delete").map(\.serial), [first])
            XCTAssertEqual(harness.events("render_scale").map(\.renderScale), [0.5, 0.5])
            XCTAssertEqual(harness.events("apply_config").last?.source, harness.urlB.path)
            let operations = harness.events.dropFirst(baseline).map(\.operation)
            XCTAssertEqual(Array(operations.prefix(3)), ["shutdown", "delete", "new"])
            XCTAssertFalse(try harness.status(in: view).isHidden)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
        }
    }

    @MainActor
    func testFailedURLDoesNotRetryButAnotherURLRecovers() async throws {
        try await withHarness { harness in
            let message = "injected invalid scene configuration"
            wm_scene_test_fail_next("apply_config", message)
            let view = harness.makeView()
            harness.attach(view)
            let label = try harness.status(in: view)
            XCTAssertEqual(label.text, message)
            XCTAssertFalse(label.isHidden)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            let baseline = harness.events.count

            view.apply(url: harness.urlA, settings: playback(renderScale: 0.5), properties: [:])
            harness.layout(view)
            view.readHealth()
            XCTAssertEqual(harness.events.count, baseline)
            XCTAssertEqual(label.text, message)

            view.apply(url: harness.urlB, settings: playback(renderScale: 0.5), properties: [:])
            harness.layout(view)
            XCTAssertEqual(harness.events("new").count, 2)
            XCTAssertEqual(harness.events("delete").count, 1)
            XCTAssertEqual(harness.events("apply_config").last?.source, harness.urlB.path)
            XCTAssertEqual(harness.events("render_scale").last?.renderScale, 0.5)
            XCTAssertNotEqual(label.text, message)
            harness.presentedFrames(1)
            view.readHealth()
            XCTAssertTrue(label.isHidden)
        }
    }

    @MainActor
    func testShutdownBeforeFirstLayoutPreventsQueuedInitialization() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            view.shutdown()
            harness.attach(view)
            harness.layout(view)
            view.apply(url: harness.urlA, settings: playback(), properties: [:])
            view.readHealth()
            XCTAssertTrue(harness.events.isEmpty)
        }
    }

    @MainActor
    func testZeroSizeDefersQualityUntilPositiveLayoutWithoutRebuildingSurface() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let baseline = harness.events.count
            harness.layout(view, size: .zero)
            view.apply(url: harness.urlA, settings: playback(renderScale: 0.5), properties: [:])
            XCTAssertEqual(harness.events("render_scale").map(\.renderScale), [1])
            XCTAssertEqual(harness.events.dropFirst(baseline).map(\.operation), ["pause"])
            XCTAssertEqual(harness.events("pause").last?.paused, true)

            harness.layout(view, size: CGSize(width: 320, height: 200))

            XCTAssertEqual(harness.events("render_scale").map(\.renderScale), [1, 0.5])
            XCTAssertEqual(harness.events("pause").last?.paused, false)
            XCTAssertEqual(try harness.layer(in: view).drawableSize, CGSize(width: 640, height: 400))
            XCTAssertTrue(harness.events("begin").isEmpty)
            XCTAssertTrue(harness.events("finish").isEmpty)
            XCTAssertEqual(harness.events("new").count, 1)
        }
    }

    @MainActor
    func testEqualBoundsDisplayScaleChangeReconfiguresPhysicalPixelsOnSameEngine() async throws {
        try await withHarness { harness in
            let view = harness.makeView(settings: playback(renderScale: 0.5))
            harness.attach(view)
            let serial = try XCTUnwrap(harness.events("new").first).serial
            let pointSize = view.bounds.size
            let baseline = harness.events.count

            harness.clock.scale = 3
            // Exercise the real layout/reconfigure path with unchanged point bounds.
            // Real UIScreen/trait notification delivery remains a separate runtime gate.
            harness.layout(view)

            let changes = Array(harness.events.dropFirst(baseline))
            XCTAssertEqual(view.bounds.size, pointSize)
            XCTAssertEqual(changes.map(\.operation), ["begin", "finish"])
            XCTAssertTrue(changes.allSatisfy { $0.serial == serial })
            let surface = try XCTUnwrap(changes.last)
            XCTAssertEqual(surface.outputSize, CGSize(width: 960, height: 600))
            XCTAssertEqual(surface.renderSize, CGSize(width: 480, height: 300))
            XCTAssertEqual(surface.displayScale, 3)
            XCTAssertEqual(surface.layer, Unmanaged.passUnretained(view.layer).toOpaque())
            XCTAssertEqual(try harness.layer(in: view).drawableSize, surface.outputSize)
            XCTAssertEqual(try harness.layer(in: view).contentsScale, 3)
            XCTAssertEqual(harness.events("render_scale").map(\.renderScale), [0.5])
            XCTAssertEqual(harness.events("init_metal").count, 1)
            XCTAssertEqual(harness.events("new").count, 1)
            XCTAssertEqual(harness.events("apply_config").count, 1)
            XCTAssertTrue(harness.events("delete").isEmpty)
            let afterReconfigure = harness.events.count
            harness.layout(view)
            XCTAssertEqual(harness.events.count, afterReconfigure)
        }
    }

    @MainActor
    func testDetachedEnginePausesAndDefersSettingsUntilReattachment() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let serial = try XCTUnwrap(harness.events("new").first).serial
            let drawable = try harness.layer(in: view).drawableSize
            let baseline = harness.events.count

            view.removeFromSuperview()
            XCTAssertNil(view.window)
            var settings = playback(renderScale: 0.5)
            settings.framesPerSecond = 30
            settings.volume = 0.25
            settings.isMuted = false
            settings.scaling = "fill"
            settings.microphoneEnabled = true
            let properties = ["speed": WallpaperProperty(label: "Speed", type: "slider", value: .number(3))]
            view.apply(url: harness.urlA, settings: settings, properties: properties)
            harness.layout(view)

            let detached = Array(harness.events.dropFirst(baseline))
            XCTAssertEqual(detached.map(\.operation), ["pause"])
            XCTAssertEqual(detached.first?.paused, true)
            XCTAssertEqual(detached.first?.serial, serial)
            XCTAssertEqual(harness.events("render_scale").map(\.renderScale), [1])
            XCTAssertEqual(try harness.layer(in: view).drawableSize, drawable)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
            let beforeReattach = harness.events.count

            try harness.reattach(view)

            let changes = Array(harness.events.dropFirst(beforeReattach))
            XCTAssertNotNil(view.window)
            XCTAssertTrue(changes.allSatisfy { $0.serial == serial })
            XCTAssertEqual(changes.filter { $0.operation == "pause" }.map(\.paused), [false])
            XCTAssertEqual(changes.filter { $0.operation == "render_scale" }.map(\.renderScale), [0.5])
            XCTAssertEqual(changes.last { $0.operation == "fps" }?.fps, 30)
            XCTAssertEqual(changes.last { $0.operation == "volume" }?.volume, 0.25)
            XCTAssertEqual(changes.last { $0.operation == "muted" }?.muted, false)
            XCTAssertEqual(changes.last { $0.operation == "set_property_int32" }?.int32Value, 3)
            XCTAssertEqual(changes.last { $0.operation == "set_property_bool" }?.boolValue, true)
            let json = try XCTUnwrap(changes.last { $0.operation == "set_property_string" }?.stringValue)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber])
            XCTAssertEqual(object["speed"]?.doubleValue, 3)
            XCTAssertEqual(try harness.layer(in: view).drawableSize, drawable)
            XCTAssertEqual(harness.events("new").count, 1)
            XCTAssertEqual(harness.events("apply_config").count, 1)
            XCTAssertTrue(harness.events("begin").isEmpty)
            XCTAssertTrue(harness.events("finish").isEmpty)
            XCTAssertTrue(harness.events("delete").isEmpty)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
        }
    }

    @MainActor
    func testStartupDeadlineAccumulatesTenActiveSecondsThenFiveAfterHoursPaused() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let label = try harness.status(in: view)
            let waiting = label.text
            harness.clock.now = 10
            view.readHealth()
            XCTAssertEqual(label.text, waiting)
            view.setApplicationActive(false)
            harness.clock.now += 10 * 60 * 60
            view.readHealth()
            XCTAssertEqual(label.text, waiting)
            view.setApplicationActive(true)
            harness.clock.now += 4.999
            view.readHealth()
            XCTAssertEqual(label.text, waiting)
            harness.clock.now = 10 + 10 * 60 * 60 + 5
            view.readHealth()
            XCTAssertFalse(label.isHidden)
            XCTAssertNotEqual(label.text, waiting)
            XCTAssertFalse(try XCTUnwrap(label.text).isEmpty)
            XCTAssertEqual(Array(harness.events("pause").suffix(2)).map(\.paused), [true, false])
        }
    }

    @MainActor
    func testCompletedFramesDoNotHideStatusUntilAFrameIsPresented() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let label = try harness.status(in: view)
            wm_scene_test_set_health(100, 0, 0, UInt64.max, 0)
            view.readHealth()
            XCTAssertFalse(label.isHidden)
            harness.clock.now = 15
            view.readHealth()
            XCTAssertFalse(label.isHidden)

            wm_scene_test_set_health(100, 1, 0, 0, 0)
            view.readHealth()
            XCTAssertTrue(label.isHidden)
            XCTAssertEqual(harness.events("health").count, 3)
        }
    }

    @MainActor
    func testBackendReasonWinsOverOldPresentedFramesAndDeadline() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            harness.presentedFrames(100)
            view.readHealth()
            let label = try harness.status(in: view)
            XCTAssertTrue(label.isHidden)
            let healthQueries = harness.events("health").count
            let reason = "injected command-buffer backend failure"
            wm_scene_test_set_backend_reason(reason)
            harness.clock.now = 1000

            view.readHealth()

            XCTAssertFalse(label.isHidden)
            XCTAssertEqual(label.text, reason)
            XCTAssertEqual(harness.events("health").count, healthQueries)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
        }
    }

    @MainActor
    func testFinishFailureAfterAnOldFrameIsTerminalAndNeverUsesDeletedHandle() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            harness.presentedFrames(1)
            view.readHealth()
            let label = try harness.status(in: view)
            XCTAssertTrue(label.isHidden)
            let message = "injected surface rebuild failure"
            wm_scene_test_fail_next("finish", message)

            harness.layout(view, size: CGSize(width: 400, height: 240))

            XCTAssertEqual(harness.events("begin").count, 1)
            XCTAssertEqual(harness.events("finish").last?.result, 1)
            XCTAssertEqual(harness.events("shutdown").count, 1)
            XCTAssertEqual(harness.events("delete").count, 1)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            XCTAssertFalse(label.isHidden)
            XCTAssertEqual(label.text, message)
            let baseline = harness.events.count
            view.readHealth()
            harness.layout(view)
            view.apply(url: harness.urlA, settings: playback(renderScale: 0.5), properties: [:])
            view.setApplicationActive(false)
            view.setApplicationActive(true)
            view.shutdown()
            XCTAssertEqual(harness.events.count, baseline)
            XCTAssertFalse(label.isHidden)
            XCTAssertEqual(label.text, message)
            XCTAssertEqual(wm_scene_test_invalid_handle_calls(), 0)
        }
    }

    @MainActor
    func testSuccessfulAllocationReturningNullShowsFailureWithoutInitializingEngine() async throws {
        try await withHarness { harness in
            wm_scene_test_return_null_handle(true)
            let view = harness.makeView()
            let waiting = try harness.status(in: view).text
            harness.attach(view)
            let label = try harness.status(in: view)
            XCTAssertFalse(label.isHidden)
            XCTAssertNotEqual(label.text, waiting)
            XCTAssertFalse(try XCTUnwrap(label.text).isEmpty)
            XCTAssertEqual(harness.events.map(\.operation), ["new"])
            XCTAssertEqual(harness.events("new").first?.serial, 0)
            XCTAssertEqual(harness.events("new").first?.result, 0)
            harness.layout(view)
            view.readHealth()
            view.apply(url: harness.urlA, settings: playback(), properties: [:])
            XCTAssertEqual(harness.events.map(\.operation), ["new"])
        }
    }

    @MainActor
    func testInitialAPIFailureStopsBeforeMetalAndConfigurationAndCleansUpOnce() async throws {
        try await withHarness { harness in
            let message = "injected native initialization failure"
            wm_scene_test_fail_next("init", message)
            let view = harness.makeView()
            harness.attach(view)
            XCTAssertEqual(harness.events.map(\.operation), ["new", "init", "shutdown", "delete"])
            XCTAssertEqual(harness.events("init").first?.result, 1)
            XCTAssertEqual(try harness.status(in: view).text, message)
            XCTAssertFalse(try harness.status(in: view).isHidden)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            harness.layout(view)
            view.readHealth()
            view.apply(url: harness.urlA, settings: playback(), properties: [:])
            XCTAssertEqual(harness.events.map(\.operation), ["new", "init", "shutdown", "delete"])
        }
    }

    @MainActor
    func testReconfigurationReleasesOldLayerSizeBeforePublishingNewSize() async throws {
        try await withHarness { harness in
            let view = harness.makeView(settings: playback(renderScale: 0.5))
            harness.attach(view)
            let observation = SurfaceObservation(layer: try harness.layer(in: view))
            withExtendedLifetime(observation) {
                wm_scene_test_set_observer({ operation, context in
                    guard let operation, let context else { return }
                    // The recorder calls synchronously from this MainActor-only test.
                    MainActor.assumeIsolated {
                        let observation = Unmanaged<SurfaceObservation>.fromOpaque(context).takeUnretainedValue()
                        observation.record(String(cString: operation))
                    }
                }, Unmanaged.passUnretained(observation).toOpaque())
                defer { wm_scene_test_set_observer(nil, nil) }
                harness.layout(view, size: CGSize(width: 400, height: 240))
            }

            XCTAssertEqual(observation.samples.map(\.operation), ["begin", "finish"])
            XCTAssertEqual(observation.samples.map(\.size), [CGSize(width: 640, height: 400), CGSize(width: 800, height: 480)])
            let finish = try XCTUnwrap(harness.events("finish").first)
            XCTAssertEqual(finish.outputSize, CGSize(width: 800, height: 480))
            XCTAssertEqual(finish.renderSize, CGSize(width: 400, height: 240))
            XCTAssertEqual(finish.displayScale, 2)
            XCTAssertEqual(finish.layer, Unmanaged.passUnretained(view.layer).toOpaque())
            XCTAssertEqual(harness.events("init_metal").count, 1)
            XCTAssertEqual(harness.events("new").count, 1)
            XCTAssertTrue(harness.events("delete").isEmpty)
        }
    }
    @MainActor
    func testAssetInstallationClosesEveryReaderAndBlocksNewInitialization() async throws {
        try await withHarness { harness in
            let first = harness.makeView()
            let second = harness.makeView()
            harness.attach(first)
            harness.attach(second)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 2)
            let coordinator = SceneSharedAssetsCoordinator.shared
            let token = try coordinator.beginAssetInstallation()
            defer { coordinator.endAssetInstallation(token: token) }
            XCTAssertTrue(coordinator.isInstallingAssets)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            XCTAssertEqual(harness.events("shutdown").count, 2)
            XCTAssertEqual(harness.events("delete").count, 2)
            let baseline = harness.events.count
            let added = harness.makeView()
            harness.attach(added)
            for view in [first, second, added] {
                harness.layout(view)
                view.apply(url: harness.urlA, settings: playback(), properties: [:])
                view.readHealth()
            }
            XCTAssertEqual(harness.events.count, baseline)
            coordinator.endAssetInstallation(token: token)
            for view in [first, second, added] { harness.layout(view) }
            XCTAssertEqual(wm_scene_test_live_handle_count(), 3)
        }
    }

    @MainActor
    func testAssetInstallationRearmsSameURLAndFailedSessionWithoutOldReadiness() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            harness.presentedFrames(1)
            view.readHealth()
            XCTAssertTrue(try harness.status(in: view).isHidden)
            let coordinator = SceneSharedAssetsCoordinator.shared
            var token = try coordinator.beginAssetInstallation()
            coordinator.endAssetInstallation(token: token)
            XCTAssertFalse(try harness.status(in: view).isHidden)
            harness.presentedFrames(0)
            harness.layout(view)
            XCTAssertEqual(harness.events("new").count, 2)
            XCTAssertEqual(harness.events("apply_config").last?.source, harness.projectJSON.path)
            wm_scene_test_fail_next("render_scale", "old resources unavailable")
            view.apply(url: harness.urlA, settings: playback(renderScale: 0.5), properties: [:])
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            let baseline = harness.events.count
            harness.layout(view)
            XCTAssertEqual(harness.events.count, baseline)
            token = try coordinator.beginAssetInstallation()
            coordinator.endAssetInstallation(token: token)
            harness.layout(view)
            XCTAssertEqual(harness.events("new").count, 3)
            XCTAssertEqual(harness.events("render_scale").last?.renderScale, 0.5)
            XCTAssertFalse(try harness.status(in: view).isHidden)
            harness.presentedFrames(1)
            view.readHealth()
            XCTAssertTrue(try harness.status(in: view).isHidden)
        }
    }

    @MainActor
    func testStaleInstallationTokenCannotReleaseAnotherPublicationGate() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let coordinator = SceneSharedAssetsCoordinator.shared
            let first = try coordinator.beginAssetInstallation()
            coordinator.endAssetInstallation(token: first)
            harness.layout(view)
            let second = try coordinator.beginAssetInstallation()
            defer { coordinator.endAssetInstallation(token: second) }
            let baseline = harness.events.count
            coordinator.endAssetInstallation(token: first)
            coordinator.endAssetInstallation(token: UUID())
            harness.layout(view)
            XCTAssertTrue(coordinator.isInstallingAssets)
            XCTAssertEqual(harness.events.count, baseline)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            coordinator.endAssetInstallation(token: second)
            harness.layout(view)
            XCTAssertFalse(coordinator.isInstallingAssets)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
        }
    }

    @MainActor
    func testDismantledAndExplicitlyStoppedSurfacesNeverReviveAfterAssetsChange() async throws {
        try await withHarness { harness in
            let retired = harness.makeView()
            let stopped = harness.makeView()
            let uninitialized = harness.makeView()
            harness.attach(retired)
            harness.attach(stopped)
            stopped.shutdown()
            uninitialized.shutdown()
            let coordinator = SceneSharedAssetsCoordinator.shared
            let token = try coordinator.beginAssetInstallation()
            SceneWallpaperView.dismantleUIView(retired, coordinator: ())
            coordinator.endAssetInstallation(token: token)
            let baseline = harness.events.count
            harness.attach(uninitialized)
            for view in [retired, stopped, uninitialized] {
                harness.layout(view)
                view.apply(url: harness.urlA, settings: playback(), properties: [:])
                view.readHealth()
            }
            // Even a new URL cannot revive a permanently dismantled view.
            retired.apply(url: harness.urlB, settings: playback(), properties: [:])
            harness.layout(retired)
            XCTAssertEqual(harness.events.count, baseline)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
        }
    }

    @MainActor
    func testSceneExportLeaseAndAssetPublicationAreMutuallyExclusive() async throws {
        try await withHarness { harness in
            let view = harness.makeView()
            harness.attach(view)
            let coordinator = SceneSharedAssetsCoordinator.shared
            let export = try coordinator.beginExport()
            defer { coordinator.endExport(token: export) }
            let baseline = harness.events.count
            XCTAssertThrowsError(try coordinator.beginAssetInstallation())
            XCTAssertThrowsError(try coordinator.beginExport())
            coordinator.endExport(token: UUID())
            XCTAssertThrowsError(try coordinator.beginAssetInstallation())
            XCTAssertEqual(harness.events.count, baseline)
            coordinator.endExport(token: export)
            let install = try coordinator.beginAssetInstallation()
            defer { coordinator.endAssetInstallation(token: install) }
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            XCTAssertThrowsError(try coordinator.beginExport())
            XCTAssertThrowsError(try coordinator.beginAssetInstallation())
            coordinator.endAssetInstallation(token: install)
            let nextExport = try coordinator.beginExport()
            coordinator.endExport(token: nextExport)
            harness.layout(view)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 1)
        }
    }
    @MainActor
    func testManualExportModeEnabledBeforeInitAndWaitsForPreparedStatusWithoutPresentedFrame() async throws {
        try await withHarness { harness in
            let view = harness.makeView(exportFrameRate: 60)
            harness.attach(view)
            let operations = harness.events.map(\.operation)
            XCTAssertEqual(harness.events("enable_frame_export").map(\.fps), [60])
            XCTAssertLessThan(try XCTUnwrap(operations.firstIndex(of: "enable_frame_export")),
                              try XCTUnwrap(operations.firstIndex(of: "init")))
            XCTAssertLessThan(try XCTUnwrap(operations.firstIndex(of: "init")),
                              try XCTUnwrap(operations.firstIndex(of: "apply_config")))
            XCTAssertEqual(view.offlineFrameRate, 60)
            XCTAssertFalse(view.isOfflineFrameCaptureReady)
            XCTAssertFalse(view.isFrameCaptureReady)
            harness.presentedFrames(100)
            XCTAssertFalse(view.isOfflineFrameCaptureReady, "Live health cannot invent manual preparation")
            harness.presentedFrames(0)
            wm_scene_test_set_export_status(1)
            XCTAssertTrue(view.isOfflineFrameCaptureReady, "Index zero must not wait for a frame that only a request can produce")
            XCTAssertFalse(view.isFrameCaptureReady, "Manual capture must never fall through to live snapshot capture")
            let healthCalls = harness.events("health").count
            harness.clock.now = 3_600
            view.readHealth()
            XCTAssertTrue(view.isOfflineFrameCaptureReady)
            XCTAssertEqual(harness.events("health").count, healthCalls)
            XCTAssertTrue(harness.events("request_export_frame").isEmpty, "Readiness queries must not render frames")
            wm_scene_test_set_export_status(-1)
            XCTAssertFalse(view.isOfflineFrameCaptureReady)
            let diagnosis = "injected manual-export command-buffer failure"
            wm_scene_test_set_backend_reason(diagnosis)
            XCTAssertEqual(view.frameCaptureFailure, diagnosis,
                           "A failed native frame must not be mislabeled as an unsupported scene")
            view.readHealth()
            XCTAssertEqual(try harness.status(in: view).text, diagnosis)
            XCTAssertFalse(try harness.status(in: view).isHidden)
            wm_scene_test_set_backend_reason("")
            XCTAssertEqual(view.frameCaptureFailure,
                           NSLocalizedString("scene.offline.nativeFailed", comment: ""))
        }
    }

    @MainActor
    func testManualExportEnableFailureStopsBeforeInitAndCleansAllocatedHandle() async throws {
        try await withHarness { harness in
            wm_scene_test_fail_next("enable_frame_export", "injected manual clock failure")
            let view = harness.makeView(exportFrameRate: 60)
            harness.attach(view)
            XCTAssertEqual(harness.events("enable_frame_export").count, 1)
            XCTAssertTrue(harness.events("init").isEmpty)
            XCTAssertTrue(harness.events("init_metal").isEmpty)
            XCTAssertTrue(harness.events("apply_config").isEmpty)
            XCTAssertEqual(harness.events("shutdown").count, 1)
            XCTAssertEqual(harness.events("delete").count, 1)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
            XCTAssertFalse(view.isOfflineFrameCaptureReady)
            XCTAssertEqual(try harness.status(in: view).text, "injected manual clock failure")
            let baseline = harness.events.count
            harness.layout(view)
            view.readHealth()
            XCTAssertEqual(harness.events.count, baseline, "Failed manual initialization must not loop")
        }
    }

    @MainActor
    func testManualExportFinishClosesOnceAndLiveSessionsNeverUseManualABI() async throws {
        try await withHarness { harness in
            let live = harness.makeView()
            harness.attach(live)
            let liveSerial = try XCTUnwrap(harness.events("new").last).serial
            XCTAssertTrue(harness.events("enable_frame_export").isEmpty)
            XCTAssertFalse(live.isOfflineFrameCaptureReady)
            XCTAssertFalse(harness.events.contains { $0.serial == liveSerial && $0.operation == "frame_export_status" })
            live.shutdown()
            let manual = harness.makeView(exportFrameRate: 60)
            harness.attach(manual)
            let manualSerial = try XCTUnwrap(harness.events("new").last).serial
            wm_scene_test_set_export_status(1)
            XCTAssertTrue(manual.isOfflineFrameCaptureReady)
            manual.finishOfflineCapture()
            manual.finishOfflineCapture()
            XCTAssertFalse(manual.isOfflineFrameCaptureReady)
            XCTAssertEqual(harness.events("shutdown").filter { $0.serial == manualSerial }.count, 1)
            XCTAssertEqual(harness.events("delete").filter { $0.serial == manualSerial }.count, 1)
            let baseline = harness.events.count
            manual.apply(url: harness.urlA, settings: playback(), properties: [:])
            harness.layout(manual)
            manual.readHealth()
            XCTAssertEqual(harness.events.count, baseline)
            XCTAssertTrue(harness.events("request_export_frame").isEmpty)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
        }
    }
    @MainActor
    func testPreparedManualSessionIgnoresIdenticalUpdatesButEndsOnChangedSettings() async throws {
        try await withHarness { harness in
            let settings = playback()
            let view = harness.makeView(settings: settings, exportFrameRate: 60)
            harness.attach(view)
            let serial = try XCTUnwrap(harness.events("new").last).serial
            wm_scene_test_set_export_status(1)
            XCTAssertTrue(view.isOfflineFrameCaptureReady)
            let baseline = harness.events.count
            view.apply(url: harness.urlA, settings: settings, properties: [:])
            let updates = Array(harness.events.dropFirst(baseline))
            XCTAssertFalse(updates.isEmpty)
            XCTAssertTrue(updates.allSatisfy { $0.operation == "frame_export_status" },
                          "Identical SwiftUI updates cannot resend manual-session properties or quality")
            var changed = settings
            changed.renderScale = 0.5
            view.apply(url: harness.urlA, settings: changed, properties: [:])
            XCTAssertFalse(view.isOfflineFrameCaptureReady)
            XCTAssertEqual(harness.events("shutdown").filter { $0.serial == serial }.count, 1)
            XCTAssertEqual(harness.events("delete").filter { $0.serial == serial }.count, 1)
            let afterTermination = harness.events.count
            view.apply(url: harness.urlB, settings: settings, properties: [:])
            harness.layout(view)
            view.readHealth()
            XCTAssertEqual(harness.events.count, afterTermination, "Another URL must not revive a consumed manual export session")
            XCTAssertEqual(harness.events("new").count, 1)
            XCTAssertEqual(wm_scene_test_live_handle_count(), 0)
        }
    }
}

private func playback(renderScale: Double = 1) -> PlaybackSettings {
    var settings = PlaybackSettings()
    settings.renderScale = renderScale
    return settings
}

/// Every test's assertions and teardown run in one uninterrupted actor turn.
/// Yield first so queued application-notification tasks from the previous test settle.
@MainActor
private func withHarness(_ body: @MainActor (Harness) throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
    await Task.yield()
    XCTAssertEqual(wm_scene_test_live_handle_count(), 0, file: file, line: line)
    XCTAssertEqual(wm_scene_test_invalid_handle_calls(), 0, file: file, line: line)
    guard wm_scene_test_reset() else {
        XCTFail("Previous test left a live native handle", file: file, line: line)
        throw HarnessError.liveHandleAtStart
    }
    let harness = try Harness()
    defer { harness.cleanup(file: file, line: line) }
    try body(harness)
}

private enum HarnessError: Error {
    case liveHandleAtStart
    case unsafeTemporaryDirectory
}

@MainActor
private final class Clock {
    var now: Double = 0
    var scale: Double = 2
}

@MainActor
private final class Harness {
    let clock = Clock()
    let temporaryDirectory: OwnedTemporaryDirectory
    let assets: URL
    let projectJSON: URL
    let urlA: URL
    let urlB: URL
    private var views: [SceneMetalSurface] = []
    private var windows: [UIWindow] = []

    init() throws {
        let directory = try OwnedTemporaryDirectory()
        temporaryDirectory = directory
        assets = directory.url.appendingPathComponent("assets", isDirectory: true)
        let firstProject = directory.url.appendingPathComponent("A", isDirectory: true)
        let secondProject = directory.url.appendingPathComponent("B", isDirectory: true)
        projectJSON = firstProject.appendingPathComponent("project.json")
        urlA = firstProject.appendingPathComponent("scene.pkg")
        urlB = secondProject.appendingPathComponent("scene.pkg")
        do {
            for child in [assets, firstProject, secondProject] {
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            }
            // A exercises project.json selection; B exercises the original URL.
            // The native recorder never reads either source or any licensed assets.
            try Data("{\"file\":\"scene.pkg\",\"type\":\"scene\"}".utf8).write(to: projectJSON)
        } catch {
            try directory.remove()
            throw error
        }
    }

    var events: [NativeEvent] {
        (0..<Int(wm_scene_test_event_count())).compactMap { index in
            // Copy the C struct and its strings before a later reset frees them.
            wm_scene_test_event_at(index).map { NativeEvent($0.pointee) }
        }
    }

    func events(_ operation: String) -> [NativeEvent] {
        events.filter { $0.operation == operation }
    }

    func makeView(settings: PlaybackSettings = PlaybackSettings(), exportFrameRate: Int? = nil) -> SceneMetalSurface {
        let clock = clock
        let assets = assets
        let environment = SceneHostEnvironment(
            now: { clock.now },
            prepareResources: { SceneResourceDirectories(sharedAssets: assets, shaderCache: nil) },
            initiallyActive: { true },
            prepareMetal: { _ in },
            metalAvailable: { _ in true },
            displayScale: { _ in clock.scale },
            automaticallyPollHealth: false
        )
        let view = SceneMetalSurface(url: urlA, settings: settings, properties: [:], environment: environment,
                                     exportFrameRate: exportFrameRate)
        views.append(view)
        return view
    }

    func attach(_ view: SceneMetalSurface) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1210))
        let controller = UIViewController()
        window.rootViewController = controller
        windows.append(window)
        window.isHidden = false
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        controller.view.addSubview(view)
        view.setApplicationActive(true)
        window.layoutIfNeeded()
        layout(view)
        XCTAssertNotNil(view.window)
    }

    func reattach(_ view: SceneMetalSurface) throws {
        let window = try XCTUnwrap(windows.last)
        let controller = try XCTUnwrap(window.rootViewController)
        controller.view.addSubview(view)
        window.layoutIfNeeded()
        layout(view)
    }

    func layout(_ view: SceneMetalSurface, size: CGSize? = nil) {
        if let size { view.frame.size = size }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func status(in view: SceneMetalSurface) throws -> UILabel {
        try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first {
            $0.accessibilityIdentifier == "wm.scene.status"
        })
    }

    func layer(in view: SceneMetalSurface) throws -> CAMetalLayer {
        try XCTUnwrap(view.layer as? CAMetalLayer)
    }

    func presentedFrames(_ count: UInt64) {
        wm_scene_test_set_health(count, count, 0, count > 0 ? 0 : UInt64.max, 0)
    }

    func cleanup(file: StaticString, line: UInt) {
        wm_scene_test_set_observer(nil, nil)
        for view in views {
            view.retire()
            view.removeFromSuperview()
        }
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        views.removeAll()
        windows.removeAll()
        XCTAssertEqual(wm_scene_test_live_handle_count(), 0, file: file, line: line)
        XCTAssertEqual(wm_scene_test_invalid_handle_calls(), 0, file: file, line: line)
        XCTAssertTrue(wm_scene_test_reset(), file: file, line: line)
        do {
            try temporaryDirectory.remove()
        } catch {
            XCTFail("Could not remove this test's owned temporary directory: \(error)", file: file, line: line)
        }
    }
}

/// Owns exactly one fresh child of NSTemporaryDirectory; never removes its parent.
private final class OwnedTemporaryDirectory {
    let url: URL
    private let parent: URL
    private let name: String

    init() throws {
        parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        name = "WMSceneHost-" + UUID().uuidString
        url = parent.appendingPathComponent(name, isDirectory: true)
        guard url.deletingLastPathComponent().path == parent.path else { throw HarnessError.unsafeTemporaryDirectory }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() throws {
        guard url.lastPathComponent == name, url.deletingLastPathComponent().path == parent.path,
              url.standardizedFileURL.resolvingSymlinksInPath().path == url.path else {
            throw HarnessError.unsafeTemporaryDirectory
        }
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor
private final class SurfaceObservation {
    struct Sample {
        let operation: String
        let size: CGSize
    }
    let layer: CAMetalLayer
    var samples: [Sample] = []

    init(layer: CAMetalLayer) { self.layer = layer }

    func record(_ operation: String) {
        guard operation == "begin" || operation == "finish" else { return }
        samples.append(Sample(operation: operation, size: layer.drawableSize))
    }
}

/// Value snapshot: no strings refer to storage invalidated by wm_scene_test_reset.
private struct NativeEvent {
    let operation: String
    let serial: UInt64
    let validHandle: Bool
    let result: Int32
    let layer: UnsafeMutableRawPointer?
    let outputSize: CGSize
    let renderSize: CGSize
    let displayScale: Double
    let renderScale: Double
    let fps: UInt32
    let volume: Float
    let muted: Bool
    let paused: Bool
    let source: String
    let assets: String
    let cachePath: String
    let stringValue: String
    let int32Value: Int32
    let boolValue: Bool

    init(_ event: wm_scene_test_event) {
        operation = event.operation.map { String(cString: $0) } ?? ""
        serial = event.handle_serial
        validHandle = event.valid_handle
        result = event.result
        layer = event.metal_layer
        outputSize = CGSize(width: CGFloat(event.width), height: CGFloat(event.height))
        renderSize = CGSize(width: CGFloat(event.render_width), height: CGFloat(event.render_height))
        displayScale = event.display_scale_factor
        renderScale = event.render_scale
        fps = event.fps
        volume = event.volume
        muted = event.muted
        paused = event.paused
        source = event.source.map { String(cString: $0) } ?? ""
        assets = event.assets.map { String(cString: $0) } ?? ""
        cachePath = event.cache_path.map { String(cString: $0) } ?? ""
        stringValue = event.string_value.map { String(cString: $0) } ?? ""
        int32Value = event.int32_value
        boolValue = event.bool_value
    }
}
