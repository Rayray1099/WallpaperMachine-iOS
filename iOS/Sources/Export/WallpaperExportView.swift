// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

@MainActor
public struct WallpaperExportView: View {
    let item: WallpaperItem
    let sourceURL: URL
    let playback: PlaybackSettings
    var frameProvider: WallpaperFrameProvider?
    @State private var options = WallpaperExportSettings()
    @State private var progress: WallpaperExportProgress?
    @State private var result: WallpaperExportResult?
    @State private var error: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var share = false
    @Environment(\.dismiss) private var dismiss

    public init(item: WallpaperItem, sourceURL: URL, settings: PlaybackSettings,
                frameProvider: WallpaperFrameProvider? = nil) {
        self.item = item; self.sourceURL = sourceURL; self.playback = settings
        self.frameProvider = frameProvider
    }
    private var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    private func l(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    private var renderingUnavailable: Bool { (item.kind == .scene || item.kind == .web) && frameProvider == nil }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: item.title).font(.headline)
                    if renderingUnavailable {
                        Label(l("Real frame capture is not connected for this wallpaper. Export is unavailable; its preview image will not be substituted.",
                                "此桌布尚未連接實際畫面擷取。無法匯出，且不會以預覽圖片冒充動畫。"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(l("Exports are files for sharing. They do not enable continuous third-party wallpaper playback on the iPad Home or Lock Screen.",
                           "匯出會產生可分享的檔案，不會讓第三方桌布在 iPad 主畫面或鎖定畫面持續播放。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(l("Output", "輸出")) {
                    Picker(l("Format", "格式"), selection: $options.format) {
                        Text("MP4").tag(WallpaperExportFormat.movie)
                        Text(l("Image sequence (ZIP)", "影格序列（ZIP）")).tag(WallpaperExportFormat.imageSequence)
                        Text(".tendies (experimental)").tag(WallpaperExportFormat.tendies)
                    }
                    if options.format == .movie {
                        Picker(l("Codec", "編碼"), selection: $options.codec) {
                            ForEach(WallpaperExportCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    Picker(l("Resolution", "解析度"), selection: $options.resolution.preset) {
                        Text(l("This device", "此裝置")).tag(WallpaperExportResolutionPreset.device)
                        Text("1080 × 1920").tag(WallpaperExportResolutionPreset.fullHD1080)
                        Text(l("Custom", "自訂")).tag(WallpaperExportResolutionPreset.custom)
                    }
                    if options.resolution.preset == .custom {
                        Stepper(l("Width: \(options.resolution.customWidth)", "寬度：\(options.resolution.customWidth)"), value: $options.resolution.customWidth, in: 64...8192, step: 2)
                        Stepper(l("Height: \(options.resolution.customHeight)", "高度：\(options.resolution.customHeight)"), value: $options.resolution.customHeight, in: 64...8192, step: 2)
                    }
                    Stepper(l("FPS: \(options.frameRate)", "影格率：\(options.frameRate)"), value: $options.frameRate, in: 1...120)
                    Stepper(l("Duration: \(Int(options.duration)) seconds", "長度：\(Int(options.duration)) 秒"), value: $options.duration, in: 1...600, step: 1)
                    Picker(l("Compression quality", "壓縮品質"), selection: $options.quality.preset) {
                        ForEach(WallpaperExportQualityPreset.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                    }
                    if options.format == .imageSequence {
                        Picker(l("Image format", "圖片格式"), selection: $options.imageFormat) {
                            Text("PNG").tag(WallpaperExportImageFormat.png)
                            Text("JPEG").tag(WallpaperExportImageFormat.jpeg)
                        }
                        Slider(value: $options.imageQuality, in: 0.1...1) { Text(l("Image quality", "圖片品質")) }
                    }
                }.disabled(exportTask != nil)
                Section(l("Placement", "位置")) {
                    Picker(l("Aspect ratio", "長寬比"), selection: $options.aspectMode) {
                        Text(l("Fit", "完整顯示")).tag(WallpaperExportAspectMode.fit)
                        Text(l("Fill", "填滿")).tag(WallpaperExportAspectMode.fill)
                        Text(l("Stretch", "延展")).tag(WallpaperExportAspectMode.stretch)
                    }
                    Slider(value: $options.zoom, in: 0.25...4) { Text(l("Zoom", "縮放")) }
                    Slider(value: $options.offsetX, in: -1...1) { Text(l("Horizontal position", "水平位置")) }
                    Slider(value: $options.offsetY, in: -1...1) { Text(l("Vertical position", "垂直位置")) }
                }.disabled(exportTask != nil)
                if options.format == .tendies {
                    Section("PosterBoard / AirCard") {
                        Text(l("Experimental archive compatibility, not verified installation. The OS controls loop duration. No 300-frame cap is imposed. No system databases are changed.",
                               "封存檔相容性仍屬實驗性，尚未驗證安裝。循環長度由系統控制，不設定 300 影格限制，也不修改系統資料庫。"))
                        TextField(l("Wallpaper name", "桌布名稱"), text: $options.tendies.wallpaperName)
                        Text(verbatim: options.tendies.screenClass.name).font(.caption.monospaced())
                        Slider(value: $options.tendies.frameQuality, in: 0.1...1) { Text(l("JPEG quality", "JPEG 品質")) }
                    }
                }
                if let progress {
                    Section(l("Progress", "進度")) {
                        ProgressView(value: progress.fraction)
                        Text(verbatim: "\(progress.phase.rawValue): \(progress.completedFrames)/\(progress.totalFrames)")
                        Button(l("Cancel export", "取消匯出"), role: .cancel) { exportTask?.cancel() }
                    }
                }
                if let result {
                    Section(l("Exported file", "匯出檔案")) {
                        Text(verbatim: "\(result.frameCount) frames · \(result.pixelSize) · \(result.byteSize) bytes")
                        ForEach(result.notes, id: \.self) { Text(verbatim: $0).font(.footnote) }
                        Button(l("Share file", "分享檔案")) { share = true }.accessibilityIdentifier("wm.export.share")
                    }
                }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
                Button(l("Render and export", "算繪並匯出"), action: start)
                    .disabled(exportTask != nil || renderingUnavailable)
                    .accessibilityIdentifier("wm.export.start")
            }
            .navigationTitle(l("Export wallpaper", "匯出桌布"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(l("Done", "完成")) { dismiss() }.disabled(exportTask != nil) } }
            .onAppear {
                options.frameRate = min(60, max(1, playback.framesPerSecond))
                options.aspectMode = WallpaperExportAspectMode(rawValue: playback.scaling) ?? .fit
                options.tendies.screenClass = ExportDevice.screenClass
                options.tendies.wallpaperName = item.title
            }
            .onDisappear { exportTask?.cancel() }
            .sheet(isPresented: $share) { if let result { ExportShareSheet(url: result.outputURL) } }
        }.accessibilityIdentifier("wm.export")
    }
    private func start() {
        error = nil; result = nil
        let selected = options
        exportTask = Task {
            defer { exportTask = nil; progress = nil }
            do {
                result = try await WallpaperExportService().export(item: item, sourceURL: sourceURL, settings: selected,
                    frameProvider: frameProvider, progress: { value in Task { @MainActor in progress = value } })
            } catch is CancellationError { error = l("Export cancelled.", "已取消匯出。") }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
