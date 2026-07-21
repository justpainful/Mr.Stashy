# Storage format

## On-device layout

At runtime, Stashy stores data in its Application Support container:

```text
Stashy/
  Database/library.sqlite
  Posts/<archive UUID>/
    manifest.json
    summary.json
    media/<order>-<media UUID>.<extension>
```

`manifest.json` is an `ArchiveManifest` encoded as sorted-key ISO-8601 JSON. It includes schema version, archive ID, source and canonical URLs, author snapshot, post text, optional quoted post, resolver version, save timestamp, and `orderedMedia`. Each media record stores the original variant URL, local filename, type, order index, variant metadata, and an optional SHA-256 checksum.

`summary.json` is an `ArchivedPostSummary` used for quick library presentation and recovery. `library.sqlite` is a metadata/search index (including FTS) rather than the only copy of a post. An interrupted or unavailable index therefore must not make an existing archive unreadable.

## `.stash` interchange package

A `.stash` export contains a safe archive directory with `manifest.json`, `summary.json`, and local media. Imports reject unsafe filenames, unknown future schema versions, duplicate archive IDs, missing media, integrity-check failures, and checksum mismatches. Import/export must never dereference a source URL merely to open already archived content.

## Durability and privacy

Saving uses a temporary folder followed by a move into the final archive folder. Media is validated after download before the manifest points at it. Data remains local unless the user uses an explicit system share/export or Photos action.
