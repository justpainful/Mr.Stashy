#!/usr/bin/env bash
# A portable case-insensitive source search shared by the lint and the release guard.
#
# Both previously called `rg` directly and swallowed its absence, so on a runner without
# ripgrep every policy check reported success without examining a single line. These helpers
# prefer ripgrep when it is installed and fall back to POSIX grep, which is always present.
# Exit status matches grep and rg: 0 when something matched, non-zero when nothing did.

# search_swift <extended-regex> <path>...
search_swift() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -n --glob '*.swift' -i "$pattern" "$@"
  else
    grep -rniE --include='*.swift' "$pattern" "$@"
  fi
}

# search_files <extended-regex> <path>...
search_files() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -n -i "$pattern" "$@"
  else
    grep -rniE "$pattern" "$@"
  fi
}
