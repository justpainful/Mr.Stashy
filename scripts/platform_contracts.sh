#!/usr/bin/env bash
# Live resolver contracts are intentionally separate from deterministic unit tests.
set -euo pipefail

scheme="${1:-MrStashy}"
destination="${2:-}"
report="${PLATFORM_SUPPORT_REPORT:-Artifacts/PlatformSupportReport.json}"
result_bundle="${RESULT_BUNDLE:-Artifacts/PlatformContractTests.xcresult}"
log_path="${XCODEBUILD_LOG:-Artifacts/Logs/platform-contracts.log}"

if [[ "${LIVE_PLATFORM_CONTRACTS:-}" != "1" ]]; then
  echo "Refusing to run live resolver contracts without LIVE_PLATFORM_CONTRACTS=1." >&2
  exit 2
fi
if [[ -z "$destination" ]]; then
  udid="$(bash scripts/boot_simulator.sh)"
  destination="platform=iOS Simulator,id=$udid"
fi

mkdir -p "$(dirname "$report")" "$(dirname "$result_bundle")" "$(dirname "$log_path")"
rm -f "$report"
rm -rf "$result_bundle"
set -o pipefail
LIVE_PLATFORM_CONTRACTS=1 PLATFORM_SUPPORT_REPORT="$report" \
  xcodebuild -project MrStashy.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination "$destination" -only-testing:PlatformContractTests \
  -resultBundlePath "$result_bundle" test 2>&1 | tee "$log_path"

python3 scripts/generate_support_report.py --output "$report"
python3 scripts/validate_support_report.py "$report" --markdown Artifacts/PlatformSupport.md
python3 scripts/generate_capability_registry.py "$report" MrStashy/Core/Models/PlatformCapability.generated.swift
