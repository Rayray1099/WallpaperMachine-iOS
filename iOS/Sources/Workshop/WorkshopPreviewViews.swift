import SwiftUI
import UIKit

/// A grid tile's still, loaded from the Workshop preview cache. The placeholder never claims
/// the image is missing: a failed preview is simply a neutral workshop tile.
struct WorkshopThumbnailImage: View {
    let url: URL?
    let cache: WorkshopThumbnailCache

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .quaternarySystemFill)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: failed ? "photo" : "sparkles")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            do {
                let data = try await cache.thumbnail(for: url)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data)
                if image == nil { failed = true }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

/// The detail sheet's preview: a large still until the person asks for the animation, then
/// the original bytes Steam published, played in a bounded `UIImageView`. The animation is
/// never started automatically, so opening an item costs one still request at most.
struct WorkshopLargePreview: View {
    let item: WorkshopItem
    let cache: WorkshopThumbnailCache

    @State private var still: UIImage?
    @State private var animation: UIImage?
    @State private var isLoadingAnimation = false
    @State private var animationUnavailable = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .secondarySystemBackground)
            if let animation {
                AnimatedUIImageView(image: animation)
                    .accessibilityLabel(WS("Animated Workshop preview", "工作坊動態預覽"))
            } else if let still {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(WS("Workshop preview", "工作坊預覽"))
            } else if item.previewURL != nil {
                ProgressView()
            } else {
                ContentUnavailableView(
                    WS("No preview", "沒有預覽"),
                    systemImage: "photo",
                    description: Text(WS(
                        "The author did not publish a preview for this item.",
                        "作者沒有為此項目發佈預覽。")))
            }

            if let previewURL = item.previewURL, animation == nil, !isLoadingAnimation {
                Button {
                    Task { await loadAnimation(previewURL) }
                } label: {
                    Label(
                        animationUnavailable
                            ? WS("Still preview only", "僅靜態預覽")
                            : WS("Play animated preview", "播放動態預覽"),
                        systemImage: animationUnavailable ? "photo" : "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(12)
                .disabled(animationUnavailable)
                .accessibilityIdentifier("wm.workshop.animation")
            }

            if isLoadingAnimation {
                ProgressView()
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(12)
            }
        }
        .frame(minHeight: 240, maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .task(id: item.previewURL) {
            still = nil
            animation = nil
            animationUnavailable = false
            guard let url = item.previewURL else { return }
            if let data = try? await cache.largeThumbnail(for: url) {
                still = UIImage(data: data)
            }
        }
    }

    private func loadAnimation(_ url: URL) async {
        isLoadingAnimation = true
        defer { isLoadingAnimation = false }
        do {
            let data = try await cache.animatedPreview(for: url)
            guard let image = UIImage(data: data), image.images?.count ?? 0 > 1 else {
                animationUnavailable = true
                return
            }
            animation = image
        } catch {
            animationUnavailable = true
        }
    }
}

/// A `UIImageView` displaying an animated `UIImage`. The frame budget was checked before the
/// bytes were accepted, so this does not hand an unbounded GIF to the decoder.
struct AnimatedUIImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.startAnimating()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image {
            view.stopAnimating()
            view.image = image
            view.startAnimating()
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
        view.image = nil
    }
}

/// A small wrapping layout for Steam tags and metadata. Values are shown as Steam wrote them.
struct WorkshopTagFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
