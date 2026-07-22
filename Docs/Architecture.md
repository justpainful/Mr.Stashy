# Architecture

## Targets

`Project.swift` defines the main `MrStashy` application, `StashyShareExtension`, `MrStashyTests`, `MrStashyUITests`, and `PlatformContractTests`. Tuist is the committed source of project configuration. The app and share extension use `group.com.tryvaultline.mrstashy` to pass pending URLs without performing long work in the extension.

## Runtime boundaries

| Area | Responsibility | Boundary |
| --- | --- | --- |
| `App/` | App lifecycle, typed `AppState`, tab selection and deep links | Owns composition, not resolver/network work |
| `Features/` | Catch, result, queue, library, living-post, onboarding, settings and text-card UI | SwiftUI screens and focused state |
| `Core/Networking` | URL normalization, resolver selection, download byte progress | Talks only to a user-requested source/media host |
| `Core/Storage` | File archive, `.stash` package, SQLite index, integrity checks | Keeps durable data on device |
| `Core/Security` | Keychain access and sensitive-log redaction | Never persists secrets in logs |
| `Shared/` | App/extension payload format | No independent networking |

The root uses one `TabView` with a separate `NavigationStack` per primary tab. Ownership is narrow: environment injection is used for app-scoped state and storage work is actor-isolated. Views must not perform network resolution directly from `body`.

## Local-first data path

```text
Paste/share URL → canonicalize → resolver → selectable ResolvedPost
                                       ↓
                      download + signature validation + SHA-256
                                       ↓
              immutable post folder (manifest + ordered media + summary)
                                       ↓
                          SQLite index (recoverable/search only)
```

The post folder is durable. If the database cannot open or must be rebuilt, library summaries are reconstructed from `summary.json` files. See `StorageFormat.md`.

Pending queue entries persist only the source URL, selected source-order indexes, save mode, and request identifier. On relaunch the app re-resolves the public source before downloading, so expiring media URLs and request headers are never written to the queue file. A cancellation-aware permit pool enforces the user's parallel-download setting.

Downloaded media is verified before it enters the archive. Files with the same SHA-256 digest reuse an existing on-volume file through a hard link when the filesystem supports it; a failed link safely falls back to the independently verified file.

## Visual reserve

The current product direction intentionally excludes character and illustration assets from runtime UI. The design system uses semantic color, typography, spacing, native controls, and functional SF Symbols without reserving empty artwork containers.
