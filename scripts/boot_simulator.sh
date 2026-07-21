#!/usr/bin/env bash
# Prints a booted iPhone simulator UDID. Prefer a Pro Max model for visual QA.
set -euo pipefail

preference="${1:-latest-pro-max}"
case "$preference" in
  latest-pro-max|iphone-14-or-closest) ;;
  *) echo "Usage: $0 [latest-pro-max|iphone-14-or-closest]" >&2; exit 2 ;;
esac

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to select an iOS Simulator." >&2
  exit 1
fi

device_json="$(xcrun simctl list devices available -j)"
udid="$(DEVICE_JSON="$device_json" SIMULATOR_PREFERENCE="$preference" python3 - <<'PY'
import json
import os
import re

devices = json.loads(os.environ["DEVICE_JSON"]).get("devices", {})
candidates = []
for runtime, values in devices.items():
    for device in values:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        if not name.startswith("iPhone"):
            continue
        candidates.append((runtime, name, device["udid"]))

if not candidates:
    raise SystemExit("No available iPhone Simulator runtime is installed.")

preference = os.environ["SIMULATOR_PREFERENCE"]
iphone_14 = [item for item in candidates if item[1] == "iPhone 14 Pro Max"]
if preference == "iphone-14-or-closest" and iphone_14:
    print(sorted(iphone_14, reverse=True)[0][2])
    raise SystemExit(0)

pro_max = [item for item in candidates if item[1].endswith("Pro Max")]
pool = pro_max or candidates
# Runtime identifiers sort in release order; choosing the last gives the newest available
# Pro Max. This is the closest available equivalent when iPhone 14 Pro Max is absent.
print(sorted(pool, key=lambda item: (item[0], item[1]), reverse=True)[0][2])
PY
)"

xcrun simctl bootstatus "$udid" -b >/dev/null
printf '%s\n' "$udid"
