#!/usr/bin/env bash
# This is deliberately a narrow source-policy lint. SwiftFormat's default rule set is a
# formatter configuration rather than a project correctness policy, and enforcing every
# newly introduced cosmetic rule made valid Swift source fail before compilation.
set -euo pipefail

paths=()
for path in MrStashy MrStashyTests MrStashyUITests PlatformContractTests ShareExtension Shared; do
  [[ -d "$path" ]] && paths+=("$path")
done
(( ${#paths[@]} > 0 )) || { echo "No Swift source directories found." >&2; exit 1; }

# Without the search tool this check silently passed on every revision, which made the policy
# it enforces meaningless. It now fails closed.
command -v rg >/dev/null 2>&1 || { echo "ripgrep (rg) is required for the source-policy lint." >&2; exit 1; }

if rg -n --glob '*.swift' -i \
  '(fatalError\(|preconditionFailure\(|\bTODO\b|\bFIXME\b|\bstub\b|not implemented|deliberate mock|mock response)' \
  "${paths[@]}"; then
  echo "Production Swift source contains an unresolved placeholder or crash marker." >&2
  exit 1
fi

echo "Source-policy lint passed for ${#paths[@]} Swift roots."
