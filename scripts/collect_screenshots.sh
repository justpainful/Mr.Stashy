#!/usr/bin/env bash
# Collect named screenshots produced by ScreenshotFlows without rerunning the UI suite.
set -euo pipefail

screenshots_dir="${1:-Artifacts/Screenshots}"
result_bundle="${2:-Artifacts/MrStashyUITests.xcresult}"
required=(
  onboarding.png catch-empty.png results-mixed-media.png queue.png library-posts.png
  library-media.png living-post.png text-card-composer.png settings.png discord-disabled.png
  ar-catch.png ar-library.png dark-catch.png dark-library.png
)

mkdir -p "$screenshots_dir"
screenshots_dir="$(cd "$screenshots_dir" && pwd -P)"

# The app writes named files into its test container when possible.
for name in "${required[@]}"; do
  found="$(find ~/Library/Developer/CoreSimulator/Devices /tmp /var/tmp -type f -name "$name" -print -quit 2>/dev/null || true)"
  [[ -z "$found" ]] || cp -f "$found" "$screenshots_dir/$name"
done

# Xcode may instead retain screenshots as xcresult attachments. Export them with the
# supported tool, preserving attachment names, then copy only the release contract set.
if [[ -d "$result_bundle" ]]; then
  attachments="$(mktemp -d)"
  if xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$attachments" >/dev/null 2>&1; then
    for name in "${required[@]}"; do
      found="$(find "$attachments" -type f -name "$name" -print -quit 2>/dev/null || true)"
      [[ -z "$found" ]] || cp -f "$found" "$screenshots_dir/$name"
    done
  fi
fi

missing=0
for name in "${required[@]}"; do
  if [[ ! -s "$screenshots_dir/$name" ]]; then
    echo "Missing required screenshot: $screenshots_dir/$name" >&2
    missing=1
  fi
done
(( missing == 0 ))
