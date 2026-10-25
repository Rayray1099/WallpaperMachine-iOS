import AVFoundation
import Foundation

/// Real microphone permission state for the audio-response setting.
///
/// The host never claims system-wide audio capture: the setting only allows the
/// wallpaper surfaces that support it to receive microphone samples after iPadOS
/// grants access, and a denial is shown instead of pretending it works.
@MainActor
final class WMMicrophoneController: ObservableObject {
    @Published private(set) var permission: MicrophoneAudioAnalyzer.Permission

    init() {
        permission = MicrophoneAudioAnalyzer.currentPermission()
    }

    func refresh() {
        permission = MicrophoneAudioAnalyzer.currentPermission()
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    self.refresh()
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    var hasPermission: Bool {
        permission == .granted
    }

    var statusKey: String {
        switch permission {
        case .granted:
            return "settings.microphone.allowed"
        case .denied:
            return "settings.microphone.denied"
        case .undetermined:
            return "settings.microphone.undetermined"
        @unknown default:
            return "settings.microphone.undetermined"
        }
    }
}
