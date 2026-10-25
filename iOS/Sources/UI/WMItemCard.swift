import SwiftUI
import UIKit

/// Bounded in-memory thumbnail cache. Disk work and image decoding happen off the
/// main actor; the UI only receives ready `UIImage` values.
@MainActor
final class WMThumbnailCache {
    static let shared = WMThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: CGFloat = 480) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let path = url.path
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
                  let source = UIImage(data: data) else {
                return nil
            }
            let longestSide = max(source.size.width, source.size.height)
            guard longestSide > 0 else { return source }
            if longestSide <= maxPixelSize {
                return source
            }
            let ratio = maxPixelSize / longestSide
            let target = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            return source.preparingThumbnail(of: target) ?? source
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}

struct WMThumbnailView: View {
    let url: URL?
    let kind: WallpaperKind

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: kind.wmSystemImage)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await WMThumbnailCache.shared.image(for: url)
        }
    }
}

/// A single library tile. The parent wraps it in a button (regular width) or a
/// navigation link (compact width) and supplies the stable accessibility id.
struct WMItemCard: View {
    let item: WallpaperItem
    let previewURL: URL?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WMThumbnailView(url: previewURL, kind: item.kind)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                }

            HStack(spacing: 6) {
                Text(verbatim: item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .accessibilityHidden(true)
                }
            }

            Text(item.kind.wmLocalizedKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(item.kind.wmLocalizedKey))
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
    }
}
