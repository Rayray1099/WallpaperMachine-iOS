// SPDX-License-Identifier: GPL-3.0-only
import UIKit

/// Blank isolated test host: no library, renderer, playback, audio or network startup.
@main
@MainActor
final class ExportOwnershipApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1210))
        window.rootViewController = UIViewController()
        window.isHidden = false
        self.window = window
        return true
    }
}
