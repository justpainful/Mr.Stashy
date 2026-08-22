#!/usr/bin/env bash
# Final release gate. It fails closed when an artifact is absent or a placeholder survived.
set -euo pipefail

# shellcheck source=scripts/source_search.sh
source "$(dirname "${BASH_SOURCE[0]}")/source_search.sh"

ipa="${IPA_PATH:-Artifacts/MrStashy-unsigned.ipa}"
screenshots_dir="${SCREENSHOTS_DIR:-Artifacts/Screenshots}"

fail() {
  echo "RELEASE GUARD: $*" >&2
  exit 1
}

bash scripts/verify_assets.sh
python3 scripts/verify_localization.py

if [[ "${RELEASE_GUARD_SKIP_TESTS:-}" != "1" ]]; then
  bash scripts/test.sh
  bash scripts/ui_test.sh
fi

if [[ ! -s "$ipa" ]]; then
  fail "Unsigned IPA is missing: $ipa"
fi
if ! unzip -tqq "$ipa" >/dev/null; then
  fail "Unsigned IPA is not a valid ZIP archive: $ipa"
fi

required_screenshots=(
  onboarding.png catch-empty.png catch-preview.png queue.png library.png archive-detail.png
  settings.png sources.png ar-catch-preview.png ar-library.png ar-settings.png
)
for name in "${required_screenshots[@]}"; do
  [[ -s "$screenshots_dir/$name" ]] || fail "Missing screenshot: $screenshots_dir/$name"
done

if search_swift '(fatalError\(|preconditionFailure\(|\bTODO\b|\bFIXME\b|\bstub\b|not implemented|deliberate mock|mock response)' MrStashy Shared ShareExtension; then
  fail "Found unresolved placeholder or crash marker in production Swift code"
fi

echo "Release guard passed."
