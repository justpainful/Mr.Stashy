#!/usr/bin/env bash
# Builds an unsigned archive and packages its .app under Payload/, suitable for
# sideload re-signing. It intentionally never exports or stores credentials.
set -euo pipefail

scheme="${1:-MrStashy}"
archive_path="${ARCHIVE_PATH:-Artifacts/Build/MrStashy.xcarchive}"
ipa_path="${IPA_PATH:-Artifacts/MrStashy-unsigned.ipa}"
dsym_path="${DSYM_PATH:-Artifacts/MrStashy-dSYM.zip}"
metadata_path="${BUILD_METADATA_PATH:-Artifacts/BuildMetadata.json}"
expected_bundle_id="${BUNDLE_ID:-com.tryvaultline.mrstashy}"

mkdir -p "$(dirname "$archive_path")" "$(dirname "$ipa_path")" "$(dirname "$dsym_path")" "$(dirname "$metadata_path")"
ipa_path="$(cd "$(dirname "$ipa_path")" && pwd)/$(basename "$ipa_path")"
dsym_path="$(cd "$(dirname "$dsym_path")" && pwd)/$(basename "$dsym_path")"
rm -rf "$archive_path" "$ipa_path" "$dsym_path"

xcodebuild -project MrStashy.xcodeproj -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive_path" archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

app_path="$(find "$archive_path/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$app_path" ]]; then
  echo "Archive did not contain an application bundle." >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app_path" "$stage/Payload/$(basename "$app_path")"
(cd "$stage" && /usr/bin/zip -qry "$(cd "$(dirname "$ipa_path")" && pwd)/$(basename "$ipa_path")" Payload)

info_plist="$app_path/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
  echo "Unexpected bundle identifier: $bundle_id" >&2
  exit 1
fi

dsym_dir="$archive_path/dSYMs"
if [[ -d "$dsym_dir" ]]; then
  (cd "$dsym_dir" && /usr/bin/zip -qry "$(cd "$(dirname "$dsym_path")" && pwd)/$(basename "$dsym_path")" .)
else
  echo "Archive did not contain dSYMs." >&2
  exit 1
fi

python3 - "$metadata_path" "$bundle_id" "$version" "$build" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone

path, bundle_id, version, build = sys.argv[1:]
metadata = {
    "bundleIdentifier": bundle_id,
    "version": version,
    "build": build,
    "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "createdAt": datetime.now(timezone.utc).isoformat(),
}
with open(path, "w", encoding="utf-8") as output:
    json.dump(metadata, output, indent=2, sort_keys=True)
    output.write("\n")
PY

if ! unzip -Z1 "$ipa_path" | grep -Eq '^Payload/[^/]+\.app/Info\.plist$'; then
  echo "IPA does not have the required Payload/<App>.app structure." >&2
  exit 1
fi
echo "Created unsigned IPA: $ipa_path ($bundle_id $version ($build))"
