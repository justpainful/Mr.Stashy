# Privacy

Stashy is local-first by design.

- No Stashy account, proprietary backend, cloud database, advertising SDK, analytics, telemetry, remote feature flag, or tracking SDK is permitted.
- A URL is contacted only after the user explicitly pastes/shares/resolves it or starts a download. The request goes to the source platform or required media host, not a Stashy-owned relay.
- Post metadata, manifests, media, thumbnails, collections, settings, and SQLite indexes remain in the app's local container unless the user explicitly exports, shares, or saves content to Photos.
- The Share Extension passes pending URLs through the local App Group and does not perform long-running downloads.
- Logs must redact authorization headers, cookies, sessions, tokens, and private URLs before CI upload or support sharing.

Public availability is not permission to bypass DRM, encryption, paywalls, access control, or privacy controls. Stashy is for public content or content the user is explicitly authorized to archive. It does not remove watermarks; it can only select a clean original variant when one is publicly exposed.

## Deleting data

Deleting a local archive removes its managed post folder and its index record. Clearing a cache/thumbnail store must not silently erase full post archives. Exported files, Photos copies, and externally shared copies are controlled by their destination and are outside the app container.
