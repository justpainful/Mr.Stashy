# Sideloading the unsigned IPA

Stashy releases include `MrStashy-unsigned.ipa`. It contains the built `.app` inside `Payload/` and is intentionally not signed by this repository. A device owner must re-sign it with their own Apple credentials and a compatible sideloading tool.

## Build locally

```bash
make bootstrap
make ipa
```

The IPA is written to `Artifacts/MrStashy-unsigned.ipa`; `Artifacts/MrStashy-dSYM.zip` is kept for symbolicated crash diagnosis. `scripts/package_ipa.sh` checks the IPA ZIP layout, bundle identifier (`com.tryvaultline.mrstashy`), version, build, and archive dSYMs before succeeding.

## Install

1. Download the unsigned IPA from a successful release workflow or build it locally.
2. Open it in a sideloading/re-signing tool that supports your platform and signing method.
3. Sign using an Apple ID/team and provisioning profile you control.
4. Install the resulting signed app to the device and trust the signing identity if the tool requires it.

The app uses an App Group for its share extension. The signer must provision the app and extension with compatible identifiers and the `group.com.tryvaultline.mrstashy` capability. Free/provisioning-limited signing may expire; that is a limitation of the signer, not a Stashy cloud service.

## Optional GitHub signing secrets

Unsigned packaging must always work. When all four optional GitHub secrets below are available, `release-ipa.yml` installs them in an ephemeral runner keychain and additionally uploads `MrStashy-signed.ipa`:

- `IOS_SIGNING_P12_BASE64`
- `IOS_SIGNING_P12_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `APPLE_TEAM_ID`

`IOS_KEYCHAIN_PASSWORD` is optional but recommended to set to a unique random value. Never add the source certificate, decoded profile, passwords, or token output to the repository or workflow logs.
