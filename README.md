<div align="center">

# Mr. Stashy

A local-first iOS archive for public posts and media.

</div>

## Overview

Mr. Stashy saves public content to the device with the context needed to make the archive useful later. A saved item can include post text, attribution, ordered media and source metadata.

The app has no Stashy account or hosted library. Saved content stays local unless the user exports it.

## Features

- Save from a pasted URL or Share Sheet
- Archive a full post, selected media or a text card
- Local searchable library
- Offline access after a successful save
- `.stash` import and export
- Arabic and English localization
- Native RTL support
- Per-platform capability reporting
- Optional user supplied developer keys for supported sources

## How sources are handled

Mr. Stashy reads information made available to public readers such as page metadata, documented embed endpoints and media references published by the page itself.

The app does not sign in to a user's social account or reuse personal sessions. Sources that require authentication are reported as unavailable unless a supported developer key has been provided by the user.

Media candidates are validated before they are added to an archive. Partial captures are recorded as partial instead of presenting a preview image as if the original media file had been saved.

## Platform support

Source capabilities are defined in:

```text
MrStashy/Core/Models/PlatformCapability.swift
```

The same capability model drives the Catch screen and the support status shown in Settings.

Live source checks can be run with:

```bash
LIVE_PLATFORM_CONTRACTS=1 make platform-contracts
```

Generated evidence is written to `Artifacts/PlatformSupport.md`.

## Requirements

- macOS 26
- Xcode 26.5
- iOS 26.5 Simulator runtime
- Tuist 4.64.1
- Python 3 for development validation scripts

## Build and test

```bash
make bootstrap
make build
make test
make ui-test
make screenshots
make ipa
make release-check
```

The release checks cover source policy, assets, localization, tests, screenshots, support evidence and IPA packaging.

## Sideload build

```bash
make ipa
```

This creates:

```text
Artifacts/MrStashy-unsigned.ipa
```

The IPA is unsigned and can be re-signed by the device owner with a compatible sideloading tool.

## Documentation

- [`Docs/Privacy.md`](Docs/Privacy.md)
- [`Docs/StorageFormat.md`](Docs/StorageFormat.md)
- [`Docs/ResolverArchitecture.md`](Docs/ResolverArchitecture.md)
- [`Docs/Sideloading.md`](Docs/Sideloading.md)
- [`Docs/CI.md`](Docs/CI.md)

## Privacy

Source access keys are stored in the device Keychain. They are not written to archives, logs, diagnostics or repository configuration.