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

## 2026-10-27 — iOS Pixiv integration and Tendies regression boundaries

Pending iOS source integration; current tree has no new commit, push, Actions build or device deployment.

- `IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B scripts/test.py`: exit 1; 34/39 Python modules passed, including all 14 iOS modules (220 reported tests). Five unchanged Windows/macOS portability modules failed before XcodeGen/native execution; the optional pinned AirCard source class was skipped.
- `python -B -m unittest discover -s scripts/tests -p 'test_ios_pixiv*.py'`: three wrappers passed, executing 31 production Swift behavior cases (17 service, six library, eight store).
- Anonymous live production Swift ranking/page/original/project/import/reload smoke test passed: 174,693 original bytes retained exactly; Pillow decoded 1000x1000 matching metadata. Temporary artwork and libraries were removed.
- Production Pixiv core/store passed Swift 5 typechecking with warnings as errors; 135 iOS Swift source/test files syntax-parsed. Both catalogs have 384 unique matching keys/placeholders.
- Tendies native integration manifest dry run only: 38 pinned inputs and 57 cases. Local package checks do not establish Flash/system playback; the startup watchdog and separate AVFoundation failure retain their documented limits.
- NOT EXECUTED for this patch: Apple SDK build/XCTest (including two new ImageIO tests), WebKit login, authenticated Pixiv, physical browsing/download/export, or system-wallpaper installation/playback.
- Owning docs: [Pixiv](../ios/PIXIV.md), [converter](../ios/PC-CONVERTER.md), [status](../ios/STATUS.md). Earlier Rayray1099 Actions successes exclude this working-tree patch.

## 2026-10-27 — Opt-in PosterBoard 27 PC packaging and complete-frame validation

Browser and paired-PC requests can select posterBoard27 while legacy stays the default. Package structure and complete frame sequences are validated; this is not proof of system playback or a repair for the measured startup watchdog.

- IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B -m unittest discover -s scripts/tests -p test_ios*.py: exit 0; Ran 217 tests, OK (one external-reference class skipped because AIRCARD_VALIDATION_SOURCE is unset); includes real FFmpeg, Swift packager and HTTP integration. The class-level skip does not subtract a passed test from the executed count.
- Real modern archive mutation regression: 56 malformed metadata variants rejected with bounded validation errors; the original archive still validates.
- python -B scripts/test.py: exit 1 in Python tests on Windows (unchanged non-iOS sources; POSIX paths, cp950 decoding, Python 3.10 API and missing macOS tools). Apple native gate was not reached.
- python -B scripts/ios/check_pc_integration_simulator.py --dry-run: 38 SHA-pinned inputs and 57 required native cases; no Apple compilation or XCTest execution claimed.
- JavaScript syntax and git diff --check passed; all 291 iOS localization keys match English and Traditional Chinese catalogs.
- Three requested Terra reviewers could not execute due to provider HTTP 503 and invalidated authentication; final review continued locally. No commit, push, app rebuild, device install or Flash in this continuation.

## 2026-10-26 — Explicit 30/60 FPS PC-conversion requests

Offline response to the reported black Collections preview/loading failure. This adds an explicit frame-rate selector and loading-risk disclosure; it does not establish a cause or a verified system-wallpaper fix.

- IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B -m unittest discover -s scripts/tests -p test_ios*.py: 163 passed, no skips; includes actual CPU FFmpeg/Swift 30-FPS archive conversion and full JPEG decode, plus HTTP forwarding at 30 and 60 FPS.
- Production Foundation-only request options compiled and executed in Swift 5 mode with warnings as errors; native size1668x2420, JPEGq2 and full-source/no-duration request fields preserved at both rates.
- Swift frontend parsing, iOS build.py --check, JavaScript syntax, 285 matching en/zh-Hant keys and format placeholders, and git diff --check passed. These are not Apple UI typecheck/build results.
- Full scripts/test.py was attempted and retried after correcting the new standalone source closure and UTF-8 environment: all iOS modules passed; five unchanged desktop/macOS-oriented modules still fail on Windows. Native Xcode test phase was not reached.
- Validation branch and commits retained; CAML, metadata, JPEG encoding and existing archives unchanged. No device calls after departure, install, Flash, respring, cleanup of installed descriptors, commit, push or merge. Apple compilation/device validation for this patch remains outstanding.

## 2026-10-26 — iOS full PC exports verified; fixed-step source awaits Apple and pairing prerequisites

- Installed ce6c5f4c native PC flow uploaded/converted/downloaded Dune173174746B SHA256bbee9496898da3dd62d8fbb692b415ee911d88c8feeb978572afc02cbd85e7df; all1976JPEGs independently byte-identical to prior fully decoded Dune. Earlier full Bocchi1800JPEG native transfer also verified.
- AirCard imported exact full Dune; isolated one-item Flash rejected saved pairing keys/fallback tunnels, like Bocchi. No respring/system-playback pass, no 10FPS Flash, no final lock Shortcut. Original Steam/shared assets remain read-only.
- Pending native fixed-step mode: exactindex/fps, zero first advance, same-command owned GPU readback, strict identity, no auto ticks/input/audio, immutable sessions; scripts/video/pendingtext rejected, no preview substitute. Not built/installed; no Wallpaper Engine reference comparison.
- Actual Windows clang++ -std=c++20 -O2 -DNDEBUG -Wall -Wextra -Werror contract PASS all18000indices, upperbound and100completion/failure races. Temporary executable removed. Swift parse and test-only C recorder syntax PASS; not Apple SDK compile.
- IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B -m unittest discover -s scripts/tests -p test_ios*.py:155PASS0skip incl real tiny FFmpeg/Swift conversion. Renderer-driver portable37run34pass3macOS-prerequisite skips; no scene GPU pass.
- Strict source closures/dryruns53Appleexport+25UIKitrecorderPASS; actual53/25 and native8tickfast/slowMetalregression UNRUN. CMake testThreads dependency scoped explicitly; standaloneCPU added routine renderer registry.
- GitHub475d41b4 fullbuild40216595709/native40216595658 refused before any steps: payment/spending-limit annotation. ntfy notified; no billing changes or futile repeated dispatch. Latest pending renderer remains source-only; AVFoundation -11819 unresolved.

## 2026-10-25 — iPad native fixture, Bocchi export diagnostics and isolated UIKit gates

- Installed 92fdedc9 through exact-dylib LCSign copy; native quadrant output observed and recovered after invalid scene switch. Real Your Name scene 2064316482 fails with missing Metal translation; thumbnail is not output.
- Bocchi 3407161102 copied read-only from authorized Workshop corpus; native muted changing video output. 2s/10FPS native tendies:20 frames9575805B, AirCard import accepted then explicitly deselected. User prohibits flashing that sample; no Flash/respring.
- Diagnostic-only db3455de Release40201153315 passed full native/Swift/package;32 actual macOS Foundation diagnostic checks. Untouched IPA11814943B SHA256ceddf2cdc57788b947bc97071c32a24ac9759581cb6a948601040aecb271235e; verified separate presign copy installed preserving library.
- Actual8s30FPS and30s60FPS native Fit/.82 exports fail copy stage AVFoundationErrorDomain:-11819. SDK AVError.h confirms mediaServicesWereReset; no memory/corruption cause inferred. Later2s30FPS succeeds60frames28711544B; high-quality full export unresolved.
- Native reader40203515983 passed generated Main@5.2 2160square60FPS 8.2s, VFR timing and all10/30/60FPS plain/pool tick checks80/240/480 each. Decoder-only macOS, not full iPad export; initial test-only optional dictionary compile failure corrected.
- Separate scene-host validation branch PR1 run40204631268 passed exactly16UIKit C-recorder tests/0skip +41offline verdict tests; actual raw xcresult independently checked and owned simulator deletion verified. Timer/notification dispatch, real counters/GPU/device excluded; not installed device source.
- Ownership40204945730:actualZIP81checks pass;source lifetime retention reproduced. Whole-pipeline pool releases sources peak1 but native RSS safety-cap after22/240 fails; not sufficient memory fix. Further render/JPEG isolation pending; no speculative production pooling/quality change.
- Original Steam assets, secrets and installed identity unchanged. All screenshots/private assets/local injection excluded from Git. User authorizes final validated best-quality Flash/respring independently; no low-quality fallback or rollback guarantee.

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
