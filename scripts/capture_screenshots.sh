#!/usr/bin/env bash
# Screenshot UI tests write named PNGs to Artifacts/Screenshots. This script is the
# release contract so a partial visual run cannot be accidentally published.
set -euo pipefail

scheme="${1:-MrStashy}"
destination="${2:-}"
screenshots_dir="${SCREENSHOTS_DIR:-Artifacts/Screenshots}"
result_bundle="${RESULT_BUNDLE:-Artifacts/Screenshots.xcresult}"
log_path="${XCODEBUILD_LOG:-Artifacts/Logs/screenshots.log}"

if [[ -z "$destination" ]]; then
  udid="$(bash scripts/boot_simulator.sh)"
  destination="platform=iOS Simulator,id=$udid"
fi

required=(
  onboarding.png
  catch-empty.png
  results-mixed-media.png
  queue.png
  library-posts.png
  library-media.png
  living-post.png
  text-card-composer.png
  settings.png
  discord-disabled.png
  ar-catch.png
  ar-library.png
  dark-catch.png
  dark-library.png
)

rm -rf "$screenshots_dir" "$result_bundle"
mkdir -p "$screenshots_dir" "$(dirname "$result_bundle")" "$(dirname "$log_path")"
screenshots_dir="$(cd "$screenshots_dir" && pwd)"
set -o pipefail
SCREENSHOTS_DIR="$screenshots_dir" \
  xcodebuild -project MrStashy.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination "$destination" -only-testing:MrStashyUITests/ScreenshotFlows \
  -resultBundlePath "$result_bundle" test 2>&1 | tee "$log_path"

missing=0
for name in "${required[@]}"; do
  if [[ ! -s "$screenshots_dir/$name" ]]; then
    echo "Missing required screenshot: $screenshots_dir/$name" >&2
    missing=1
  fi
done
(( missing == 0 ))
