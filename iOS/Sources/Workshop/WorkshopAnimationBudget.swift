/// Pure budget and timing rules for decoding a bounded animated author preview.
enum WorkshopAnimationBudget {
    static let maximumFrames = 300
    static let maximumFramePixels = 4_194_304
    static let maximumTotalPixels = 33_554_432

    static func frameCount(_ count: Int) -> Int? {
        guard count > 1, count <= maximumFrames else { return nil }
        return count
    }

    static func canAddFrame(width: Int, height: Int, totalPixels: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumFramePixels / height,
              width <= maximumTotalPixels / height
        else { return false }
        let pixels = width * height
        return pixels <= maximumTotalPixels - totalPixels
    }

    static func duration(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0.1 }
        return min(10, max(0.02, value))
    }
}
