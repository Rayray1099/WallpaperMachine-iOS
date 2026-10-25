# Native iOS Steam transport (experimental compiler checkpoint)

A separate first-party GPL-3.0-only Rust static library, not yet linked to the
shipped Swift app. Source implements native CM credentials/Steam Guard handling,
an authenticated self-owned-games gate requiring Wallpaper Engine431960,
authenticated PublishedFile.GetDetails/consumer-app validation, PICS workshopdepot
resolution, Steam-issued depot key and manifest access code, and SHA1/size-verified
bounded staging. There is no anonymous login, injected key, guessed content URL,
free-license request, helper server or Community-cookie authentication shortcut.

C ABI: `wm_steam_start(JSON)` -> task ID; `wm_steam_poll` -> caller-freed JSON
status; `wm_steam_guard`, `wm_steam_cancel`, `wm_steam_free`. Secrets are neither
logged nor persisted nor returned in status. A dedicated runtime retains only the
in-memory authenticated connection until explicit logout; UI credentials/Guard
choices remain on-device. Downloads require an empty app-owned staging folder.

Pinned native transport bases: `steam-vent=0.3.1` (MIT) and `steam-cdn=1.0.0`
(Apache-2.0, compatible with GPLv3). Protocol flow was checked against
[DepotDownloader](https://github.com/SteamRE/DepotDownloader) ContentDownloader.cs
and Steam3Session.cs; no C# code was copied. No third-party source is vendored here.

The dedicated `iOS Steam Native Check` CI runs offline tests and actual ARM64 iOS
compilation. No live account/ownership/Workshop transfer has been verified yet.
This is implementation source, not a completed downloader claim. The first
resolved Cargo.lock must be collected and committed before shipping the library.
All linked dependency license texts must be added to the iOS app's notices when
integrating this target. Credentials must never enter CI, logs or chat.
