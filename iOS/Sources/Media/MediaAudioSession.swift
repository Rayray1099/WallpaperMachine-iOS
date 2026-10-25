import AVFAudio
import Foundation

/// The app's single audio-session owner for media surfaces.
///
/// A video wallpaper and a web wallpaper both want `.ambient` output: it mixes
/// with the user's music and follows the silent switch like a desktop wallpaper
/// does. Microphone analysis needs `.playAndRecord`, which cannot coexist with
/// `.ambient`; the two are reference counted here so starting or stopping the
/// analyser never silently changes what the other surface needs.
///
/// This type is intentionally thread-affine: call it from the main thread. It
/// serialises its counters anyway, so a stray call cannot corrupt them, and the
/// session calls themselves happen outside the lock.
final class MediaAudioSession: @unchecked Sendable {
  static let shared = MediaAudioSession()

  private let lock = NSLock()
  private let session = AVAudioSession.sharedInstance()
  private var playbackUsers = 0
  private var microphoneUsers = 0
  private var configuredCategory: AVAudioSession.Category?

  private init() {}

  /// Registers a playback surface. Safe to call again from the same surface;
  /// every `beginPlayback` must be paired with an `endPlayback`.
  func beginPlayback() {
    lock.lock()
    playbackUsers += 1
    let configure = microphoneUsers == 0
    lock.unlock()
    if configure { configurePlayback() }
  }

  func endPlayback() {
    lock.lock()
    playbackUsers = max(0, playbackUsers - 1)
    let deactivate = playbackUsers == 0 && microphoneUsers == 0
    lock.unlock()
    if deactivate { deactivateIfIdle() }
  }

  /// Registers a microphone consumer and switches the session to recording.
  /// Throws when the system refuses the category or activation; the counter is
  /// only incremented after the session accepted the change.
  func beginMicrophone() throws {
    lock.lock()
    let alreadyRecording = microphoneUsers > 0
    lock.unlock()
    if !alreadyRecording { try configureMicrophone() }
    lock.lock()
    microphoneUsers += 1
    lock.unlock()
  }

  func endMicrophone() {
    lock.lock()
    microphoneUsers = max(0, microphoneUsers - 1)
    let remaining = microphoneUsers
    let playback = playbackUsers
    lock.unlock()
    guard remaining == 0 else { return }
    if playback > 0 {
      configurePlayback(force: true)
    } else {
      deactivateIfIdle()
    }
  }

  private func configurePlayback(force: Bool = false) {
    guard force || configuredCategory != .ambient else { return }
    do {
      try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      configuredCategory = .ambient
    } catch {
      configuredCategory = nil
      MediaLog.error("playback audio session unavailable: \(error.localizedDescription)")
    }
  }

  private func configureMicrophone() throws {
    do {
      try session.setCategory(
        .playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
      try session.setActive(true)
      configuredCategory = .playAndRecord
    } catch {
      configuredCategory = nil
      throw MediaAudioSessionError.activationFailed(error.localizedDescription)
    }
  }

  private func deactivateIfIdle() {
    do {
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
      configuredCategory = nil
    } catch {
      MediaLog.debug("audio session stayed active after its last consumer: \(error.localizedDescription)")
    }
  }
}

enum MediaAudioSessionError: Error, Equatable, LocalizedError {
  case activationFailed(String)

  var errorDescription: String? {
    switch self {
    case .activationFailed(let detail):
      return "The audio session could not start: \(detail)"
    }
  }
}
