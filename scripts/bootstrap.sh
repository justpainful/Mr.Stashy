#!/usr/bin/env bash
set -euo pipefail

if ! command -v tuist >/dev/null 2>&1; then
  echo "Tuist $(cat .tuist-version) is required. Install it from https://docs.tuist.dev/" >&2
  exit 1
fi

tuist generate --no-open
