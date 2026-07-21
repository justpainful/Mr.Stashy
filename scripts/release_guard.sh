#!/usr/bin/env bash
# Final local release gate. It fails closed when evidence or artifacts are absent.
set -euo pipefail

report="${PLATFORM_SUPPORT_REPORT:-Artifacts/PlatformSupportReport.json}"
ipa="${IPA_PATH:-Artifacts/MrStashy-unsigned.ipa}"
screenshots_dir="${SCREENSHOTS_DIR:-Artifacts/Screenshots}"

fail() {
  echo "RELEASE GUARD: $*" >&2
  exit 1
}

bash scripts/verify_assets.sh

if [[ "${RELEASE_GUARD_SKIP_LIVE_CONTRACTS:-}" != "1" ]]; then
  if [[ ! -f "$report" ]]; then
    fail "Missing live platform support report: $report"
  fi
  python3 scripts/validate_support_report.py "$report" --release --markdown Artifacts/PlatformSupport.md
fi

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
  onboarding.png catch-empty.png results-mixed-media.png queue.png library-posts.png
  library-media.png living-post.png text-card-composer.png settings.png discord-disabled.png
  ar-catch.png ar-library.png dark-catch.png dark-library.png
)
for name in "${required_screenshots[@]}"; do
  [[ -s "$screenshots_dir/$name" ]] || fail "Missing screenshot: $screenshots_dir/$name"
done

# Release code must not carry explicit incomplete or fake execution paths. Test fixtures
# are intentionally excluded because their names may describe mocked network responses.
if rg -n --glob '*.swift' -i \
  '(fatalError\(|preconditionFailure\(|\bTODO\b|\bFIXME\b|\bstub\b|not implemented|deliberate mock|mock response)' \
  MrStashy Shared ShareExtension; then
  fail "Found unresolved placeholder or crash marker in production Swift code"
fi

# The capability registry must stay generated from verified contracts and cannot present
# YouTube (or any failing platform) as shipped.
registry='MrStashy/Core/Models/PlatformCapability.generated.swift'
[[ -f "$registry" ]] || fail "Missing generated platform capability registry"
grep -q 'Generated from Artifacts/PlatformSupportReport.json' "$registry" || fail "Capability registry is not generated from support evidence"
if grep -Eq '\.youTube, status: \.passing' "$registry"; then
  python3 scripts/validate_support_report.py "$report" --release --require-passing youTube >/dev/null
fi

for audit in Artifacts/CrashAudit.md Artifacts/MemoryAudit.md Artifacts/PerformanceAudit.md; do
  [[ -s "$audit" ]] || fail "Missing required quality audit: $audit"
done
if rg -n -i '(^|[^a-z])(crash detected|critical crash|leak detected|unresolved leak|critical performance)' Artifacts/CrashAudit.md Artifacts/MemoryAudit.md Artifacts/PerformanceAudit.md; then
  fail "Quality audit contains a release-blocking finding"
fi

echo "Release guard passed."
