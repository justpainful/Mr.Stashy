# Contributing to Stashy

## Prerequisites

Use Xcode 26.5.0, Tuist 4.64.1, and an iOS 26.5 simulator as documented in `README.md`. Run `make bootstrap` after cloning; generated Xcode projects are not the source of truth.

## Before a pull request

```bash
make assets
make lint
make build
make test
make ui-test
```

For a release-affecting resolver change, also run the live suite with only public, authorized test URLs:

```bash
LIVE_PLATFORM_CONTRACTS=1 make platform-contracts
```

Do not add cookies, bearer tokens, account exports, copyrighted bulk media, or personal Discord tokens to fixtures, logs, issue comments, screenshots, or commits. Redact source URLs when they would expose private content.

## Architecture rules

- Keep SwiftUI `body` methods rendering-only; resolve, download, hash, and decode outside them.
- Preserve complete posts and media order. A resolver that cannot verify a platform must not declare it supported.
- Do not bypass DRM, authentication, encryption, paywalls, or watermarks.
- Do not replace native Liquid Glass with material or custom blur.
- User-facing strings belong in the localization resources; provide Arabic updates with English changes.
- Treat `manifest.json` and saved media as the durable archive; the SQLite index is recoverable metadata.

## Reviews

PRs should state the commands run, simulator/device, locale and appearance coverage, and any resolver contract evidence. Include screenshot paths for visual changes. CI is deliberately release-blocking when artifacts or support evidence are missing.
