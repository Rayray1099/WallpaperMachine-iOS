# Native Steam Workshop transport

Rust/C ABI boundary for native Steam Workshop access. Requests are JSON operations `login`, `download`, and `logout`; `download` carries decimal `item_id` and app-owned temporary `destination`. Poll returns JSON `{phase,received,total,message,guard_type}`. Swift receives and submits Steam Guard interaction via the task API. Credentials are not included in status/error output or persisted here.

Consumer app is Wallpaper Engine 431960. A complete downloader must enforce authenticated account ownership and the server-side PublishedFile/depot authorization, use the Steam-issued manifest request code and depot key, validate manifest paths and content hashes, and stage only inside Swift-owned temporary storage. It must never use anonymous UGC, guessed public URLs, community cookies, or injected depot keys.

Current source contains the C ABI, task/status/cancel plumbing and native unit tests for item IDs and manifest path components. Authentication and the entitlement/details/SteamPipe download pipeline intentionally fail closed and are not implemented yet. This Windows environment has no Rust compiler; macOS CI must compile/test before integration.