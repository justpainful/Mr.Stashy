#!/usr/bin/env python3
"""Fail when a localization key used in code is missing, or when the languages disagree.

A missing key renders as its own identifier in the interface, which reads as a broken screen.
This runs in CI so that can never reach a build.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIRECTORIES = ("MrStashy", "Shared", "ShareExtension")
LANGUAGES = ("en", "ar")

KEY_PATTERN = re.compile(r'^\s*"([^"]+)"\s*=\s*"(?:[^"\\]|\\.)*"\s*;', re.MULTILINE)
# A literal key contains no backslash; anything with one is an interpolated family.
LITERAL_USE = re.compile(r'L10n\.(?:value|format)\(\s*"([^"\\]+)"')
# Keys assembled from an enum's raw value, e.g. "resolver.error.\(self)".
INTERPOLATED_USE = re.compile(r'L10n\.(?:value|format)\(\s*"([^"\\]*)\\\(')

# Families whose members are enumerated in Swift rather than written out at the call site.
GENERATED_FAMILIES = {
    "platform.": [
        "tikTok", "youTube", "instagram", "threads", "x", "reddit", "bluesky", "pinterest",
        "snapchat", "kick", "tumblr", "imgur", "discord", "web",
    ],
    "source.": [
        "tikTok", "youTube", "instagram", "threads", "x", "reddit", "bluesky", "pinterest",
        "snapchat", "kick", "tumblr", "imgur", "discord", "web",
    ],
    "media.": ["photo", "video", "gif", "audio"],
    "quality.": ["best", "upTo1080p", "dataSaver"],
    "stage.": ["queued", "preparing", "downloading", "assembling", "verifying", "savingToPhotos", "done", "failed", "cancelled"],
    "error.": [
        key + suffix
        for key in [
            "invalidLink", "unsupportedLink", "notFound", "loginRequired", "privateContent", "rateLimited",
            "blocked", "noMedia", "sourceChanged", "network", "expired", "assemblyFailed", "verificationFailed",
            "storage", "cancelled",
        ]
        for suffix in ["", ".fix"]
    ],
    "credential.": [
        key + suffix
        for key in ["discordBotToken", "xBearerToken", "imgurClientID", "tumblrAPIKey"]
        for suffix in ["", ".help"]
    ],
    "settings.appearance.": ["system", "light", "dark"],
    "settings.language.": ["system", "english", "arabic"],
}

# Counted strings resolve through `L10n.plural`, which appends the CLDR category. English
# needs `one` and `other`; Arabic additionally has zero, two, few and many, which it may use.
PLURAL_USE = re.compile(r'L10n\.plural\(\s*"([^"]+)"')
PLURAL_REQUIRED = {"en": ["one", "other"], "ar": ["one", "few", "many", "other"]}


def keys_in(language: str) -> set[str]:
    path = ROOT / "Resources" / f"{language}.lproj" / "Localizable.strings"
    return set(KEY_PATTERN.findall(path.read_text(encoding="utf-8")))


def swift_sources() -> list[Path]:
    files: list[Path] = []
    for directory in SOURCE_DIRECTORIES:
        files.extend(sorted((ROOT / directory).rglob("*.swift")))
    return files


def used_keys() -> set[str]:
    used: set[str] = set()
    for path in swift_sources():
        text = path.read_text(encoding="utf-8")
        used.update(LITERAL_USE.findall(text))
        for prefix in INTERPOLATED_USE.findall(text):
            for suffix in GENERATED_FAMILIES.get(prefix, []):
                used.add(prefix + suffix)
    return used


def main() -> int:
    problems: list[str] = []
    per_language = {language: keys_in(language) for language in LANGUAGES}

    base = per_language[LANGUAGES[0]]
    plural_suffixes = (".zero", ".one", ".two", ".few", ".many", ".other")
    for language in LANGUAGES[1:]:
        missing = sorted(key for key in base - per_language[language] if not key.endswith(plural_suffixes))
        extra = sorted(key for key in per_language[language] - base if not key.endswith(plural_suffixes))
        for key in missing:
            problems.append(f"{language}: missing translation for {key!r}")
        for key in extra:
            problems.append(f"{language}: has {key!r} which {LANGUAGES[0]} does not")

    for key in sorted(used_keys() - base):
        problems.append(f"code uses {key!r} but no localization defines it")

    plural_keys: set[str] = set()
    for path in swift_sources():
        plural_keys.update(PLURAL_USE.findall(path.read_text(encoding="utf-8")))
    for language in LANGUAGES:
        for key in sorted(plural_keys):
            for category in PLURAL_REQUIRED[language]:
                if f"{key}.{category}" not in per_language[language]:
                    problems.append(f"{language}: plural form {key + '.' + category!r} is not defined")

    for family, suffixes in GENERATED_FAMILIES.items():
        for suffix in suffixes:
            key = family + suffix
            if key not in base:
                problems.append(f"generated family key {key!r} is not defined")

    if problems:
        print("Localization check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"Localization check passed: {len(base)} keys across {', '.join(LANGUAGES)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
