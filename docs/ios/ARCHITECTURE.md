# iOS port architecture

The macOS application and renderer remain in place. iOS is a separate UIKit/SwiftUI host for the existing GPL-3.0-only engine, not a video replacement for scenes. The initial deployment floor is iOS 18; iPadOS 27 is the physical test target. SDK availability is determined on GitHub Actions, never inferred from a device OS.

## Latest cross-agent decisions

Read [INTEGRATION.md](INTEGRATION.md) for library signatures, frame-provider agreement and renderer output paths. The current implementation continues the existing host and upstream engine; it is not a replacement architecture.

## Integration contracts

- App module name: `WallpaperMachineIOS`; bundle identifier `com.rayray1099.wallpapermachine.ios`.
- XcodeGen spec: `iOS/project.yml`. Sources: `iOS/Sources/`; resources: `iOS/Resources/`. All Swift files share one module, Swift 5 language mode to avoid imposing Swift 6 concurrency migrations on upstream code.
- `WallpaperKind: String, Codable, CaseIterable`: `scene`, `video`, `web`, `image`.
- `WallpaperItem: Identifiable, Codable, Hashable`: `id: UUID`, `title: String`, `kind: WallpaperKind`, `relativePath: String` (folder inside managed library), `entryFile: String`, `previewFile: String?`, `workshopID: String?`, `isFavorite: Bool`, `collections: [String]`, `properties: [String: WallpaperProperty]`, `addedAt: Date`.
- `WallpaperProperty: Codable, Hashable`: `label: String`, `type: String`, `value: JSONValue`, `minimum: Double?`, `maximum: Double?`, `options: [String]`.
- `JSONValue` supports string, number, bool, array, object, null, and Codable.
- `WallpaperItem.pixiv: PixivAttribution?` retains upstream-shaped source metadata; it is optional for existing libraries. Imports deduplicate Pixiv work/page independently of Steam Workshop IDs.
- `@MainActor LibraryStore: ObservableObject`: published `items`, `errorMessage`, `isImporting`, `collections`, `playlistIDs`, `settings`; `rootURL: URL`; `url(for:) -> URL`, `previewURL(for:) -> URL?`, `importURL(_:) async`, `toggleFavorite(_:)`, `update(_:)`, `remove(_:) throws`, `save() throws`, `exportBackup(to:) throws`, `restoreBackup(from:) throws`.
- `PlaybackSettings: Codable`: `volume: Double`, `isMuted: Bool`, `framesPerSecond: Int`, `renderScale: Double`, `scaling: String` (`fit`, `fill`, `stretch`), `playlistInterval: Double`, `microphoneEnabled: Bool`.
- Media provides `VideoWallpaperView(url: URL, settings: PlaybackSettings)` and `WebWallpaperView(url: URL, properties: [String: WallpaperProperty])`; image uses a native image view. Microphone analysis must expose real samples and explicit permission; no system-wide audio capture claim.
- Renderer provides `SceneWallpaperView(url: URL, settings: PlaybackSettings, properties: [String: WallpaperProperty])`; URL points at the imported project entry (scene JSON or package). Asset-root configuration must be explicit, never redistribute Wallpaper Engine's licensed shared assets.
- Workshop provides `WorkshopBrowserView(library: LibraryStore)` and service types under its owned directory; no auth bypass or credential logging.
- Pixiv provides an app-owned `PixivStore` and `PixivBrowserView(store:onShowInLibrary:)`; `PixivLibraryAccess` adapts the real library and permits isolated state tests. `LibraryStore.importURLReporting(_:) async throws` exposes import failure to the download owner before completion is published. See [PIXIV.md](PIXIV.md).
- Export provides `WallpaperExportView(item: WallpaperItem, sourceURL: URL, settings: PlaybackSettings)` and services; it must not label unsupported frame providers as working. User-owned content only, no system wallpaper database edits.
- Stable accessibility IDs prefixed `wm.`; top-level library `wm.library`, import `wm.import`, search `wm.search`, preview `wm.preview`, settings `wm.settings`, workshop `wm.workshop`, export `wm.export`.

## Ownership

- Lead: models, managed library, integration, persistent progress and documentation index.
- Renderer Agent: `Renderer/`, `iOS/Sources/Renderer/`, `scripts/ios/build_renderer.sh` only.
- iOS UI Agent: `iOS/Sources/App/`, `iOS/Sources/UI/`, `iOS/Resources/en.lproj/`, `iOS/Resources/zh-Hant.lproj/` only.
- Workshop Agent: `iOS/Sources/Workshop/` and Workshop-specific tests/docs only.
- Media Agent: `iOS/Sources/Media/` and media-specific tests/docs only.
- Wallpaper Agent: `iOS/Sources/Export/`, export-specific tests/docs and reference analysis only.
- Build Agent: `.github/workflows/ios-build.yml`, `iOS/project.yml`, `iOS/Resources/Info.plist`, build/package/validate scripts under `scripts/ios/` except renderer and QA scripts.
- QA Agent: `scripts/ios/qa/`, `iOS/Tests/`, QA-specific documentation only. Physical RPC access serialized by Lead.

Agents must not commit, push, or alter other scopes. Lead reviews, commits and triggers builds. Existing generated bridges and third-party code are not hand-patched. Third-party dependency changes require provenance/license records.

## Verification boundaries

Windows cannot execute Xcode/Metal builds. CI must compile real ARM64 iOS objects, preserve logs, and package a structurally validated unsigned IPA. Only successful builds and physical test evidence establish functionality. iCTRL runner memory/CPU is not app memory/CPU. Wallpaper export and AirCard are separate from foreground native rendering; iPadOS does not provide arbitrary third-party continuous Home/Lock Screen rendering through a public API.
