# Local PC conversion for iPad

The PC converter is an alternative video-export path: CPU FFmpeg decodes and fits the original video; the shared iOS `TendiesManifest` and `ZipArchiveWriter` generate the archive. It bypasses, rather than fixes, the unresolved on-device AVFoundation media-services reset. It does not render scene projects or export author thumbnails as animation.

## Start on this computer

Requirements: Python 3.10+, Swift compiler, FFmpeg and FFprobe on PATH. Windows also checks `C:\FFmpeg\bin`. No Python packages, cloud service, GPU, microphone or audio output are required.

From the repository root:

```powershell
python -B scripts/ios/serve_converter.py --host 192.168.2.200 --port 57351
```

Use the computer's actual private IPv4 address. The default is loopback-only `127.0.0.1`; to use the iPad, explicitly bind the computer's trusted-LAN address. Unspecified/public binds are rejected. The convenience launcher keeps a console open:

```powershell
& scripts/ios/start_converter.ps1 -BindAddress 192.168.2.200
```

The console prints a private connection URL with a per-run `#token`. Open the **whole URL** on the PC or iPad. Both must be on the same trusted network and the console must stay running. Do not post that capability publicly. No firewall, startup task or system-network setting is changed by the tool. Restarting generates a new connection token and new per-file download keys; reopen the newly printed link rather than resuming an obsolete URL.

A trusted local file can be copied and queued at startup without uploading it through a browser:

```powershell
python -B scripts/ios/serve_converter.py --host 192.168.2.200 --port 57351 `
  --input 'C:\Videos\wallpaper.mp4' --title 'My wallpaper'
```

Only this local CLI accepts a local path. HTTP accepts video bytes, never a filesystem path or remote URL.

## Use from the iPad

1. Open the printed private URL in Safari.
2. Choose a video and name, select an explicit frame rate/JPEG quality and package layout, then upload. `legacy` is the default; `posterBoard27` is an experimental compatibility option.
3. Wait for conversion and archive validation. Progress and errors appear on the page.
4. Download the completed `.tendies` and save it to Files. Large downloads support `HEAD`, byte ranges and strong ETags for resumption.
5. Import that exact file in AirCard. **Import is not Flash, and neither import nor an archive pass proves system playback.** Flash/respring must be a deliberate user-authorized action and may require a valid AirCard pairing/tunnel.

The native app's paired-PC integration uses the same private URL and protocol. It now exposes **30 FPS (default)** and **60 FPS (higher loading risk)** instead of hardcoding 60 FPS; the selected value is captured when conversion starts. Its token stays in process memory, not preferences/backups. It streams the managed video to the PC, polls only its returned job UUID, downloads into a temporary file, and verifies exact size, ZIP signature and streamed SHA-256 before saving into Files → WallpaperMachine → Exports. It never follows redirects or automatically installs a wallpaper. Earlier Apple client/importer tests and full ARM64 builds passed before the new FPS selector; this change still needs Apple compilation/device validation. An installed iPad completed the earlier full Bocchi upload/conversion/download/SHA-256 round trip, preserving its library. This is still not system-wallpaper installation or playback verification.

The browser and native paired-PC sheet also expose **Legacy (default)** and **PosterBoard 27 (experimental)**. Both capture the selected layout with the request and send `package_layout=posterBoard27` when opted in. Python's `convert(..., package_layout="posterBoard27")` and both local CLIs' `--package-layout posterBoard27` select the same path; the server passes `packageLayout` to the Swift frame packager. Job status and completed-job receipts retain the selected layout, including restoration after restart. The native receipt labels its value as requested: download integrity checks do not independently establish the archive's layout or system compatibility. Omitted layout fields remain legacy-compatible.

The current source also carries a keyed-archive format repair candidate for the
modern package: production provider-info, optional display-name, suggestion and
modern configuration archives are intended to be binary property lists with true
NSKeyedArchiver UID references. The suggestion record follows the stock
Collections split between `displayNameLocalizationKey = Collections`, the
user-facing localized title, the numeric `.DYNAMIC` descriptor identifier and a
separate gallery identifier. This repairs serialization/metadata shape only;
it is not evidence that missing suggestion metadata caused a picker failure or
that PosterBoard will accept, display, animate or loop the archive.

## Output and limits

- Native and browser UI default: **full duration, explicitly shown 30 FPS, 1668×2420, aspect Fit, silent JPEG sequence**, screen class `834w-1210h@2x~ipad`. The native client carries the selected 30/60 FPS through upload and reports the requested rate with the saved file. The existing headless CLI/API default remains 60 FPS for compatibility; pass `--fps 30` or `fps=30` explicitly. Existing archives are never rewritten.
- JPEG `q=2` is the tool's highest allowed FFmpeg MJPEG quality, with `yuvj444p` output. It is **lossy**, not identical to UIKit's numeric compression-quality scale.
- Fit preserves the entire image; a square video has 376-pixel top/bottom margins at the default size. A landscape video has larger margins. No silent crop, FPS reduction or duration truncation is used.
- Source FPS can differ from requested output FPS. Explicitly choose the rate you want; requesting more frames does not invent source motion.
- The OS controls actual playback cadence and duration. A 1,800-frame/30-second archive is nominal 60 FPS, not proof that PosterBoard presents at 60 FPS.
- Input: regular local MP4/MOV/M4V/MKV/WebM/AVI, maximum 2 GiB. When pixel-aspect metadata is unspecified, the converter reports a square-pixel assumption and preserves stored width:height. Explicit non-square sample aspect, malformed metadata, unsupported timing and unsafe sources fail rather than distort.
- One active upload/conversion. Maximum 600 seconds, 18,000 output frames, 120 requested FPS, even dimensions 64…4096 and at most 12 million pixels.
- Bounded staging/archive/job sizes and disk-space checks apply. A job fails clearly rather than lowering quality to fit.
- Up to 20 in-memory/history jobs. Use another `--data-dir` when full. No automatic history/output pruning is performed.

### Playback risk is separate from archive validity

An archive of JPEG frames is not a streamed movie. Frame count and decoded pixel size matter independently of compressed ZIP size and requested FPS. Native 1668×2420 RGBA8 is 16,146,240 bytes per frame; 988 frames would be about 14.86 GiB **if all decoded frames were resident at once**. This is arithmetic, not a measurement of PosterBoard's residency or proof of an out-of-memory failure.

The UI now warns about loading risk without silently shortening, resizing or recompressing the output. Primary-source comparison: [Nugget's 400-frame admission safeguard](https://github.com/leminlimez/Nugget/blob/94908594ee80e1bbdffd10bbde418b86c64c2754/src/controllers/video_handler.py#L64-L72) and [Placard's warning above 30 FPS](https://github.com/frs0n/placard/blob/7dcefb610cc60ae909b6046beee7adb691148e44/placard/VideoWallpaper.swift) are producer safeguards, **not documented Apple hard limits**. Thirty FPS alone does not establish compatibility; a long native-resolution sequence may still fail to load.

Black previews, a loading spinner or missing Collections entries do not identify the cause by themselves. AirCard's [missing-wallpaper report](https://github.com/Mak5er/AirCard-iOS/issues/53) and [iOS 27 disappearance report](https://github.com/Mak5er/AirCard-iOS/issues/73) remain reports, not verified fixes. A separately approved short diagnostic can reduce frame-count pressure, but old injected descriptors can confound the result. No automatic descriptor deletion, preference reset, AirCard installation, Flash or device operation is introduced here. The current offline changes are not a proven repair for the system selector.

The converter and native exporter share the same package generator and default to the legacy layout. Newer third-party iOS 27 modernization involves coordinated CAML, document-unit, plane, naming and rendering-metadata changes, not just FPS or one family field; see [the opt-in diagnostic package contract](EXPORT.md#modern-package-layout-is-independent-of-fps). An explicit browser/native paired-PC selection, API option or CLI flag now carries the modern layout through the server and frame packager. It remains a compatibility experiment, not a validated repair or a streamed-image implementation. The validator checks contiguous JPEGs, frame references, timing and the logical screen class for both layouts; the modern path additionally requires dictionary-shaped asset metadata, three distinct plane references with matching root documents, and the Clownfish family.

#### Distinguish startup watchdogs from memory-limit events

A supplied iPadOS 27 CollectionsPoster report establishes a **10-second `scene-create` watchdog termination** (`FRONTBOARD`, `0x8BADF00D`). Its main-thread snapshot is in ImageIO JPEG decoding, reached through QuartzCore image preparation, `CAKeyframeAnimation` render-value preparation and the first UIKit commit. This makes startup image/keyframe preparation a concrete compatibility lead, rather than evidence of an unsupported playback FPS. The snapshot does **not** identify the archive being loaded, establish that decoding occupied the entire allowance, or prove that all frames were resident. It predates the later short diagnostic Flash; do not assign it to that diagnostic. See Apple's [watchdog interpretation](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations).

The separately supplied Jetsam event identifies **backboardd**, not CollectionsPoster, AirCard or the iCTRL runner, as the `per-process-limit` victim. Use the process `reason` and `name`, not just `largestProcess`; `rpages * pageSize` is that process's reported memory accounting, not a universal wallpaper limit. Apple's [Jetsam report guide](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports) describes these fields. AirCard's pinned [NeoSpring helper](https://github.com/Mak5er/AirCard-iOS/blob/40640c4d827aeab8d798285b57d24fcf6be070d0/ios-app/RespringHelper.swift) creates many full-screen blurred layers and repeated allocations, so respring is an independent pressure confounder; the event alone does not prove that helper ran or that Flash completed. Neither report validates the short diagnostic's installation, identity or playback. No automatic re-encoding, truncation, descriptor cleanup or reset follows from this diagnosis.

## Security and storage

This is **unencrypted HTTP for a trusted private LAN**, not an Internet service. Exact Host/Origin checks and bearer authorization protect upload/status/cancel. Downloads use distinct per-file capabilities; the global token is not put in download queries or request logs. Static files are explicitly allowlisted, titles are rendered as text, and CORS/directory listing/arbitrary URL fetch are not enabled.

Runtime data defaults to `artifacts/ios-local-converter/data`. Each UUID job owns its input copy, temporary frames, private tool logs and output. Tool stderr is not sent to the web UI. Completed jobs receive a bounded, atomically published receipt with exact byte size and SHA-256. Only valid receipts restore on restart; tampered/incomplete output is ignored, not deleted. Existing Steam assets remain read-only. Source-hashed optimized Swift packager binaries are cached under this data root.

These runtime files are private, Git-ignored and disposable. Preserve delivered archives/receipts before cleaning artifacts; do not treat the default directory as a backup. For longer-lived use, pass an explicit data directory under your own control. Stop with Ctrl+C; this cancels active work and closes the worker. The session's managed background instance can also be stopped by the agent.

## User-owned shared scene assets

A scene can require shared shaders/textures that the app cannot redistribute. A separate manifest-backed resource import lives in Settings; this does not make the video-only PC worker a scene renderer. Package only your own installation with explicit source/output paths:

```powershell
python -B scripts/ios/package_shared_assets.py `
  --assets 'E:\SteamLibrary\steamapps\common\wallpaper_engine\assets' `
  --output 'C:\Transfer\owned-shared-assets.zip' `
  --texture materials/particle/halo.tex `
  --texture materials/particle/halo_2.tex `
  --texture materials/particle/nature/rosepetals.tex `
  --texture materials/util/noise.tex `
  --texture materials/util/white.tex
```

The destination must be new and its parent must exist. All shader files are included; additional textures are exact paths relative to the owned assets root, not guessed aliases. Input links/reparse points, unsafe names, executable/special files, duplicate/case-folded paths and quota violations fail. The packager hashes each original before/copy/after and verifies the final ZIP. Never commit or publicly redistribute that private resource pack.

Transfer the ZIP privately to Files and explicitly choose **Settings → Import owned shared assets**. The app checks the exact manifest member set, SHA-256, CRCs, ZIP metadata and actual extracted-byte limits. It fully stages before stopping native scene readers, then publishes under an ownership gate with synchronous rollback and a retained previous-assets directory. Same-source/failed scenes reset afterward; dismantled/stopped views are not revived. An active scene export blocks replacement. None of this proves a particular shader translates or the real scene renders.

The installed native scene build separately captures the actual renderer's owned composition texture through its scoped live mailbox. It uses a full native-size canvas, mute/microphone-off, exact-size validation and monotonic live timing; excessive drift fails without reducing quality/FPS. Your Name hit that guard at 60 requested FPS. A dedicated fixed-step native replacement is now implemented in pending source, but its Apple compilation/GPU/device gates are blocked and no replacement build was installed. It is distinct from this video-only PC worker and is documented in [EXPORT.md](EXPORT.md#pending-fixed-step-native-scene-export). Neither path substitutes an author thumbnail.

## Verification and actual observations

- Current pending Tendies/Pixiv integration (2026-10-27): the final `IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B scripts/test.py` run passed all 14 iOS Python modules (220 reported tests, including real tiny Swift/FFmpeg conversions and the three wrappers executing 31 Pixiv Swift cases). The optional pinned AirCard source class was skipped. The overall gate returned exit 1 in five unchanged upstream Windows/macOS portability modules, before XcodeGen/native execution; [details and Apple verification boundaries](PIXIV.md#verification-boundaries). The 38-input/57-case native integration manifest was checked in dry-run mode only. This patch has no new Apple build or device-playback result.
- The focused Tendies regression is `python3 -B -m unittest discover -s scripts/tests -p 'test_ios_tendies_posterboard27.py' -v`. The Windows portable run passed **9 tests**; the same command is now a macOS step before the iOS ARM64 build, where the Darwin-only `NSKeyedUnarchiver` proxy traversal executes. The checks establish binary UID encoding, keyed-archive graph shape and identity relationships; they do not establish picker visibility or PosterBoard playback.
- Earlier converter baseline: `IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B -m unittest scripts.tests.test_ios_local_converter scripts.tests.test_ios_converter_server scripts.tests.test_ios_shared_assets_pack`: **83 passed, no skips** (16 engine including two actual optimized Swift/FFmpeg tiny conversions; 36 HTTP; 31 owned-assets packaging). Transport tests include exact range reconstruction, authentication, cancellation, restoration and strict persisted aspect-assumption disclosure.
- Actual Apple [39-case integration gate](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40214634291): **39 passed, zero failures/skips**, consisting of 7 PC-client, 12 resource-installer and 20 CPU scene-mailbox/timing tests. Separate [UIKit host gate](https://github.com/Rayray1099/WallpaperMachine-iOS/actions/runs/40213825556): **21 passed**, using the explicit native-operation recorder—not a real GPU renderer.
- Actual authorized Bocchi source: **30 seconds, 60/1 FPS, 1,800 frames**. The PC produced **840,285,420 bytes**, SHA-256 `207baa7bfcbecbaa2ac59f0671742fefb32844458f801b7403cc2d5be3eb8ef2`.
- Independent actual-byte validation fully decoded all 1,800 JPEGs and checked all 1,812 ZIP CRCs, ordered CAML/metadata, dimensions and frame changes. Five fresh CPU reference frames matched exactly. Minor JPEG ringing at four padding-boundary rows is expected lossy encoding, not a crop or lower-quality fallback.
- Actual Safari downloaded the full archive after resumable-download support was added; AirCard imported the named full-quality file. Only it was selected for Flash; the prohibited 10-FPS sample stayed off.
- **Flash failed**: AirCard reported rejection of its pairing keys and fallback tunnel timeouts. No respring or system-playback pass followed. Fixing/exporting the archive does not repair AirCard pairing, and no keys were read or replaced blindly.
- The native PC client on installed `fd87a824` uploaded the unchanged Bocchi source and downloaded/SHA-256-verified **840,147,958 bytes** (`116b516b0d74e581bf24a957164422f99540df106d4e2cc7b9755a65205c2291`) into Exports. All 1,800 JPEG payloads match the first validated archive byte-for-byte; shorter title-bearing ZIP paths/metadata explain the size difference.
- Dune's actual full-length archive has **1,976 JPEGs**, **173,285,868 bytes**, SHA-256 `b4d2bdae6d4d9585fbf876d9146d9afc5cdd1747712e500a11d02ef01cbeaa61`. All JPEGs decoded, all 1,988 ZIP CRCs passed, and five fresh CPU references matched exactly. The installed scene-enabled app subsequently completed another real Dune upload/conversion/download, displayed the aspect-assumption notice, and verified **173,174,746 bytes** (`bbee9496898da3dd62d8fbb692b415ee911d88c8feeb978572afc02cbd85e7df`) into Exports. All 1,976 JPEGs are independently byte-identical; title/path/metadata differences explain every changed archive byte. AirCard imported that exact Dune file. Its authorized one-item Flash again failed the pairing/tunnel prerequisite, with no system-playback pass. Source SAR is unspecified; the square-pixel assumption is reported, not claimed as known author intent.
- Installed scene-enabled `ce6c5f4c` explicitly imported all 142 privately owned shader/material files, retaining old app resources; Your Name then displayed genuine native Metal output instead of the missing-shader error. Its subsequent **8-second / 60-requested-FPS / native-size / JPEG-quality-1** live capture failed the real timing-drift guard. No scene archive or system-playback pass is claimed; FPS/quality were not lowered. Offline fixed-step scene rendering is not implemented by the video-only PC worker.
- On-device AVFoundation remains unresolved. Current source/build/device distinctions are maintained in [EXPORT.md](EXPORT.md), [STATUS.md](STATUS.md) and [QA.md](QA.md).
