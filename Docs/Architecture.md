# Architecture

```
paste link ──▶ LinkParser ──▶ ExtractorRegistry ──▶ Post (items, variants best-first)
                                   │
                                   ├── YouTubeExtractor   InnerTube (iOS client) → muxed ladder
                                   ├── TikTokExtractor    page state → player API → embed
                                   ├── InstagramExtractor GraphQL → embed → OG
                                   ├── …one per source
                                   └── WebExtractor       direct files, OG, <video>, JSON-LD

Save ──▶ SaveEngine ──▶ per item: choose variant by QualityPreference
                         ├── .file   Downloader (ranged, resumable)
                         ├── .muxed  Downloader ×2 → MediaAssembler.mux (AVMutableComposition, passthrough)
                         └── .hls    MediaAssembler.downloadStream → fMP4 concat | TSRemuxer → MP4
                       ──▶ FileVerifier (magic bytes, SHA-256) ──▶ ArchiveStore.commit
                       ──▶ covers, manifest.json, SQLite/FTS index ──▶ Photos (optional)
```

## Archive format

`Application Support/Stashy/Archives/<uuid>/`

- `manifest.json` — `ArchiveManifest`: source, author, text, ordered `files[]` with size,
  SHA-256, dimensions, codec, label; `notes[]` shown before saving; `missing[]` for items that
  could not be fetched.
- `01-video.mp4`, `02-photo.jpg`, … — the files, named by order and kind, extension from the
  real bytes.
- `cover-N.jpg` — a still for each video.

A `.stash` export is this folder zipped (stored, not compressed). Import verifies every
SHA-256 before the folder is accepted.

## Why the extractors look the way they do

Every platform answers a signed-out reader differently, and changes shape often. Each
extractor therefore:

1. tries the richest public surface first and falls back to simpler ones;
2. walks loosely-typed JSON (`JSONValue`) and takes what is there rather than failing on one
   renamed field;
3. returns variants best-first, with honest `notes` when the source only served a preview;
4. maps failures to one of `StashyError`'s cases, each of which has a sentence saying what
   happened and one saying what to do.

## Concurrency

`AppModel` is `@MainActor @Observable`. `ArchiveStore` and `SaveEngine` are actors. Network
and file work never touches the main thread; progress arrives through a `@Sendable` callback
that hops to the main actor.
