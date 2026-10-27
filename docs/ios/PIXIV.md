# Pixiv on iPhone and iPad

The iOS port uses the illustration models, web endpoints, response decoding and
session rules from upstream WallpaperMachine's [Pixiv feature](../features/pixiv.md).
Open **Pixiv** from the iPad sidebar or the iPhone library menu. It is a native
browse and image-import flow backed by `iOS/Sources/Pixiv/`.

## Browse and sign in

An empty search shows illustration rankings (daily, weekly, monthly or rookie).
Entering tags switches to newest/oldest tag search. Orientation, minimum image
size, age rating and AI filters follow the upstream query rules. Manga, ugoira,
masked entries and malformed rows are excluded by the service; R-18G is never
admitted. Pages and selected-work page lists have bounded in-memory caches.

Public browsing is anonymous. Sign in opens Pixiv's own HTTPS page in a private
`WKWebView`. Only a signed-in-shaped `PHPSESSID` from `pixiv.net` is read. Pixiv
checks the session before it is adopted; the password and verification codes
remain in the website. The session is stored as a device-only Keychain item,
outside the managed library and its backups. A failed save is reported and the
session then lasts only for that app process.

Mature search and rankings require a verified account, the Mature filter and an
account whose reported restrictions permit it. Signing out invalidates pending
account requests, clears browse/page caches, removes Mature from the query and
removes the Keychain item. A late login response cannot restore the signed-out
account. Existing downloaded library images are retained.

JSON requests are paced by the service (350 ms). Image requests carry Pixiv's
required Referer and do not carry the account cookie. The session may accompany
only HTTPS requests to `www.pixiv.net`; redirects cannot take it to image or
other hosts. HTTP 403, 429, expired sessions and unreadable responses have
separate failures. A denied request is not treated as a confirmed rate limit.

## Save an illustration page

Select a work, select a page, and download its original into the managed library.
Downloads run serially to bound image memory and share the library import lock.
Queued and downloading jobs can be cancelled and retried. Closing the Pixiv
sheet keeps the app-owned queue alive while the app runs. iOS can suspend or
terminate the app; this port does not promise background execution, persisted
download queues or partial-transfer restoration after relaunch. Those upstream
desktop features are not exposed here.

The original is limited to 64 MiB and its signature determines its extension.
On Apple platforms ImageIO must decode it successfully. The imported project
is a native `image` wallpaper, using the existing preview, playlist and export
paths. It preserves:

- `illustration.jpg`, `.png` or `.gif`: the original response bytes;
- `preview.jpg`: a generated preview of at most 512 pixels on its long side;
- `display.jpg`, when the original exceeds 4096 pixels on its long side: a
  bounded playback image; the original remains alongside it;
- `project.json`: title, rating, tags and the upstream-shaped `pixiv` attribution
  (work/page, author, source/original URLs, original filename and dimensions).

Image work occurs off the main actor. A staging folder is handed to the existing
transactional library importer, then removed. Success is reported only after
the library contains that work/page. Import failures remain retryable failures.
Image export reads the retained original, rather than the preview or display copy.
The `(work ID, page)` identity prevents duplicate library entries and retains
the existing UUID, favorites, collections and compatible property values on
reimport. Pixiv attribution survives save/reload and backups; old manifests
without it remain readable. Library details link back to the work and identify
its artist. The image still belongs to that artist.

## Verification boundaries

Portable Swift harnesses compile and execute the production service, query,
transport request policy, image-project, repository and store code through:

```powershell
python -B -m unittest discover -s scripts/tests -p 'test_ios_pixiv*.py'
```

On 2026-10-27 all three Python wrappers passed and executed **31 Swift behavior
cases**: 17 service/query/transport cases, six image-project/repository cases and
eight store/account/download-race cases. Production core/store code also passed
Swift 5 typechecking with warnings treated as errors. All 135 iOS Swift source
and test files passed syntax parsing; both shipped catalogs have 384 unique,
matching keys with matching format placeholders. Syntax parsing does not
typecheck Apple frameworks.

Fixtures and isolated temporary libraries are used; tests do not read account
cookies, the real Keychain or the installed collection. Windows does not run
ImageIO, WebKit, SwiftUI, UIKit or native XCTest. Apple-specific image decoding,
private-webview login and device browsing/download remain separate gates, as
does the unsigned ARM64 GitHub Actions build. Neither source integration nor
an archive test establishes system Home/Lock Screen installation or playback.

An anonymous live smoke test on 2026-10-27 compiled the production service,
transport, project packager and repository in Swift 5 mode with warnings treated
as errors. It read 50 ranking works, fetched one work's page list and a 174,693-byte
original, imported it as an image, reloaded the library and compared the stored
original byte-for-byte. Pillow fully decoded that original at 1000 × 1000,
matching the page metadata. All artwork, temporary libraries and executable
outputs were removed by the test. This verifies the live Windows/Foundation
service-to-library path, independently of the untested Apple UI and login.

The final `IOS_LOCAL_CONVERTER_INTEGRATION=1 python -B scripts/test.py` run on
Windows/Python 3.10 returned exit 1. **34 of 39 Python modules passed**, including
all 14 iOS modules (220 reported tests); the optional pinned AirCard source class
was skipped because `AIRCARD_VALIDATION_SOURCE` was absent. Five unchanged
upstream modules failed before XcodeGen/native tests could start:

| Module | Observed portability failure |
|---|---|
| `test_check_licenses.py` | POSIX/Mach-O/Homebrew path and dependency resolution assumptions |
| `test_clean.py` | POSIX path-label expectations on Windows |
| `test_notices.py` | Newline-normalization fixture expectation on Windows |
| `test_power_benchmark.py` | macOS process API assumptions and Python 3.11 `hashlib.file_digest` unavailable in Python 3.10 |
| `test_we_reference.py` | macOS `xattr`/`sips` and `time.tzset` unavailable on Windows |

This local checkpoint predates the Apple build. The iOS Build workflow now also
runs the three Pixiv wrappers on macOS, including the real ImageIO image-project
branch, before producing the device IPA. Earlier successful Actions runs do not
validate this patch. Apple build results must be recorded against their actual
source commit. Native ImageIO XCTest, authenticated Pixiv sessions, device
interaction and system-wallpaper playback remain separate verification gates.
