// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Validate before scaling: NaN, infinity and extreme aspect ratios must never
/// reach a floating-point-to-integer conversion or produce a zero-sized image.
enum LiveCaptureLimits {
    static let maximumFrameRate = 30

    static func boundedSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let factor = min(1, 1920 / max(size.width, size.height))
        return CGSize(width: max(1, floor(size.width * factor)),
                      height: max(1, floor(size.height * factor)))
    }
}

/// Live sources cannot rewind. Reject capture drift rather than silently encode
/// minutes of slow snapshots as a short animation with fabricated timing.
enum LiveCaptureTiming {
    static func waitNanoseconds(origin: UInt64, now: UInt64, seconds: Double) -> UInt64? {
        guard now >= origin, seconds.isFinite, seconds >= 0, seconds <= 86_400 else { return nil }
        let offset = UInt64(seconds * 1_000_000_000)
        let (target, overflow) = origin.addingReportingOverflow(offset)
        guard !overflow else { return nil }
        if target > now { return target - now }
        return now - target <= 500_000_000 ? 0 : nil
    }
}
