# Continuous integration and release tooling

## Runner decision

The workflows use GitHub-hosted `macos-26` and explicitly select `/Applications/Xcode_26.5.0.app/Contents/Developer`. The [GitHub runner-image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) lists macOS 26 runners and Xcode 26.5/iOS 26.5 SDK support; the exact Xcode path is checked before each job. `macos-latest` is deliberately not used because its OS/Xcode selection moves over time.

Tuist is pinned to 4.64.1 in both `.tuist-version` and `.tool-versions`; `jdx/mise-action` installs the version declared by the repository. Workflow logs print the selected Xcode and Tuist versions.

## Workflows

| Workflow | Purpose |
| --- | --- |
| `ci.yml` | Assets, format/lint, bootstrap, tests, simulator build, unsigned Release build, and a static release guard that intentionally leaves live contracts to their dedicated workflow |
| `platform-contracts.yml` | Nightly/manual public resolver contracts with redacted evidence artifacts |
| `screenshots.yml` | Manual/release-candidate visual flow capture and screenshot ZIP artifact |
| `release-ipa.yml` | `v*-sideload` tag/manual end-to-end release gate, live contracts, screenshots, unsigned IPA, dSYMs, quality reports, and the GitHub Release only after every gate passes |

PR CI runs project generation once as a prerequisite, then executes simulator build, tests, UI tests, and unsigned packaging in parallel. The final Ubuntu guard reuses the IPA and screenshot artifacts instead of rebuilding them. Workflow concurrency cancels obsolete runs after a newer commit is pushed.

The release workflow fails closed. It does not publish merely because an archive was built: all contract evidence, audits, screenshot files, alpha validation, tests, and package checks must pass.

The release flow tests the latest available Pro Max simulator and separately selects `iPhone 14 Pro Max` when the runner provides it; otherwise it uses the closest available Pro Max equivalent. The exact UDIDs are discovered by `scripts/boot_simulator.sh`, not guessed in YAML.
