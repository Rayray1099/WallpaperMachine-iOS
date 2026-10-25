# iOS export and AirCard boundary

Export is separate from foreground playback. `WallpaperExportService` decodes real video frames with AVFoundation, composites placement/aspect/zoom, and writes H.264/HEVC MP4, PNG/JPEG frame sequences (optionally ZIP), or an experimental PosterBoard `.tendies` ZIP. Image sources are explicitly still images. Scene/web sources require an injected live `WallpaperFrameProvider`; absent that provider the operation fails rather than substituting an author preview. The settings sheet exposes that unsupported state.

## References and provenance

- [22amiibo/mp4To.Tendies](https://github.com/22amiibo/mp4To.Tendies) demonstrates JPEG frame assets, CAML and plist structure inside a ZIP renamed `.tendies`. Its defaults are iPhone-oriented. It was inspected as a format reference; no external template wallpaper imagery is bundled.
- [Mak5er/AirCard-iOS](https://github.com/Mak5er/AirCard-iOS), specifically `ios-app/TendiesEngine.swift`, imports `.tendies` as ZIP, discovers descriptors and images, and distinguishes container/database payloads. WallpaperMachine exports collections-style assets, not a system database container.
- The export source includes generated keyed archive metadata and CAML from field values. Compatibility is experimental until an actual exported archive is imported and checked on this user's iPadOS version. Generated metadata is not proof of operating-system acceptance.

## iPad defaults

`ExportDevice` reads connected display native geometry and derives portrait point dimensions and the idiom suffix. It does not reuse iPhone 1290×2796 naming. Both the output pixel size and PosterBoard screen class remain explicit. The target's observed logical geometry is 834×1210 points at2x (1668×2420 portrait pixels). Resolution, duration, FPS, compression, aspect, zoom and offsets are user configurable.

There is no imposed 300-frame restriction. Longer sequence export and actual OS playback duration remain unverified. A safety duration limit is not an OS compatibility claim.

## Timing and limits

Video export uses source timestamps. `MediaCaptureFrameProvider` adapts actual live surface snapshots but cannot yet guarantee deterministic web/scene time: WebKit snapshots are asynchronous and arbitrary webpage clocks are not seekable. It must not be described as an offline deterministic scene renderer or guaranteed60fps capture. The app currently needs live provider wiring for these sources.

Current movie export does not mux audio. Standalone WebM input is rejected accurately by the media layer pending connection to the existing native WebM reader. iOS app background suspension can interrupt an export; the operation must report cancellation/failure, not success with an incomplete file.

## Installation safety

The share sheet can pass an archive to compatible AirCard versions. No direct AirCard exploit, respring, wallpaper database replacement, or system write is performed by this app. Importing/previewing a file in AirCard is distinct from authorizing its application to the system wallpaper store. Never infer continuous Home/Lock Screen playback from an in-app loop.

## Verification

Source syntax parsed on Windows. Actual MP4 encoding, numbered output contents, tendies import, longer export behavior, portrait/landscape crop and background/foreground recovery still require native build and physical-device tests. See STATUS.md for current build/device state.
