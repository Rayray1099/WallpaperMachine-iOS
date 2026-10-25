// SPDX-License-Identifier: GPL-3.0-only
import UIKit

/// Blank test host; actual production views are compiled but never presented.
@main
@MainActor
final class PCIntegrationApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}
