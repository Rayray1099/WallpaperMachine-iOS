# iOS export and AirCard boundary

Export is separate from foreground playback. `WallpaperExportService` decodes real video frames with AVFoundation, composites placement/aspect/zoom, and writes H.264/HEVC MP4, PNG/JPEG frame sequences (optionally ZIP), or an experimental PosterBoard `.tendies` ZIP. Image sources are explicitly still images. The export sheet supplies a visible local-WebKit frame provider for web sources; callers can still inject their own provider. Scene sources require an injected live `WallpaperFrameProvider`; absent that provider the operation fails rather than substituting an author preview. The settings sheet exposes that unsupported scene state.

## References and provenance

- [22amiibo/mp4To.Tendies](https://github.com/22amiibo/mp4To.Tendies) demonstrates JPEG frame assets, CAML and plist structure inside a ZIP renamed `.tendies`. Its defaults are iPhone-oriented. It was inspected as a format reference; no external template wallpaper imagery is bundled.
- [Mak5er/AirCard-iOS](https://github.com/Mak5er/AirCard-iOS), specifically `ios-app/TendiesEngine.swift`, imports `.tendies` as ZIP, discovers descriptors and images, and distinguishes container/database payloads. WallpaperMachine exports collections-style assets, not a system database container.
- The export source includes generated keyed archive metadata and CAML from field values. Compatibility is experimental until an actual exported archive is imported and checked on this user's iPadOS version. Generated metadata is not proof of operating-system acceptance.

## iPad defaults

`ExportDevice` reads connected display native geometry and derives portrait point dimensions and the idiom suffix. It does not reuse iPhone 1290×2796 naming. Both the output pixel size and PosterBoard screen class remain explicit. The target's observed logical geometry is 834×1210 points at2x (1668×2420 portrait pixels). Resolution, duration, FPS, compression, aspect, zoom and offsets are user configurable.

There is no imposed 300-frame restriction. Longer sequence export and actual OS playback duration remain unverified. A safety duration limit is not an OS compatibility claim.

## Timing and limits

Video export uses source timestamps. `MediaCaptureFrameProvider` adapts actual live surface snapshots but cannot guarantee deterministic web/scene time: WebKit snapshots are asynchronous and arbitrary webpage clocks are not seekable. It must not be described as an offline deterministic scene renderer or guaranteed 60 FPS capture. The visible local-WebKit export host remains outside recycled Form rows and must be attached, loaded and laid out. Web export requests at most 30 FPS and downscales captured images into a 1920-pixel edge bound (WebKit may first allocate its full viewport snapshot). Output size is independent of that capture bound. The provider is prepared once by the export service; the live clock starts on the first requested frame and is reset between exports. Capture is checked both before and after each snapshot, including the final frame: more than 0.5 seconds of timeline drift fails instead of silently time-compressing slow captures. Rewinding/repeated timestamps and nonfinite/invalid dimensions are rejected. Readiness and each snapshot have separate 10-second timeouts; cancellation stops awaiting an uncancellable WebKit callback and discards its late result. No microphone adapter is started by export, and preview updates retain the selected capture FPS with audio response disabled. The page's capture surface is the visible preview viewport, scaled into the chosen output; arbitrary JavaScript/WebGL clocks are not seeked. Native scene capture still needs its provider connection.

Current movie export does not mux audio. Standalone WebM input is rejected accurately by the media layer pending connection to the existing native WebM reader. iOS app background suspension can interrupt an export; the operation must report cancellation/failure, not success with an incomplete file.

## Installation safety

The share sheet can pass an archive to compatible AirCard versions. No direct AirCard exploit, respring, wallpaper database replacement, or system write is performed by this app. Importing/previewing a file in AirCard is distinct from authorizing its application to the system wallpaper store. Never infer continuous Home/Lock Screen playback from an in-app loop.

## Verification

Release build `95d82eeb` / Actions `40172632944` was installed and opened on the iPad. A synthetic 320×240, 12 FPS, two-second H.264 source was imported into the library. With 1080×1920 output and 30 requested FPS, the app completed H.264 MP4 export (60 frames, 377,447 bytes) and `.tendies` export (60 frames, 5,613,260 bytes, detected `834w-1210h@2x~ipad` screen class). Both reached the real system share sheet; a tendies copy was saved through Files. These UI/runtime results do not independently validate exported frame contents or AirCard acceptance/application. HEVC, sequence contents, longer exports, crop and lifecycle recovery remain unverified.

That installed build does **not** include the visible-web capture changes described here. Updated sources passed syntax parsing plus 33 executed portable timing/provider checks on Windows using explicit Apple-type stand-ins. New Apple-SDK XCTest coverage exercises provider preparation/reuse, capture sizing, final-frame drift, late wakeup, timestamp rejection, cancellation/timeout with late callbacks, surface readiness and failed preparation. Those XCTest cases and the changed UIKit/SwiftUI/WebKit sources still require an Xcode build/test run; Windows cannot typecheck Apple SDK APIs. Actual web output is unverified. See [STATUS.md](STATUS.md) for current build/device state.
