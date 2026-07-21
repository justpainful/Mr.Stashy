#!/usr/bin/env bash
set -euo pipefail

scheme="${1:-MrStashy}"
destination="${2:-}"
result_bundle="${RESULT_BUNDLE:-Artifacts/MrStashyUITests.xcresult}"
log_path="${XCODEBUILD_LOG:-Artifacts/Logs/ui-tests.log}"

if [[ -z "$destination" ]]; then
  udid="$(bash scripts/boot_simulator.sh)"
  destination="platform=iOS Simulator,id=$udid"
fi

mkdir -p "$(dirname "$result_bundle")" "$(dirname "$log_path")"
rm -rf "$result_bundle"
set -o pipefail
xcodebuild -project MrStashy.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination "$destination" -only-testing:MrStashyUITests \
  -resultBundlePath "$result_bundle" test 2>&1 | tee "$log_path"
