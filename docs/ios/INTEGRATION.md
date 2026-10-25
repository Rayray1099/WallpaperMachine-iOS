# Integration decisions from Lead

These are shared implementation contracts, not verification claims. Source, compilation, packaging and physical-device verification are tracked separately in [STATUS.md](STATUS.md).

## Shared model and UI

- Lead implements `LibraryStore()` no-argument initializer plus `init(rootURL:)` for isolated tests.
- Published properties are module-settable as architecture says.
- `JSONValue` has string/number/bool/array/object/null cases with manual JSON-shaped Codable (not Swift tagged synthesized representation).
- `update(_ item:)` is nonthrowing, errors through `errorMessage`; `remove(_ item:) throws`.
- `importURL(_:) async` is nonthrowing, errors through `errorMessage`. It accepts a project folder, ZIP project, video, image or HTML. Generic import rejects `.wmbackup` (case-insensitive) without changing the live library and directs the user to Settings → Restore Backup; only that separately confirmed restore flow replaces the library. Numeric imported folder name initializes workshopID. Importing an existing workshopID replaces its managed asset folder atomically while preserving favorite/collection/property selections.
- `url(for:)` returns the managed project **folder**, not the entry. UI appends `entryFile` before preview/export. For scene projects whose root-level declared JSON entry is physically absent, import resolves the same-basename `.pkg` as the physical entry (for example, `scene.json` → `scene.pkg`); both the declared path and selected package must stay contained, and the selected entry must be a regular file. The complete project folder and original `project.json` bytes, properties and assets are preserved. The native scene resolver mounts the package to read its virtual JSON; import does not unpack packages or claim renderer compatibility. Other wallpaper types and unrelated/missing packages do not receive this fallback. Missing nested JSON entries (with either path separator) are rejected even when a nested package exists, because the current scene host locates `project.json` beside the playback entry; existing physically present loose nested entries are unchanged.
- `AssetPath.resolve` appends validated relative components to one canonical root, normalizes either path separator, and refuses existing/dangling symlink components. Missing leaves and ancestors remain valid contained paths without independently resolving them from the original root alias (important for Darwin `/var` → `/private/var` paths); consumers still require regular files where needed.
- Backups use a versioned directory tree archived as ZIP with `.wmbackup` extension (ZIPFoundation package). No credentials in backups.
- `save()` persists direct UI settings/playlists/collections mutations atomically.

## Frame providers

Export owns its `@MainActor WallpaperFrameProvider` protocol and type erasure:
`frameSize: CGSize`, `prepareForExport() async throws`, `frame(at: CMTime) async throws -> CVPixelBuffer?`, `finishExport() async`.
Media owns its `@MainActor MediaFrameProviding` CGImage capture protocol. These can coexist: an adapter in app integration converts CGImage to CVPixelBuffer (or export agent may provide such an adapter). Never silently export a static preview as a scene/web animation. WallpaperExportView's three-argument initializer remains available; optional injected provider defaults to nil, which must be an explicit unsupported state for any unsupported source.

## Confirmed renderer outputs (latest, supersedes build proposal below)

Renderer Agent supplies `iOS/Generated/Renderer/lib/libWallpaperSceneRenderer.a`, generated includes `include/Platform/Apple/SceneWallpaperBindings.h`, `include/Core/RendererCounters.h`, `include/WallpaperSceneRenderer.h`, `link-flags.txt` and `manifest.json`.

Build Agent MUST adapt its project/script to that actual contract:
- call `bash scripts/ios/build_renderer.sh --sdk iphoneos`
- bridging header `$(SRCROOT)/Sources/Renderer/SceneWallpaperBridge.h` (SRCROOT is iOS)
- static archive `$(SRCROOT)/Generated/Renderer/lib/libWallpaperSceneRenderer.a`
- use renderer link-flags.txt system frameworks; no force_load, no Homebrew dependency dylibs
- no generated UniFFI WallpaperBridge Swift/FFI/modulemap requirement (we are not compiling macOS Rust Core/Bridge)
- all sources compile as one app module, include QA test target and exclude `Tests/UI` from unit target; separate UI testing target if running those tests.

Media and Renderer both proposed AVAudioEngine microphone feed; avoid simultaneous recording, use one shared source during integration. Export protocol+type erasure and Media capture protocol may coexist with conversion adapter; 3-arg export initializer must stay valid.

## Native scene startup

The iOS host prepares an empty `Application Support/WallpaperMachine/SharedAssets` directory before creating the native scene. This satisfies the native `/assets` mount even for a self-contained project; it does not supply or redistribute licensed Wallpaper Engine resources. Existing user-owned assets are preserved, child symlinks/non-directory conflicts are rejected, and shader caching remains optional. A preparation failure is shown explicitly rather than starting a doomed renderer or repeatedly retrying on layout.

Native pre-admission source/mount/document/property failures are published through the existing backend-failure query with a fixed, path-independent reason. They stop the frame clock without a preview/first-frame callback or presented-frame credit. A surface resize cannot clear a failed replacement and resume the outgoing graph; a successful new scene commit clears that state. Reapplying an identical configuration after repairing files is not a guaranteed reload: use an explicit refresh or a new scene host.

The old empty package is an import-only negative rendering fixture: no material means no Metal shader translation attempt, which native admission refuses. `python3 scripts/ios/make_native_scene_fixture.py --output <new-folder>` instead generates a wholly self-authored packaged quad, shader pair and RGBA texture with no shared-asset dependencies. Its native test checks actual detached GPU pixels when Metal is available, not iPad presentation. `frames_presented > 0` remains the iOS readiness gate; the native first-frame callback also settles some upstream failures and must not be used as proof of rendering.

## Build/renderer agreement

The device build uses SDK `iphoneos`, deployment floor 18.0, architecture `arm64` and Rust target `aarch64-apple-ios`. `iOS/Generated/Renderer` is the single output root; older `build/ios/renderer` and UniFFI proposals are obsolete.

We integrate Rust `wm-shader` + the real C++ engine C ABI, **not** unmodified macOS-only Rust Core/Bridge with AppKit/ServiceManagement. No generated UniFFI WallpaperBridge files are required.

System frameworks only; no Homebrew macOS binaries in the IPA. All iOS/Sources files share one Swift 5 module. Resources include English and Traditional Chinese, with microphone purpose text. After successful Xcode compilation, the build bundles actual source license texts under `Licenses/`: upstream GPL/history/provenance, pinned native dependencies, ZIPFoundation's resolved checkout, and the target-specific normal dependency closure of wm-shader. Missing required text fails the build; this notice payload is not a substitute for GPL corresponding-source obligations. Unit and UI tests have separate XcodeGen targets; simulator testing requires its own simulator renderer objects and is not established by a device archive build. Lead alone commits/pushes/triggers.

## Workshop

Public Wallpaper Engine details commonly contain no `file_url`. Never guess HTTP downloads or bypass ownership. Community browser login remains separate from native content authorization. Experimental `iOS/SteamTransport` implements native CM credentials/Guard, authenticated self-ownership check, PublishedFile manifest lookup, PICS workshopdepot resolution, Steam-issued key/request code and hash-verified staging. Full native/Swift Release linkage passed in run `40172632944`; that build was installed and opened on the iPad. The user completed native sign-in and the UI showed the authorized native session. A real download failed before bytes were transferred, so authenticated content transfer/import is **not** verified. A public Valve directory response reproduced the integer-only `weighted_load` decoding defect; the fractional-load/HTTPS fix passes 13 real offline CDN tests and still requires a fresh app build/device retry. Native status separates item, depot, content-directory and manifest-authorization stages; visible errors include only exact allowlisted codes, never arbitrary server text or credentials. No live credentials belong in tests/CI/logs. Animated author preview content was verified with six distinct cropped screenshot samples; this is not native wallpaper engine playback.
