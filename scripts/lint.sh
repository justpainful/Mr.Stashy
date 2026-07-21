#!/usr/bin/env bash
# SwiftFormat is deliberately lint-only: CI never rewrites a contributor's files.
set -euo pipefail

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "swiftformat is required. Install it with: brew install swiftformat" >&2
  exit 1
fi

paths=()
for path in MrStashy MrStashyTests MrStashyUITests PlatformContractTests ShareExtension Shared; do
  [[ -d "$path" ]] && paths+=("$path")
done
(( ${#paths[@]} > 0 )) || { echo "No Swift source directories found." >&2; exit 1; }

swiftformat --version
swiftformat --lint --swiftversion 6 "${paths[@]}"
