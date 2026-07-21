#!/usr/bin/env bash
# Optional signed sideload package. Signing material is installed by CI into an
# ephemeral keychain/profile directory; this script never reads a repository secret.
set -euo pipefail

scheme="${1:-MrStashy}"
team_id="${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for a signed IPA}"
archive_path="${SIGNED_ARCHIVE_PATH:-Artifacts/Build/MrStashy-signed.xcarchive}"
export_path="${SIGNED_EXPORT_PATH:-Artifacts/SignedExport}"
ipa_path="${SIGNED_IPA_PATH:-Artifacts/MrStashy-signed.ipa}"
export_options="${SIGNED_EXPORT_OPTIONS:-.github/export-options-sideload.plist}"

[[ -f "$export_options" ]] || { echo "Missing export options: $export_options" >&2; exit 1; }
mkdir -p "$(dirname "$archive_path")" "$(dirname "$ipa_path")"
rm -rf "$archive_path" "$export_path" "$ipa_path"

xcodebuild -project MrStashy.xcodeproj -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" archive \
  DEVELOPMENT_TEAM="$team_id" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates

xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" -allowProvisioningUpdates

exported_ipa="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
[[ -n "$exported_ipa" ]] || { echo "Signed export produced no IPA." >&2; exit 1; }
cp "$exported_ipa" "$ipa_path"
unzip -tqq "$ipa_path" >/dev/null
echo "Created signed IPA: $ipa_path"
