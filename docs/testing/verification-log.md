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

## 2026-10-25 — iOS physical geometry and scene host lifecycle

- Source92fdedc9: physical output pixels independent of .25...1 native render quality; real set_render_scale before config; URL replacement with fresh session; deferred detached/collapsed work; first-error host shutdown latch; eligible monotonic first-frame wait, no fake readiness.
- Actual Windows Swift5-mode/warnings-as-errors execution:145 geometry+119 timing+21 session checks=285PASS. Reproduced old2x/3x point/pixel and quality-scaled drawable mismatch. Host frontend parse passed syntax only.
- Actual macOS ARM64 Release40192791966 PASS with Xcode26.3/iPhoneOSSDK26.2/iOS18.0floor. All285helperchecks actually executed and passed on macOS, plus32resource+21pathchecks; full native/Steam/Swift/notices/package validation PASS. Simulator XCTest explicitly deferred.
- Original unsigned IPA11805758B SHA25691b0227b375e388b6e245d0b9ec9bf2412cb12b986fbec836c74fe3f2f56aaa8, source92fdedc957807d58fe75e0d84f1f8b0e8b1adf8b; not injected/signed/installed. Prior30a48125original and evidence preserved.
- Native macOS40192791935 PASS56/0skipped:3async loader+25containerCPU and13failure/recovery+14synthetic+1packedquadGPU;17fixture/verdictPythonchecks alsoPASS. Private process-owned textures/layers/null audio, not UIKit lifecycle execution.
- Offline122iOSQA119pass3licenseinputskips;17fixture/verdictregressionspass;matching213unique nonempty keys inboth shipped catalogs. Scope-reviewed checked-return/pointer lifetime, handle cache reset and backend-error priority; no per-frame loop/timer added.
- User remains away: no iPad/RPC/probes, GUI/desktop/VM/audiohardware, signing/install, secret access, AirCard Flash/system writes or respring. Physical sceneA→B, rotation/scale, background timing and native first-frame confirmation still deferred; no WallpaperEngine reference comparison.

## 2026-10-25 — iOS scene startup prerequisites and native load diagnostics

- Source 30a48125: prepare mandatory empty SharedAssets before native allocation; optional cache; preserve startup errors. Native early failures publish sanitized Prepare reasons without frame credit, and failed replacements stay blocked across resize until a successful commit.
- Actual macOS ARM64 Release build 40189391576 PASS with Xcode 26.3 / iPhoneOS SDK 26.2 / iOS 18.0 floor; real Foundation helper 32 checks and asset containment 21 checks PASS. No simulator XCTest dispatch.
- Original unsigned IPA 11,798,049 B SHA256 6a029b5fd4b71a19e236c499f585b80370b4b8ec560f84904d72d2c9e6cf57a8. Independent ZIP/plist/Mach-O/resource verification:23 checks pass,0 fail,7 explicit scope skips; all541 legal files unchanged.
- Native macOS run40189738436 (CI-only80a9acaa) actually compiled and executed56 tests:3 async loader+25 texture/container CPU;13 failure/recovery+14 synthetic GPU+1 packed-quad pixel tests;0 skipped. Private process-owned GPU layers/textures and null audio only.
- Initial native run40189391622 failed before tests under runner default Xcode16.4 missing C++20 jthread/stop_token; selecting installed stable Xcode26.3 and compile-only prerequisite check fixed test infrastructure, not production renderer policy.
- Offline checks:122 iOS QA tests119 pass3 license-input skips;37 renderer-gate tests34 pass3 macOS prerequisites skipped;9 procedural fixture+8 verdict-parser tests pass. Routine upstream Windows gate previously failed platform assumptions; no full macOS app XCTest pass claimed.
- Old empty packed fixture is import-only: Metal admission refuses no shader-translation attempt. Positive self-authored fixture includes model/material/shader pair/TEX; actual Mac quad pixels pass. ZIP creator metadata is now pinned and payload hashes reported; no Workshop assets committed.
- Physical iPad testing/install explicitly deferred until user home. No iPad/RPC probes, VM/reference comparison, signing/install, AirCard Flash/system writes/respring, desktop automation or audio hardware. No on-device rendering fix or arbitrary licensed-scene pass claimed.

## 2026-10-25 — Canonical asset-root regression reproduced and packed iPad import retested

- Physical55579c69 packed-scene import FAILED: user observed Unsafe imported asset path: scene.json; library unchanged. This is retained as failure, not inferred success from a disappearing picker.
- General AssetPath correction b4f87626 builds normalized validated components from canonicalRoot, preserves containment and refuses child links including dangling links; no wallpaper-ID/title specialcase. Source review and Windows actual Foundation21checks passed.
- Actual macOS Foundation executable in Actions40185800564 reproduced old algorithm false containment rejection2/2 synthetic root-alias cases plus raw-backslash mismatch; corrected21checks passed. Actual /var-to-/private/var variant explicitlySKIPPED because runner temporary root notunder/privatevar; no false23check claim.
- Full actual ARM64 native/Swift Release build/package/validation40185800564 PASS. Original IPA11,791,067bytes SHA256593a818701270dc0c8d656edf3b49bcaefd36ee50820c5762e22f111e49b147c;857safeCRCentries,definedengine/shader/5SteamABI,541legal files verified.
- Separate user-authorized pre-sign exact-dylib copy11,767,593bytes SHA2566034e4192a4839bef4d6b0062c74acb2d495345c262ca9396908617aafbfadf8;onlymainchanged+onedylibadded,all856otherZIPrecordsbyte-identical;LLVMparsesall3. Originaluntouched;no release/version bump.
- User confirmed installing b4f87626 and retrying same537byte self-authoredPKGV0001 ZIP without errors; officialdeviceRPC thenconfirmed WM QA Packed Scene as newscene-type item with allfiveprioritems preserved. Import passes;emptyobjects is not proofrealMetalrendering.
- Earlier actual nativeSteam download/import, realCodeTime/Dune tests and75check decodedlivewebarchive remain revision-scoped to326dd9d1. Correctedarchive alsoAirCardimported;noFlash/systemwrites/cache-refresh/Respring.
- FocusedofflineQA122run119pass3missinglicenseinputskips;staticbuildconfiganddiffchecksPASS. NativeappXCTest remainsdeferred;earlierWindowsroutinegatefailedplatformmodules anddidnotreachXcode. Real scenes stillheldmissinglicensedsharedassets, downloadedRhineLabWKpreviewblack,letterboxedwebcapture/fullscreencomposition unresolved.

## 2026-10-25 — iPad native Workshop download and inspected live tendies export

- Actual macOS ARM64 iOS Release builds40181346724 (326dd9d1) and40183702083 (55579c69) passed full native/Swift compilation, packaging and IPA validation; simulator XCTest explicitly deferred, not passed.
- Independent original55579c69 IPA verification:11,791,167bytes SHA25697cc74ddcbfe9b7023d03d16b09dd5eb782ba039cc48be3c7d88b99fc2b13b6a;857safe ZIP entries;defined engine/shader/fiveSteamABI symbols;541nonempty legal files byte-identical to prior build.
- User-authorized separate exact-dylib pre-sign copy independently verified, LCSign re-signed and installed; latest app opened and preserved all five existing library items. Original CI package untouched; no release/version bump.
- Native workflow40181346861 logs:4transport+18CDN tests pass, actual optimized ARM64 iOS compile. Live user-authenticated Workshop3799142774 completed native download/file verification/library import; final In your library/Download update and new library tile verified. Live chunk compression format was not recorded.
- Real copy-only CodeTime3419679793 and H264 Dune1403625644 ZIPs imported; source bytes/hashes/timestamps/identities unchanged. CodeTime clock/theme responds but small viewport crops; Dune4distinct inset preview samples/3transitions/3.1562%changed-area coverage, notFPS or loop proof.
- Corrected326dd9d1 live web-to-tendies10requestedFPS/2s completed20frames1668x2420,2,222,209bytes. Explicit synthetic-only Safari Files transfer returned actual archive SHA25683a51044552a50480bea6e648e36f8c65d87db91ad1b5daab32be214ad9d61b3; temporary receiver stopped.
- Independent actual-content validation75checks passed:all20JPEGs fully decoded/changing,32CRCs/members,ordered asset refs,centered actualCAML coordinates,2s declared loop,matching IDs/keyed-archive references. Actual wide captured strip letterboxed with about874px bars above/below, not full-screen portrait viewport.
- Same corrected archive imported into AirCard as Collections/one descriptor/Descriptor Archive/CollectionsPoster target. No Flash/cache refresh/Respring/system wallpaper writes. ExternalID rewrite/private runtime/cadence/recovery remain unverified.
- Root-level packed-scene import55579c69 portable actual Swift execution and independent review passed;9XCTest methods added, nested missing JSON deliberately rejected. Small real scenes held for missing licensed shared shader/include/texture inputs; synthetic physical import pending human Files confirmation.
- Final focused offline QA122run/119pass/3missing-source-license-input skips;build.py --check and diff check pass. Earlier routine scripts/test.py failed Windows/Python3.10 platform assumptions,17/25modules passed;Xcode gate not reached,no native XCTest/macOS regression claimed. Downloaded RhineLab realWKpreview black; no author-preview substitution claimed.

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
