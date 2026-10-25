# iOS port feature-parity checklist

This file records implementation and verification separately. A source implementation is not a successful iOS build; an iOS build is not a physical-device pass.

## Verified environment

- Upstream cloned with history: WallpaperMachine/WallpaperMachine at `f3405f1f528e7ff3bd057cf7a257b2be3e058964`.
- Authorized private repository created: https://github.com/Rayray1099/WallpaperMachine-iOS ; branch `ios/main`. GitHub login and admin/push permission checked. No source push/build yet at this checkpoint.
- Build-contract continuation reviewed the existing renderer, build and UI/media source with at most three workers. Runtime selection is not compiler or device evidence.
- Official iCTRL manual/schema/client retrieved from the device. Existing saved authorization reused successfully via encrypted protocol v1; no new pairing prompt or bypass. Secrets remain in the normal per-user client store, never repository/artifacts.
- Device reports iPadOS27.0, runner1.96.1. Screenshot, hierarchy, app launch, activation and tap postcondition verified on a disposable LAN-local test page. Runner foreground detection had stale Notes/PiP state; documented `reset` plus app launch corrected the state. Tap changed button text to `Tap verified`; swipe moved the target from offscreen to onscreen. `settle.screen_changed:false` alone was misleading; postconditions checked. Geometry changed after reset, so coordinate space must be refreshed rather than cached across orientation/state recovery.
- No WallpaperMachine IPA, installation or app runtime test yet. No FPS/app-memory measurements obtained. Runner process metrics are not app metrics.

## Source implementation, pending native build/runtime validation

| Feature | Current source state | Outstanding verification/work |
|---|---|---|
| Scene engine | Real C++ Metal engine plus Rust wm-shader iOS cross-build and UIKit/CAMetalLayer host; C ABI status handling reviewed | Actual ARM64 compile/link; real assets/scenes on device |
| Video | AVQueuePlayer/AVPlayerLooper MP4/MOV H264/HEVC, lifecycle, volume, scaling | Compile and physical seamless-loop playback; WebM standalone unsupported state |
| Web | Local WKWebView, property/audio JavaScript, root containment and navigation guard | Compile, real WebGL assets/touch/audio, network policy regression |
| Library | Managed copy/import, natural JSON model, favorites/collections/playlists/settings, ZIP backup/restore with containment and rollback | XCTest/iOS integration; thumbnails and folder-update cases |
| iPad UI | Adaptive SwiftUI sidebar/grid/details/properties/settings/fullscreen/shortcuts, English/Traditional Chinese | Native compile; portrait/landscape/resizing/accessibility on iPad |
| Workshop | Public browse/search/detail/preview/cache/update/import source | Runtime parsing/network tests. SteamPipe CM/depot authenticated downloads NOT implemented; public metadata has no file URL. No DRM/auth bypass |
| Audio | Microphone-only AVAudioEngine/FFT source and web adapter | Unify source ownership; scene PCM bridge; permission/device tests. Other-app audio capture unavailable |
| Export | Real decoded video/image movie/sequence/.tendies writers and integrated settings/share UI | Native build, output playback, longer exports. Live scene/web requires real injected provider, never preview still |
| Tendies/AirCard | Generated iPad-aware archive structure based on reference source, no 300-frame ceiling | Experimental/unverified OS import, looping, metadata compatibility. No system DB writes or respring performed |
| Build | Reconciled renderer output root/defaults, actual engine+shader C ABI checks, macOS host-independent ARM64 cross-build, unsigned IPA packaging | First push and real compile/fix cycle; native simulator tests explicitly deferred, not passed |
| LCSign | Not yet used | Discover correct installed app, transfer actual IPA, sign authorized identity, install and verify |
| QA | 100 executable offline Python tests pass; shared model/repository Swift Windows typecheck and all iOS source syntax parse pass | Native XCTest/UI simulator run and actual installed iPad app regressions |

## Known platform boundaries

The app is an in-app native wallpaper renderer. Public iOS APIs do not allow arbitrary third-party continuous rendering on the Home/Lock Screen or unrestricted capture of audio from other apps. AirCard and PosterBoard interoperability is an export route, not a promise of continuous background playback. Imported Workshop assets and Wallpaper Engine shared resources must be user-authorized; they are not distributed in this repository.

## Local continuation checks

- `python scripts/ios/build.py --check`: passed (static contract only).
- `python -m unittest discover -s scripts/ios/qa/tests -p 'test_*.py'`: 100 passed.
- Windows `swiftc -typecheck`: shared models/path/repository without ZIPFoundation;
  Workshop Foundation model/session/service subset; Foundation export geometry,
  settings, keyed archives and tendies manifest. All passed. Apple SDK branches
  are not typechecked by these commands.
- `swiftc -frontend -parse`: all iOS source and test Swift passed; syntax only.
- `git diff --check`: passed.
- `python scripts/test.py`: failed on Windows in upstream macOS-oriented script
  tests (POSIX paths/newlines, cp950 defaults, Python 3.11-only hashing, missing
  `xattr`/`sips`/`tzset` and macOS process APIs). No upstream native verdict or
  macOS regression pass is claimed; unrelated upstream scripts were not rewritten.

## Next build cycle

Finish renderer host and exact build contract, review/test, commit and push ios/main, inspect actual macOS CI logs, correct underlying errors, download and validate actual IPA, LAN transfer to LCSign, sign/install, and exercise real scene/video/web/import/settings/export on the paired device.
