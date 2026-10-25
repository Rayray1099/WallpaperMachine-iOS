# iOS port feature-parity checklist

This file records implementation and verification separately. A source implementation is not a successful iOS build; an iOS build is not a physical-device pass.

## Verified environment

- Upstream cloned with history: WallpaperMachine/WallpaperMachine at `f3405f1f528e7ff3bd057cf7a257b2be3e058964`.
- Authorized private repository created: https://github.com/Rayray1099/WallpaperMachine-iOS ; branch `ios/main`. GitHub login and admin/push permission checked. Initial port pushed as `cea74861`; first macOS Actions run `40162061046` reached Xcode 26.3 / iPhoneOS SDK 26.2 and built pinned C dependencies, then failed in archive verification before Rust/engine/app compilation.
- Build-contract continuation reviewed the existing renderer, build and UI/media source with at most three workers. Runtime selection is not compiler or device evidence.
- Official iCTRL manual/schema/client retrieved from the device. Existing saved authorization reused successfully via encrypted protocol v1; no new pairing prompt or bypass. Secrets remain in the normal per-user client store, never repository/artifacts.
- Device reports iPadOS27.0, runner1.96.1. Screenshot, hierarchy, app launch, activation and tap postcondition verified on a disposable LAN-local test page. Runner foreground detection had stale Notes/PiP state; documented `reset` plus app launch corrected the state. Tap changed button text to `Tap verified`; swipe moved the target from offscreen to onscreen. `settle.screen_changed:false` alone was misleading; postconditions checked. Geometry changed after reset, so coordinate space must be refreshed rather than cached across orientation/state recovery.
- Run `40162391380` passed archive verification and Rust shader compilation, then failed while compiling `SoundManager.cpp` as C++ although miniaudio's iOS backend contains Objective-C. The next fix compiles that translation unit as Objective-C++ only on iOS. Internal log upload also rejected colon-bearing filenames; stage filenames are normalized for Windows downloads.
- Run `40163079781` built/merged the actual Rust+C++ renderer: 639 ARM64 iOS objects. Subsequent compiler failures in WebKit availability/property delivery and OSLog autoclosures were fixed from actual Xcode diagnostics.
- Run `40163713936` successfully compiled the full Release device app and packaged an unsigned ARM64 IPA (5,302,602 bytes). Validation rejected only missing CryptoKit in the SDK-framework allowlist (both app and IPA checks); no downloadable IPA artifact was uploaded from that failed run. Corrected allowlist and bundled legal-notice generation are being verified in the next build.
- User deferred physical-device testing and took the iPad away. No device control, LCSign signing or installation should occur until the user returns with testing readiness.
- Run [40164005806](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40164005806), source `b2f8810b`, passed actual Release native/Swift compilation, generated source-license payload, IPA packaging and independent CI validation. Downloaded IPA independently checked on Windows: 5,756,147 bytes, SHA-256 `d77c905186e095f546f5e0a0f5fe1381abf1ebf4c7420fdfa6373e507523fa46`, unsigned thin ARM64 iOS, ZIP CRC/structure pass, English/Traditional Chinese, 74 legal payload files and linked real engine/shader symbols. The shared microphone-to-web integration follow-up `9ff8f083` also compiled, packaged and passed CI validation in run [40164217807](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40164217807); its downloaded final IPA independently passed the same hash/CRC/architecture/symbol/license checks: 5,777,278 bytes, SHA-256 `eec01ca1a75f1868105e130735eb3135ee4df87730d22572ee2b4712f30e6dc4`. This is the current build artifact, not an installed app.
- No installation or physical WallpaperMachine runtime test exists. No FPS/app-memory measurements obtained; runner process metrics are not app metrics.

## Feature implementation and remaining verification

| Feature | Current source state | Outstanding verification/work |
|---|---|---|
| Scene engine | Real C++ Metal engine plus Rust wm-shader iOS cross-build and UIKit/CAMetalLayer host; C ABI status handling reviewed | ARM64 compile/link passed; real assets/scenes on device remain deferred |
| Video | AVQueuePlayer/AVPlayerLooper MP4/MOV H264/HEVC, lifecycle, volume, scaling | ARM64 compilation passed; physical seamless-loop playback deferred; standalone WebM remains unsupported |
| Web | Local WKWebView, property/audio JavaScript, root containment and navigation guard | ARM64 compilation passed; real WebGL assets/touch/audio and network-policy runtime regression deferred |
| Library | Managed copy/import, natural JSON model, favorites/collections/playlists/settings, ZIP backup/restore with containment and rollback | XCTest/iOS integration; thumbnails and folder-update cases |
| iPad UI | Adaptive SwiftUI sidebar/grid/details/properties/settings/fullscreen/shortcuts, English/Traditional Chinese | ARM64 compilation passed; portrait/landscape/resizing/accessibility on iPad deferred |
| Workshop | Public browse/search/detail/preview/cache/update/import source | Runtime parsing/network tests. SteamPipe CM/depot authenticated downloads NOT implemented; public metadata has no file URL. No DRM/auth bypass |
| Audio | Microphone-only AVAudioEngine/FFT source; shared app-owned source wired into visible local web surfaces with opt-in/active/visible gating | New wiring ARM64 compiler/package validation passed; scene PCM bridge and real permission/device tests remain. Other-app audio capture unavailable |
| Export | Real decoded video/image movie/sequence/.tendies writers and integrated settings/share UI | ARM64 compilation passed; output playback and longer exports untested. Live scene/web requires real injected provider, never preview still |
| Tendies/AirCard | Generated iPad-aware archive structure based on reference source, no 300-frame ceiling | Experimental/unverified OS import, looping, metadata compatibility. No system DB writes or respring performed |
| Build | Actual Release native+Swift compilation, unsigned IPA packaging and CI validation passed; downloaded artifact independently checked | Final microphone follow-up compiled and validated; native simulator tests explicitly deferred, not passed |
| LCSign | Not yet used | Discover correct installed app, transfer actual IPA, sign authorized identity, install and verify |
| QA | 119 offline Python tests pass in continuation checkout (including local real-license inputs); portable Swift typechecks and all-source syntax parse pass | Native XCTest/UI simulator run and actual installed iPad app regressions |

## Known platform boundaries

The app is an in-app native wallpaper renderer. Public iOS APIs do not allow arbitrary third-party continuous rendering on the Home/Lock Screen or unrestricted capture of audio from other apps. AirCard and PosterBoard interoperability is an export route, not a promise of continuous background playback. Imported Workshop assets and Wallpaper Engine shared resources must be user-authorized; they are not distributed in this repository.

## Local continuation checks

- `python scripts/ios/build.py --check`: passed (static contract only).
- `python -m unittest discover -s scripts/ios/qa/tests -p 'test_*.py'`: 119 passed in the continuation checkout. Three license-input smoke cases skip on clean checkouts without downloaded sources; actual CI license collection is separate.
- Windows `swiftc -typecheck`: shared models/path/repository without ZIPFoundation;
  Workshop Foundation model/session/service subset; Foundation export geometry,
  settings, keyed archives and tendies manifest. All passed. Apple SDK branches
  are not typechecked by these commands.
- `swiftc -frontend -parse`: all iOS source and test Swift passed; syntax only.
- `git diff --check`: passed.
- Pure shared-microphone eligibility helper: `swiftc -typecheck` passed; standalone compiled harness executed six cases successfully. XCTest source added but simulator XCTest has not run.
- `python scripts/check_renderer.py`: blocked immediately on this Windows host by missing Homebrew executable; actual iOS engine compiler/archive verification is established by Actions, not this unrun macOS GPU regression suite.
- `python scripts/test.py`: failed on Windows in upstream macOS-oriented script
  tests (POSIX paths/newlines, cp950 defaults, Python 3.11-only hashing, missing
  `xattr`/`sips`/`tzset` and macOS process APIs). No upstream native verdict or
  macOS regression pass is claimed; unrelated upstream scripts were not rewritten.

## Workshop follow-up in progress

- User reports author preview playback failure and requests native signed-in Workshop downloads plus progress. Source fix replaces UIKit's single-frame `UIImage(data:)` animation path with bounded ImageIO frame decode, plus real preview-byte progress and failed/retry state. Author preview is not the actual rendered wallpaper.
- A separate experimental native Rust CM/SteamPipe compiler target is under development; it is not linked to the installed app yet and no real authenticated Workshop transfer is verified. Public metadata/subscription login is not ownership authorization. App/depot access must be issued by Steam for an owning account.
- User confirms the first IPA was signed/installed/opened. iCTRL launched the real app and read its Workshop detail UI in Traditional Chinese, but repeated foreground changes and stale accessibility vs screenshot state interrupted interaction. No conversion completion or wallpaper application verified. Do not treat the runner's process metrics as app metrics.

## Next build cycle

Current build-continuation milestone is complete: final source compiled in Release, bundled source-license payload, packaged/validated unsigned IPA, and actual artifact downloaded/independently checked. Remaining source-parity work includes scene PCM mic input, licensed shared-asset import UI, live scene/web frame-provider wiring and standalone WebM integration; Workshop CM/depot downloads remain unimplemented. Signing, installation and physical scene/video/web/import/settings/export tests are deferred until the user makes the iPad available again. Do not operate the device in the meantime.
