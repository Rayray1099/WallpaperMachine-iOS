# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-10-25 — iPad installation, real export and Steam CDN continuation

- Source ff15056f: macOS Actions 40179227438 passed full ARM64 iOS Release native/Swift compilation, notices, packaging and validation; simulator XCTest remains explicitly deferred.
- Downloaded original IPA independently passed SHA256 34660c81017133025cce99abefc73b3563d85d200c3e2da326958edf708e6212, ZIP CRC/structure, actual native symbols and 541 nonempty legal files.
- Native Actions 40179227416: actual logs show 3 transport + 13 CDN tests passed, zero doc tests, followed by successful iOS ARM64 optimized compilation.
- Offline iOS QA: 122 run / 119 passed / 3 pinned-source license-input skips; build --check, 93-file Swift syntax parse, portable export typechecks, 33 provider/timing checks and backup/diagnostics execution passed.
- Both iOS catalogs have 209 matching keys with clean duplicates/placeholders. Routine scripts/test.py ran once and failed on Windows/Python3.10 compatibility: 25 modules, 17 passed, 8 failed; no upstream native verdict.
- Installed 95d82eeb on iPadOS27: six cropped screenshots establish changing author animation (6 distinct, 5 transitions, 28.94 percent union coverage), not FPS or engine playback.
- Physical synthetic H264 source import/export: MP4 60 frames at1080x1920 /377447 bytes; tendies 60 frames /5613260 bytes with834w-1210h@2x~ipad screen class; both actual share sheet.
- AirCard1.3.2 accepted actual tendies with expected thumbnail/name, Collections format, one descriptor and CollectionsPoster target. No Flash/cache refresh/Respring or OS animation pass claimed.
- User-supplied dylib local pre-sign copy independently passed byte/ZIP/LLVM checks and 27 injector tests; ff15056f then LCSign signed/installed/opened with prior item preserved. Original CI IPA untouched; no supplied binary committed.
- Live native login succeeded; old directory schema reproduced fractional weighted_load failure and fixed. New installed retry progresses to chunk_download_failed; no completed content import. Web/HEVC/sequence/long output and native XCTest remain unverified.

## 2026-10-25 — Final iOS microphone-source build artifact

- Actions40164217807 source9ff8f083: Release native engine+Swift app compile, source notices, unsigned IPA packaging and structural validation PASS.
- Downloaded final IPA5777278bytes SHA256 eec01ca1a75f1868105e130735eb3135ee4df87730d22572ee2b4712f30e6dc4; independent Windows hash/CRC/IPA checks PASS, arm64 device iOS18 floor, unsigned, en+zh-Hant.
- Linked executable includes actual C++ owe_scene_wallpaper_new and Rust rs_shader_compile_program;74 bundled legal files checked. Not prerecorded scene-video substitution.
- Shared microphone-to-web lifecycle source is included in compiled artifact. Pure gate six-case harness passed; microphone permission/capture runtime is not physically verified.
- Physical signing/install/testing deferred by user taking the iPad away. No further device RPCs after that instruction; no app FPS/memory/scene appearance claims.

## 2026-10-25 — Native iOS ARM64 build and unsigned IPA validation

- Preserved existing implementation and upstream history; committed/pushed ios/main to authorized private repository, no release tag/version bump.
- Real macOS Actions40164005806 (b2f8810b), Xcode26.3/iPhoneOS SDK26.2: native Rust wm-shader + C++ engine, Swift app, legal source texts, IPA package and validation PASS.
- Renderer archive contains639 arm64 iOS Mach-O objects; downloaded IPA also contains linked owe_scene_wallpaper_new and rs_shader_compile_program symbols.
- Actual downloaded unsigned IPA: 5756147 bytes; SHA256 d77c905186e095f546f5e0a0f5fe1381abf1ebf4c7420fdfa6373e507523fa46; ZIP CRC, structure, unsigned arm64 iOS, English/zh-Hant and74 license files independently checked on Windows.
- python -m unittest discover -s scripts/ios/qa/tests -p test_*.py:119 PASS in continuation checkout; three source-input smoke cases skip without local downloaded inputs.
- Shared microphone web-feed eligibility: Foundation-only helper typecheck and compiled standalone six-case execution PASS; native XCTest still deferred.
- Upstream python scripts/test.py fails Windows-oriented prerequisites; scripts/check_renderer.py blocked by missing Homebrew; no macOS GPU/unit regression pass claimed.
- Physical iPad testing explicitly deferred by user. No LAN transfer/signing/installation/app FPS or memory measurements performed.

## 2026-10-25 — iOS native host and build-contract checkpoint

- Preserved existing port and upstream history; reconciled Rust wm-shader + C++ C ABI renderer outputs and unsigned device build contracts.
- python scripts/ios/build.py --check: PASS, static only; no IPA compiled by this check.
- python -m unittest discover -s scripts/ios/qa/tests -p test_*.py: PASS, 100 offline tests; synthetic IPA fixtures are not a built app.
- Windows swiftc portable model/repository, Workshop Foundation and export-core typechecks: PASS; ZIPFoundation and Apple SDK branches not exercised.
- swiftc -frontend -parse all iOS source/test Swift: PASS, syntax only.
- python scripts/test.py: FAIL on Windows in upstream macOS-oriented scripts (paths, encoding, Python API version and unavailable macOS utilities); native macOS gate not reached.
- Native simulator XCTest/UI tests explicitly deferred pending simulator-specific renderer build; device C ABI archive cannot serve simulator.
- No successful Xcode build, IPA, installation or physical-app verification at this checkpoint.

## 2026-10-24 — Keep each visited desktop's wallpaper loaded and paused

Follow-up to PR #77: a display with a different wallpaper for each desktop keeps the wallpapers of visited desktops parked (renderer, bridge, web and video hosts) instead of reloading them on every desktop change; memory pressure and Stop (free memory) let them go.

- `python3 scripts/check_rust.py` — exit 0; core, bridge, core-integration and shader all pass, including the new `engine::actor::space_parking_tests` (9), `tests::space_parking` (3) and `first_frame_tests::a_wallpaper_the_display_keeps_parked_is_not_awaited`
- `python3 scripts/check_renderer.py` — exit 0; corpus and media cases skipped as listed (no local assets)
- `python3 scripts/test.py` — exit 0; 4107 tests: 4060 passed, 47 skipped, after one rerun: the first run on the final code failed `EnergyUsageMonitorTests/testKernelCountersForThisProcessAdvanceWithGPUWork` (3.7 mW against a 10 mW floor, right after the renderer check), which passed alone and in the rerun
- New Swift tests: `WallpaperSpaceParkingTests`, per-window placement and opening windows in `WallpaperSpacePinningTests`, kept clips and pages in `NativeVideoWallpaperHostTests` and `WebWallpaperHostLifecycleTests`, the auditor's kept-window excuse, pressure edges in `MemoryPressureMonitorTests`
- Not checked: no desktop run (no intro on return, the kept frame during a swipe, a shared wallpaper on several desktops, `CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces`, the memory held, release under real memory pressure); the Release app was not rebuilt

## 2026-10-23 — Different wallpaper for each desktop: windows kept on their desktop, saved posters, new panel UI

Space mode reworked: wallpaper windows of a display in the mode stay on its current desktop and move hidden on a desktop change; other desktops get their wallpaper's saved poster; Apply sets the current desktop's wallpaper; the switch moved onto the display card and the toolbar menu with a desktop strip and a searchable chooser.

- `python3 scripts/test.py` — first run 1 failure (SettingsSectionsLocalizationTests: "Mission Control"/"Spaces" keywords untranslated), fixed; rerun exit 0: 4083 tests, 4037 passed, 46 skipped
- `python3 scripts/build.py --swift-only --configuration Release` — OK (ad-hoc signed)
- Authorized desktop run, macOS 27.0.1, one display, three desktops: a standalone window probe showed CGSMoveWindowsToManagedSpace moves an own window to the current Space; re-ordering, toggling canJoinAllSpaces and moveToActiveSpace do not; an alpha-0 window stays occlusion-visible and keeps vending drawables
- Live app: Mission Control showed desktop 2 Windows 11 and desktop 3 Plastic Beach (before: every desktop showed the live window); swipes show the destination's poster; warm loads shown 0.4 s (Plastic Beach) and 0.9–1.0 s (Windows 11) after the swipe ends
- Relaunch without visiting: both other desktops and the current one got their own poster within ~3 s
- Panel: card switch, desktop strip, chooser popover and the toolbar's toggle and "· Desktop 1" label rendered as intended
- Gap: ad-hoc test builds ask again for System Audio Recording; an audio-responsive scene's first frame waits for the answer (6.4 s and 180 s stalls seen); a pixiv keychain prompt was denied
- Not checked live: Apply assigning the current desktop (unit-tested), chooser search typing, multiple displays with separate Spaces, web/video on a pinned display, VoiceOver

## 2026-10-24 — Daily active count (DAU/MAU) without an install id

- App: TelemetryActiveCount sends one ping per UTC day to /api/telemetry/active (random per-day ping id, day, version, source, monthFirst); hourly retry with the same ping, next send 0-15 min after UTC midnight; no count with WALLPAPER_MACHINE_HOME or a defaults suite.
- python3 scripts/test.py --only TelemetryActiveCountTests --only TelemetryClientTests --only TelemetryServiceTests: 18 passed, 0 failed.
- python3 scripts/test.py (full gate, worktree): Python script tests OK; native 4062 passed, 0 failed, 47 skipped; 1 runtime warning (main-thread call), not traced to this change and not baselined.
- Website (separate repo, branch feat/telemetry-active-count): npm run typecheck OK; local wrangler dev on a scratch D1 with migration 0002: retries (same and lowercase ping) counted once, a day-behind clock kept its day, a far-off clock took the arrival day, bad schema/ping/day/agent 400, cron prune kept 400-day totals and 2-day pings.
- Dashboard DAU/MAU SQL run on the scratch D1 gave the expected sums; the page's new section was not viewed in a browser (owner sign-in needed).
- Not done: no D1 remote migration, no Worker deploy, no app Release build, no desktop run.

## 2026-10-24 — Library location: move library and downloads to an external drive

- python3 scripts/test.py: passed (Python stage OK; native 4051 passed, 0 failed, 47 skipped).
- New: StorageMoveServiceTests, StorageCopierTests, StorageLocationTests, DownloaderStorageTests, WallpaperBackupTests moved-library round trip, PanelStorageActionsTests move actions.
- Another disk is simulated with a fake StorageVolumeInspecting; no real external drive, ExFAT disk or eject was exercised.
- Not checked: Settings › Storage rows and the Wallpaper Library Unavailable window visually, the removable-volume privacy prompt, a live Steam download to a moved library.
- Renderer built in this worktree with scripts/build.py --renderer-only; bindings unchanged. App not rebuilt as Release.

## 2026-10-24 — Desktop posters kept until the wallpaper changes (issue 79)

macOS 26+ WallpaperAgent keeps a full-size bitmap of every desktop picture file and never deletes it; animated wallpapers made every poster retake a new file. Snapshots that change no display, Space changes, wakes and resumes now keep a settled poster, and a frame nobody asked for never replaces one.

- `python3 scripts/test.py --only DesktopWallpaperTests` — 77 passed; the new hours-of-activity test failed (13 captures instead of 3) with the old two-minute expiry put back temporarily
- `python3 scripts/test.py` — exit 0; 4070 tests: 4023 passed, 47 opt-in skipped; Python script tests passed; 1 runtime warning (main-thread call) from another class, not raised by DesktopWallpaperTests
- Not verified: WallpaperAgent's cache on a real Mac (another app's container, not read), real Mission Control thumbnails, `AppDelegate.desktopPosterLayout` (wiring, no unit test); app not rebuilt
- Space-selection mode still takes posters on every Space visit that switches the wallpaper; not changed here

## 2026-10-23 — Report on GitHub opens the bug form with required fields

- bug_report.yml: What you did, What went wrong, What you expected and the diagnostics report are required; app facts go to optional wallpaper, version and app-details fields.
- ExternalLink.newIssue opens ?template=bug_report.yml and prefills only those three field ids; no required field is filled by the app.
- YAML parsed with PyYAML; the app's query names match the form's field ids (grep both sides).
- python3 scripts/test.py --only ExternalLinkTests --only PanelLibraryStateTests: 20 passed; --only InspectorPolicyTests: 19 passed.
- python3 scripts/test.py: 4016 passed, 0 failed, 46 skipped (after rebuilding the stale renderer library with build.py --renderer-only).
- Not checked: GitHub's rendering of the form and the URL prefill; it only takes effect once the template is on the default branch.
- Blank issues stay on for the body-prefilled link of app versions up to 1.6.0; app not rebuilt.
