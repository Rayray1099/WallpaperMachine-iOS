import Foundation

/// Pure preview-transfer state shared by the URLSession callback and detail view.
enum WorkshopPreviewProgress {
    static let updateIntervalBytes: Int64 = 64 * 1024

    static func shouldPublish(received: Int64, lastPublished: Int64, expected: Int64) -> Bool {
        guard received > lastPublished else { return false }
        return received - lastPublished >= updateIntervalBytes || (expected > 0 && received >= expected)
    }

    static func fraction(received: Int64, expected: Int64) -> Double? {
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}
