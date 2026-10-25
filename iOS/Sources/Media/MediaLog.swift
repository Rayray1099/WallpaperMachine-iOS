import Foundation
import os

/// Media's log channel. The iOS app has no in-app log view yet, so records go to
/// the unified log under the iOS bundle's subsystem and survive a device trace.
enum MediaLog {
  private static let logger = Logger(
    subsystem: "com.rayray1099.wallpapermachine.ios", category: "media")

  static func debug(_ message: @autoclosure () -> String) {
    let text = message()
    logger.debug("\(text, privacy: .public)")
  }

  static func info(_ message: @autoclosure () -> String) {
    let text = message()
    logger.info("\(text, privacy: .public)")
  }

  static func warning(_ message: @autoclosure () -> String) {
    let text = message()
    logger.warning("\(text, privacy: .public)")
  }

  static func error(_ message: @autoclosure () -> String) {
    let text = message()
    logger.error("\(text, privacy: .public)")
  }
}
