# Changelog

## 1.0.0 — rebuild

- Every source is read with a dedicated extractor that returns real files, best quality first:
  YouTube (InnerTube iOS client, muxed on device up to 4K), TikTok (no watermark, up to 1080p),
  Instagram, Threads, X, Reddit (video with sound), Bluesky (original uploads), Pinterest,
  Snapchat, Kick (MPEG-TS remuxed to MP4), Tumblr, Imgur, Discord (bot token), any page/file.
- On-device assembly: separate video/audio streams are muxed without re-encoding; HLS segments
  are stitched; transport streams are rewritten into MP4.
- Every downloaded file is verified by its bytes and hashed before it enters the archive.
- New interface: Catch → preview with a spec line per file → Queue → Library with viewer,
  collections, pins, `.stash` export/import → Settings with per-source capability notes.
- Arabic with real plural forms; right-to-left layout follows the in-app language.
