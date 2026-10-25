import Foundation

/// Pure capture gate for the shared microphone response source.
struct MicrophoneCaptureEligibility: Equatable {
  var isEnabled: Bool
  var applicationActive: Bool
  var visibleConsumerCount: Int

  var shouldCapture: Bool {
    isEnabled && applicationActive && visibleConsumerCount > 0
  }
}
