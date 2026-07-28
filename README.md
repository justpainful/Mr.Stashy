# Stashy

**Catch it. Keep it.** Stashy is a local-first iOS archive for public posts and direct public media. It preserves a post's text, attribution, ordered media, and source metadata on the device rather than sending an archive to a Stashy service.

## What it is built to do

- Paste or share a public URL, inspect every detected item, and choose a full-post archive, media-only save, or text card.
- Keep archives local with a JSON manifest, verified media files, a SQLite metadata/search index, and `.stash` import/export.
- Provide four native tabs: Catch, Library, Queue, and Settings, plus a Share Extension that hands URLs to the app through its App Group.
- Work offline after a successful save, subject to local media codec support.
- Use English and Arabic localization, including right-to-left layout that follows the in-app language choice rather than only the device language.

The product never creates a Stashy account, backend, analytics stream, cloud library, ad profile, remote flag, or tracking record. Network access is limited to a source platform or media host after a user explicitly asks Stashy to resolve or download a link.

## How a source is read

Stashy reads only what a source publishes for public readers:

- the Open Graph, Twitter card, and JSON-LD metadata a page publishes for link previews;
- the unauthenticated endpoints a source documents for its own embeds — TikTok oEmbed, X's syndication endpoint, Pinterest's widget endpoint, Kick's clip endpoint, YouTube oEmbed;
- media elements and JSON payloads the public page itself contains.

It signs in to nothing, replays no stored session, and works around no access control. A source that genuinely requires an account is reported as needing access, not as an empty post.

Two behaviours make the result trustworthy:

- **Every candidate address is confirmed to serve media before it is offered.** A source that answers `200 text/html` for a media address is discarded rather than archived, so a "saved" post never turns out to hold an error page.
- **A partial capture says so.** When a source publishes a cover image but no file — TikTok sometimes, YouTube always — the archive records the cover and the interface states plainly that the video is not part of it.

## Support matrix

`Settings → Platform support status` shows, per source, what Stashy can capture and why. That list comes from `MrStashy/Core/Models/PlatformCapability.swift`, which sits next to the resolvers it describes, and it drives the Catch screen directly — the picker cannot advertise a source with no working adapter.

`make platform-contracts` runs the live suite against real public posts and writes `Artifacts/PlatformSupport.md`. Its evidence can **narrow** the shipped baseline (a source proven broken is demoted) but never widen it. A result recorded from a data centre is a diagnostic rather than a verdict about a phone, because several sources answer a hosted runner differently.

Sources where a person can supply their own developer key — X, Imgur, Tumblr, Pinterest, Instagram, Threads, TikTok — capture more once that key is added under `Settings → Your source access`. Keys are held in the device Keychain and never written to settings, manifests, archives, diagnostics, or logs.

## Requirements

- macOS 26 with Xcode 26.5.0 and the iOS 26.5 Simulator runtime.
- Tuist `4.64.1` (pinned in `.tuist-version` and `.tool-versions`).
- Python 3 with dependencies from `requirements-dev.txt` for asset and localization validation.
- An available iPhone Simulator; scripts prefer a current Pro Max model, then another iPhone.

GitHub Actions uses the `macos-26` hosted image and selects `/Applications/Xcode_26.5.0.app/Contents/Developer` explicitly. See `Docs/CI.md` for the runner decision.

## Build and test

```bash
make bootstrap
make build
make test
make ui-test
make screenshots
LIVE_PLATFORM_CONTRACTS=1 make platform-contracts
make ipa
make release-check
```

`make release-check` fails closed: it requires real-alpha assets, passing release-gated contracts, unit and UI results, an unsigned IPA, the full screenshot set, generated support evidence, and the three quality audits.

`scripts/verify_localization.py` fails the build when a key used in code is missing from either language, because a missing key renders as its own identifier and reads as a broken screen.

## Unsigned IPA and sideloading

`make ipa` creates `Artifacts/MrStashy-unsigned.ipa`. Two workflows produce it in CI:

- **`sideload-ipa.yml`** (`workflow_dispatch`) is the one to use for a sideload build. It keeps the gates that actually prove the build — source-policy lint, asset and localization validation, and the deterministic test suite — and skips the live third-party calls a hosted runner cannot make reliably.
- **`release-ipa.yml`** additionally runs the live contracts and publishes a tagged release. Packaging now happens *before* those calls, so one unavailable source no longer destroys the artifact from an otherwise good build.

The IPA is intentionally unsigned so a device owner can re-sign it. See `Docs/Sideloading.md` for the process and its limits.

## Discord tools

Discord functionality, when implemented, accepts only a user-supplied **Discord bot token** through the app's secure storage. It must never accept a personal user token, automate a normal user account, or place a token in source control or logs. No bot token is configured, so Discord is reported as blocked and is not offered on the Catch screen. See `Docs/DiscordBotToken.md`.

## Known limits

- YouTube publishes no downloadable file address for a signed-out reader, so a YouTube capture is title, channel, and cover image only.
- Kick publishes clips as adaptive streams rather than files; Stashy archives files, so a clip capture is its poster frame.
- Instagram and Threads answer most signed-out requests with a login page. Public posts that still publish preview metadata are captured; the rest need your own developer key.
- Adaptive-stream manifests (`.m3u8`, `.mpd`) are never archived as though they were media files.
- Character and illustration assets are intentionally excluded from runtime UI by the current product direction. Functional SF Symbols and native SwiftUI hierarchy provide the visual cues.

## Contributing and privacy

Read `CONTRIBUTING.md` before opening a pull request. The local-first data policy is in `Docs/Privacy.md`, the archive format in `Docs/StorageFormat.md`, the resolver design in `Docs/ResolverArchitecture.md`, and notices in `THIRD_PARTY_NOTICES.md`.
