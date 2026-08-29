<div align="center">

**Catch it. Keep it.** Stashy is an iPhone app that takes a public post link and stores the
post on the phone: its text, author, every picture at full size, and the video at the highest
quality the source actually serves. No account, no server, no analytics. Arabic and English.

## What each source gives

| Source | What is saved | How |
|---|---|---|
| YouTube | Video with sound up to 4K (H.264 to 1080p everywhere; 1440p/4K as AV1 on iPhone 15 Pro or newer), plus the cover | The player response YouTube serves its own iOS app lists direct stream addresses; video and audio streams are muxed on the device |
| TikTok | Video without watermark at the highest bitrate listed (up to 1080p), photo posts at full size | Post page state → embed player item endpoint → embed page, in that order |
| Instagram | Public posts, reels, carousels: pictures at full size and the video file | Web GraphQL post query → embed page → link-preview metadata |
| Threads | Public posts: pictures and video | Data inlined in the post/embed page |
| X | Photos at original size, video at the highest MP4 rendition | The embedded-tweet endpoint; a personal API bearer token also reaches age-gated posts |
| Reddit | Images, galleries, GIFs, v.redd.it video **with sound** | `.json` listing + DASH manifest; video and audio tracks are muxed on the device |
| Bluesky | The **original uploaded file** (video or image) | The post record names the blob; it is fetched from the author's own PDS, with the CDN rendition as fallback |
| Pinterest | Original image, every MP4 rendition of a video pin, idea-pin pages | Widget endpoint, then the pin page |
| Snapchat | Spotlight videos and public stories as MP4 | The page's Next.js payload |
| Kick | Clips and past broadcasts as one MP4 | HLS segments are downloaded and the MPEG-TS is rewritten into MP4 on the device, without re-encoding |
| Tumblr | Every picture block, Tumblr-hosted video and audio | The post page's inlined NPF blocks; optional personal API key |
| Imgur | Images, albums, videos at original size | Imgur's post endpoint |
| Discord | Attachments of a message a bot you own can read | Bot token only; user tokens are refused |
| Any page / file | Direct media links; a page's published video, pictures, metadata | Open Graph, `<video>`, JSON-LD |

Every file is verified after download (real media bytes, not an error page), hashed with
SHA-256, and recorded in a `manifest.json` next to it. The interface shows a "spec line" for
each file — resolution · codec · size — so what was saved is never a guess.

## How it is built

- `MrStashy/Core/Extract` — one extractor per source, all reading only what the source
  publishes to a signed-out reader (or to a developer key the person added themselves).
- `MrStashy/Core/Download` — ranged downloads, HLS stitching, an MPEG-TS → MP4 remuxer,
  AVFoundation muxing of separate video/audio streams, file verification.
- `MrStashy/Core/Storage` — archive folders, a SQLite/FTS index, `.stash` export/import,
  Keychain for keys.
- `MrStashy/UI` — SwiftUI: Catch, Library, Queue, Settings. Design decisions are in
  `Docs/DESIGN.md`.

Requirements: Xcode 26.5, Tuist 4.64.1 (pinned), iOS 26. Builds and tests run on GitHub
Actions (`ci.yml`); `sideload-ipa.yml` produces an unsigned IPA for re-signing.

```bash
make bootstrap
make test
make ui-test
make ipa
```

`scripts/verify_localization.py` fails the build when a key used in code is missing in either
language, including the Arabic plural forms.

## Boundaries

Stashy signs in to nothing, replays no stored session, bypasses no paywall or DRM, and never
removes a burned-in watermark. A source that needs a login says so. Keys a person adds live in
the Keychain and never leave the phone. See `Docs/Privacy.md`.

## Licence

Proprietary; see `LICENSE`.
