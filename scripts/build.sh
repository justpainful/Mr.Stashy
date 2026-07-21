#!/usr/bin/env bash
set -euo pipefail

scheme="${1:-MrStashy}"
destination="${2:-}"
if [[ -z "$destination" ]]; then
  udid="$(bash scripts/boot_simulator.sh)"
  destination="platform=iOS Simulator,id=$udid"
fi
xcodebuild -project MrStashy.xcodeproj -scheme "$scheme" -configuration Debug -destination "$destination" build
