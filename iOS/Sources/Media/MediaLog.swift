import Foundation
import os

/// Media's log channel. The iOS app has no in-app log view yet, so records go to
/// the unified log under the iOS bundle's subsystem and survive a device trace.
enum MediaLog {
  private static let logger = Logger(
    subsystem: "com.rayray1099.wallpapermachine.ios", category: "media")

  static func debug(_ message: @autoclosure () -> String) {
    logger.debug("\(message(), privacy: .public)")
  }

  static func info(_ message: @autoclosure () -> String) {
    logger.info("\(message(), privacy: .public)")
  }

  static func warning(_ message: @autoclosure () -> String) {
    logger.warning("\(message(), privacy: .public)")
  }

  static func error(_ message: @autoclosure () -> String) {
    logger.error("\(message(), privacy: .public)")
  }
}
