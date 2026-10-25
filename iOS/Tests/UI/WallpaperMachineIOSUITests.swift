// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// The accessibility-ID contract from docs/ios/ARCHITECTURE.md, exercised on a
/// real app launch. The identifiers are the stable automation surface iCTRL uses;
/// a screen that renames or drops one must fail here, not silently change.
final class WallpaperMachineIOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["WALLPAPER_MACHINE_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(element("wm.library").waitForExistence(timeout: 20),
                      "the library screen never appeared")
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertVisible(_ identifier: String, timeout: TimeInterval = 5,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(identifier).waitForExistence(timeout: timeout),
                      "\(identifier) is missing from the accessibility tree",
                      file: file, line: line)
    }

    func testRootContractIdentifiersExist() {
        assertVisible("wm.library")
        assertVisible("wm.import")
        assertVisible("wm.search")
        assertVisible("wm.settings")

        // Wide layouts show the sidebar tool directly; compact layout keeps it in
        // the scope menu opened by wm.library.
        if !element("wm.workshop").exists {
            element("wm.library").tap()
        }
        assertVisible("wm.workshop")
    }

    func testSettingsSheetKeepsItsIdentifier() {
        element("wm.settings").tap()
        assertVisible("wm.settings.volume", timeout: 10)
        assertVisible("wm.settings.mute")
        assertVisible("wm.settings.fps")
    }

    func testPreviewAndExportIdentifiersForAnItem() throws {
        let items = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "wm.item."))
        let firstItem = items.element(boundBy: 0)
        try XCTSkipUnless(firstItem.waitForExistence(timeout: 5),
                          "the library is empty on this run; preview/export IDs need an imported item")
        firstItem.tap()
        assertVisible("wm.preview", timeout: 10)
        assertVisible("wm.export")
    }
}
