# iOS QA

Executable regression for the iOS host: the official iCTRL device client, the
captured RPC schema, physical-device screenshot evidence, and Xcode unit/UI
tests. What each check proves — and what it does not — is stated here so a green
run is not read as more than it is. Ownership and integration contracts live in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Scope and evidence

QA owns `scripts/ios/qa/`, `iOS/Tests/` and this document. The Lead owns the
device lane, commits and CI. Build Agent owns `iOS/project.yml` and
`scripts/ios/validate.py`; QA tests both rather than modifying them.

All run output goes to the Git-ignored `artifacts/qa/` tree:

| Path | Content |
| --- | --- |
| `artifacts/qa/runs/<timestamp>-offline/report.json` | offline checks, counts, failures |
| `artifacts/qa/runs/<timestamp>-live-device/report.json` | live device, UI and animation verdicts |
| `artifacts/qa/runs/<timestamp>-live-device/*.png` | app-window screenshots sampled for content diff |
| `artifacts/qa/runs/<timestamp>-live-device/rpc.jsonl` | method, duration, sanitized params, errors |
| `artifacts/qa/device-lane.json` | the Lead's time-boxed device hand-off lease |
| `artifacts/qa/ipa-fixtures/` | synthetic app/IPA fixtures for validator tests |

Evidence is disposable and never cited as durable proof. Screenshots can contain
user wallpaper content: keep them out of Git and delete the run when it is no
longer needed. The harness never reads or writes `~/.ictrl/token.json`; the
official client reads its own cache. A report contains a client/schema SHA-256 and
device model, never a token, key or typed text.

## Quick start (offline; no device access)

```bash
python scripts/ios/qa/run_qa.py
```

This: imports the downloaded official client as a module (not its CLI), loads the
captured schema, runs the Python regression tests, statically audits the `wm.*`
accessibility IDs, syntax-parses `iOS/Tests/**/*.swift` when `swiftc` exists, and
exercises Build Agent's validator checks. It never opens a socket to the device
except one TCP reachability probe, which sends no RPC.

Direct test run:

```bash
python -m unittest discover -s scripts/ios/qa/tests -p "test_*.py"
```

### Official client, not homemade crypto

The client is downloaded from the device:

```bash
curl -o ../.local/ictrl/ictrl_rpc.py http://<host>:8200/skill/clients/python
curl -o ../.local/ictrl/schema.json   http://<host>:8200/schema
```

The harness imports that file (`scripts/ios/qa/official_client.py`) and calls
`call(host, method, params, timeout)`. It never reimplements pairing, X25519,
HMAC envelopes or the request keystream, and never shells out to the CLI: on
Windows `pair`'s `--name` default is `os.uname().nodename`, so every CLI
invocation raises `AttributeError` while argparse is built. The module-level call
path is functional. Override the locations with `WM_QA_ICTRL_CLIENT` /
`WM_QA_ICTRL_SCHEMA` or `--client` / `--schema`.

## Live device run (Lead-granted lane)

Physical iCTRL control is serialized by the Lead. A live run needs **two** keys:
`--device` and a non-expired lease naming `QA Agent` as holder and `Lead` as
grantor.

```bash
# Lead hands the lane for 30 minutes
python scripts/ios/qa/lane.py grant --by Lead --minutes 30

# QA runs the live suite
python scripts/ios/qa/run_qa.py --device --lane artifacts/qa/device-lane.json

# Lead (or QA, after the run) releases it
python scripts/ios/qa/lane.py release
```

`--device` without a valid lease exits 2 before importing/using credentials and
calls no device method. The harness does not pair, unlock, reboot or install; the
Lead/user keeps those actions.

The live suite performs, in order:

1. `device_info` (read-only), schema protocol/capability check, screen-lock check.
2. One `launch_app` for `com.rayray1099.wallpapermachine.ios`.
3. A visible `page_source` audit of the complete `wm.*` contract
   (`wm.library`, `wm.import`, `wm.search`, `wm.preview`, `wm.settings`,
   `wm.workshop`, `wm.export`), with `find_element` fallback for missing IDs.
4. One app-window screenshot plus `--frames` sampled app-window PNGs, default 6.
5. A content-diff verdict; a failure says animation was not proven.

Use `--tap-wm-id wm.preview` (repeatable) to open an animated preview once before
sampling. The harness taps each identifier at most once.

### Timeouts and double actions

A timeout is an unknown outcome, not a failure and not a retry prompt. The session
records the ambiguity and refuses further mutating calls. It then reads the
non-UI `logs` lane looking for `⏱ ✓ <method>`:

- completed → report success once; the action is **never resent**;
- `⏱ TIMEOUT` → report the stuck UI queue and stay blocked;
- unknown → stay blocked and require a human/Lead decision.

Read-only calls (`page_source`, `screenshot`, `find_element`, `logs`) remain
allowed. This is tested in `tests/test_device_session.py`, including a JSON-RPC
`error` returned with HTTP 200 (the official client does not raise on it).

### Animation evidence, not FPS

The live suite asks for lossless PNG screenshots of the app window, decodes them
in-process and compares adjacent samples pixel by pixel. A pass needs all three:

- at least 3 adjacent pairs whose changed-pixel ratio is at least 1% (`--min-changed-ratio`);
- at least 4 distinct sampled frames and more than 3 transitions (`--min-transitions`);
- the union of changed pixels covering at least 3% of the frame (`--min-coverage`).

Identical pixels never pass however much wall-clock time passed. Timestamps are
scheduling metadata only. The report contains **no FPS**: capture and envelope
decryption dominate each sample, so the interval cannot be converted into the
app's frame rate. `iCTRL` runner CPU/memory are runner metrics, not app metrics,
and are not reported as app measurements.

## Validator fixtures

Build Agent's `scripts/ios/validate.py` takes a built `.app`, an IPA, the renderer
archive, a manifest and checksums. Synthetic fixtures cannot supply the renderer,
so QA drives its structural checks directly (module-level `check_ipa`,
`check_bundle`, `check_executable`) instead of pretending an incomplete build
should pass the CLI. Fixtures include:

- a valid unsigned arm64 iPhoneOS app at the iOS 18 floor;
- missing `Payload/`, `Info.plist`, executable or localizations;
- traversal member `Payload/../../escape.txt`, x86_64 slice, simulator platform,
  old deployment target, non-PIE, and an IPA plist that differs from the app.

The CLI integration test asserts the report's verdict is `fail` when the renderer
is absent while `ipa.structure` and bundle checks pass — the validator reports
what it checked rather than failing open.

## iOS XCTest suite

| File | What it asserts |
| --- | --- |
| `iOS/Tests/Unit/Models/WallpaperModelContractTests.swift` | raw enum values, natural JSON types, Codable round-trips, value semantics |
| `iOS/Tests/Unit/Library/AssetPathSecurityTests.swift` | traversal, absolute/colon paths, symlink escape, root loop |
| `iOS/Tests/Unit/Library/LibraryStoreSecurityTests.swift` | contained URLs, import symlink refusal, backup traversal refusal |
| `iOS/Tests/Unit/Library/LibraryStorePersistenceTests.swift` | save/reload, favorites/edits, valid backup rejection by generic import with live memory/files preserved, explicit backup replacement round-trip, corrupt/future backups, removal |
| `iOS/Tests/Unit/Media/MicrophoneCaptureEligibilityTests.swift` | enabled/active/visible capture gate, negative/zero/multiple consumers; no microphone hardware |
| `iOS/Tests/Unit/Export/LiveCaptureTimingTests.swift` | monotonic pacing, drift/overflow and finite bounded capture dimensions |
| `iOS/Tests/Unit/Export/WebWallpaperExportProviderTests.swift` | prepare/reuse, retained size, final-frame drift, late wake, invalid/repeated timestamps, cancellation/timeout with late callback, readiness and failed prepare |
| `iOS/Tests/Unit/Workshop/WorkshopContentDiagnosticsTests.swift` | exact safe-code allowlist, distinct discovery failures, unknown/secret text suppression, explicit/fallback phases |
| `iOS/Tests/UI/WallpaperMachineIOSUITests.swift` | full `wm.*` contract on launch, settings sheet, item preview/export |

Tests use a unique temporary directory and clean it in teardown; they never touch
the installed app's Documents, the network or a real wallpaper target.

The unit target (`WallpaperMachineIOSTests`, sources `iOS/Tests/Unit` and
`iOS/Tests/Support`) and separate UI target (`WallpaperMachineIOSUITests`,
sources `iOS/Tests/UI`) are in `iOS/project.yml`. UI launches supply a unique
UUID in `WALLPAPER_MACHINE_UI_TEST_ID`; the app resolves it inside its own
sandbox temporary directory rather than using the test runner's container.
Device builds do not run these tests. The initial CI job explicitly defers
simulator testing until a separate simulator renderer build and test stage are
configured; a device archive must never be linked into a simulator test app.

### Not verified on Windows

Windows has no Xcode or iOS SDK. On this host the Swift files are only
syntax-parsed (`swiftc -parse`); the unit/UI tests are **not executed** here.
Only a macOS runner with Xcode can compile and run them:

```bash
cd iOS && xcodegen generate
xcodebuild test -project WallpaperMachineIOS.xcodeproj -scheme WallpaperMachineIOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'
```

The same limitation applies to the app: live-device QA cannot run until CI has
produced/installed a build and the Lead hands the lane. A missing live run is
reported as not verified, never as passed.

## Physical checkpoint: 2026-10-25

These are bounded device observations, not a blanket parity claim. See [STATUS.md](STATUS.md) and [EXPORT.md](EXPORT.md) for the owning feature boundaries.

| Check | Observed result | Not established |
|---|---|---|
| Release/native package | Latest `b4f87626`: actual ARM64 Release build 40185800564 plus 21 macOS Foundation filesystem checks; unchanged native transport previously passed 4 + 18 tests in 40181346861; original IPA independently validated | Simulator XCTest, signed-release trust or legal clearance |
| Native Workshop | User-authenticated item 3799142774 completed download, native verification and import; **In your library / Download update** plus new library item | Intermediate byte-progress capture, cancellation, update/recovery or more items; compression format of live chunks was not recorded |
| Downloaded web playback | Real WKWebView opened for that item, sampled content black | Author thumbnail/animated preview is not playback; root/assets/author features need actual project evidence |
| Copied CodeTime web | Allowlisted user project 3419679793 imported, actual current clock advanced, page theme switch changed appearance | Small preview crops the large author layout; not full viewport/property/WebGL parity |
| Copied Dune video | Allowlisted H.264 project 1403625644 imported; four distinct native preview samples, three transitions, 3.1562% changed-area coverage in a conservative inset crop | Measured FPS, sustained playback or correct loop; no source audio track |
| Live web tendies | Synthetic canvas on `ff15056f`: default 30 requested FPS drift error; reduced 10 requested FPS / 2 s completed 20 frames, 1668×2420, 2,230,932 bytes | That archive predates CAML geometry correction; OS playback not passed |
| Corrected web tendies | Installed `326dd9d1`: 20 frames, 1668×2420, 2,222,209 bytes; actual returned archive passed 75 checks including all JPEG decodes/changes, ordered refs, centered CAML and matching metadata IDs; AirCard imported it as one Collections descriptor | Wide web strip letterboxed with about 874-pixel top/bottom bars; no private CAML runtime, system Flash/respring or exact loop cadence |
| Packed scenes | Initial `55579c69` physical import failed with unsafe-path error. Corrected `b4f87626` Release 40185800564 passed actual macOS Foundation 21 checks; user installed/retried, then RPC confirmed new scene library item plus previous five items | Import only: empty synthetic scene is not renderer proof; real scenes held for missing licensed shared assets; special actual `/var` alias variant explicitly skipped in CI |

Copied real-project source hashes, sizes, timestamps and identities were unchanged before/after ZIP creation. No asset contents, device screenshots, supplied dylib or local injected IPA are committed. The temporary receiver accepts only exact named synthetic outputs and does not grant app-filesystem or personal-library access.

## Native scene startup regression (local / CI, no device access)

`SceneResourceDirectories` is exercised directly by `scripts/ios/test_scene_resources.swift`, compiled with the actual Foundation helper. Windows execution passed 32 checks and reproduced the old host's missing-SharedAssets setup. The same 32 checks actually passed on macOS in Release workflow [40189391576](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40189391576), alongside 21 canonical asset-path checks, before full app compilation. This filesystem test is not Metal rendering.

`bash scripts/ios/check_scene_startup.sh --artifacts-dir <new-run>` builds only four native macOS engine test binaries and executes their GTest JSON reports. `SceneLoadFailurePolicy` has no GPU prerequisite and must actually execute without skips: missing shared mount, missing project mount and a table of six pre-admission failures must expose a specific backend reason with zero native frames/callback credit. GPU failure/recovery and self-authored packed-quad pixel tests accept only explicit no-Metal-device skips, reported separately. Missing fixtures, zero matched tests, disabled cases and other skips fail this gate. The dedicated `iOS Scene Startup (native macOS)` workflow is not an iPad/simulator test.

Generate the positive import/render control with `python3 scripts/ios/make_native_scene_fixture.py --output <new-folder>`; all assets are procedural/self-authored and all dependencies are packaged. Nine Python tests now cover exact formats, closure, fixed ZIP creator metadata, per-member hashes, determinism and overwrite refusal. The first Windows/macOS archive-hash difference was reproduced solely by the ZIP creator-system field; uncompressed member bytes were unchanged. The generator now pins that field and permissions, and reports member hashes independently of compression. The earlier empty package remains an import-only negative rendering control; it must not be called a successful Metal frame. Actual native run [40189738436](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40189738436) on ARM64/Xcode 26.3/macOS SDK 26.2 passed **56 tests, zero skipped**: 3 loader + 25 container CPU cases, 13 failure/recovery + 14 synthetic render + 1 packaged-quad GPU case. The empty-scene negative test remained at zero presented/completed frames; the valid replacement-recovery case actually presented again, and the packed quad's four pixels matched. The first host build failed before testing under the runner's default Xcode 16.4; selecting the current stable toolchain fixed that infrastructure issue without a production renderer change. Eight offline GTest-verdict parser tests additionally reject false coverage/skip claims. Final run [40190529059](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40190529059) repeated all 56 native tests without skips and executed the 17 Python fixture/verdict tests successfully. Its retained fixture ZIP exactly matches the Windows-generated bytes: 1,254 bytes, SHA-256 `bb6549cb5696372b0fc4b0d85aef7aee41c46fbb117cc7e6380ca435cb339669`; the generator itself still reports `actual_gpu_frame_verified: false`, and only the separate executed pixel test supplies rendering evidence. This is macOS native evidence only; physical testing is explicitly paused while the user is away.

## Known gaps and reporting rules

- `wm.preview`/`wm.export` live in an item's detail screen. The UI test skips that
  case only when the library has no imported item, with an explicit skip reason.
- The animation test proves content change, not motion direction or loop
  correctness; a blinking element plus an animation can pass if the coverage
  thresholds are met. Raise the thresholds for stricter evidence.
- Preview/export rendering itself, video codec support, WebGL and the scene
  renderer are established only by CI builds and the Wallpaper Agent's own
  evidence; QA does not infer them from screenshots.
- `LibraryStore` was still being implemented while these tests were written. They
  target the documented contract (`init(rootURL:)`, mutable published
  `items`/`collections`/`playlistIDs`/`settings`, `save`,
  `exportBackup`/`restoreBackup`); reconcile them with the implementation before
  claiming a green XCTest run.
- Never cite an `artifacts/qa/` path as durable proof; cite the command and the
  measured counts, and say what was skipped or could not run.
