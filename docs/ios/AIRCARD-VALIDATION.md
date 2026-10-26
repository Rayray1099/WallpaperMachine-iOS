# AirCard compatibility validation build

This is a separately authorized installer diagnostic, not a WallpaperMachine
release. It builds [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) at the fixed
MIT-licensed source revision `40640c4d827aeab8d798285b57d24fcf6be070d0` with guarded,
small compatibility changes. No upstream source or binary is vendored into this
repository. The generated IPA includes upstream's license and a build-provenance
record. It is unsigned; CI never receives pairing records or signing credentials.

## What the patch tests

The upstream folder-injection ZIP walker rejects every dot-prefixed member,
including the legitimate PosterKit file
`versions/1/contents/.com.apple.posterkit.provider.contents.configurableOptions.plist`.
The exported `.tendies` ZIP contains that member, but the folder-injection payload
does not. The validation patch preserves that exact regular-file metadata path
while keeping unrelated hidden files/directories and Finder junk excluded. Tests
inspect the actual generated injection ZIP, not just the exporter archive.

AirCard also replaces `userInfo.wallpaperRepresentingIdentifier` with an integer
when randomizing the descriptor identifier. The patch writes the decimal string,
matching the exporter and the inspected modern reference. Asset identifiers,
bundle/plane names and their filename references remain unchanged: descriptor and
asset identifiers have different roles. The scalar mismatch is a measurable
format departure, not proof of a private-consumer crash.

Finally, this diagnostic build does **not** automatically invoke NeoSpring after
injection. The manual respring action remains available. This lets a controller
capture terminal installation results before intentional graphics/allocation
pressure disrupts the runner. It does not remove the installer's existing reload
preference writes or authorize a separate reset, cleanup or security change.

None of these changes makes the all-frame contents-keyframe animation a streamed
movie, establishes an Apple FPS/frame-count limit, or proves the cause of a
previous black preview. See [the export boundary](EXPORT.md) and
[crash-report interpretation](PC-CONVERTER.md#distinguish-startup-watchdogs-from-memory-limit-events).

## Build and verification boundary

`.github/workflows/ios-aircard-validation.yml` runs only by explicit dispatch or
matching tooling changes on `ios/validate-fixed-step-20261026`. It does not run on
`ios/main`, publish a release, sign an IPA or contact a device.

1. Check out the exact upstream source and reject unexpected source revisions or
   pre-existing edits before applying the patch.
2. Run patch guard tests and a Foundation fixture exercising the actual patched
   identifier-rewrite method, plus independent IPA-verifier tests.
3. Run the actual Rust folder-payload regressions on macOS.
4. Rebuild the ARM64 iPhoneOS FFI from patched source; do not reuse the upstream
   precompiled framework. Compile the real unsigned app against the rebuilt FFI.
   Use `STRIP_STYLE=non-global` and check both defined global symbols and dyld
   exports for `ALGetGrappaToken`, which the pinned Rust source resolves by name.
   This preserves the existing dynamic callback; it is not a new pairing method.
5. Package and verify the IPA's CRCs, provenance, bundle identity and actual
   ARM64/iPhoneOS Mach-O executable. Upload scoped build/test evidence separately.

The resulting artifact is `AirCard-WM27-Validation.ipa`, with bundle identifier
`com.mak5er.aircard`. An independent local check is:

```sh
python scripts/ios/package_aircard_validation.py --ipa /absolute/path/AirCard-WM27-Validation.ipa --report /absolute/path/validation.json
```

A successful build/payload test is **not** an installed-app or system-wallpaper
pass. Installation through LCSign requires separate device handback; preserve the
existing app data and never uninstall merely to force an update. After verifying
the installed build identity, a separately selected diagnostic still needs a
complete installation result, positively identified system picture, animation,
loop, orientation and lock/unlock checks. Never infer these from an import,
thumbnail, partial progress log or respring.
