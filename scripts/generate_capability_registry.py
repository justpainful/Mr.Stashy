#!/usr/bin/env python3
"""Generate the app's capability registry from a validated support report."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


PLATFORM_CASES = {
    "tikTok": "tikTok",
    "instagram": "instagram",
    "x": "x",
    "pinterest": "pinterest",
    "snapchat": "snapchat",
    "kick": "kick",
    "threads": "threads",
    "tumblr": "tumblr",
    "imgur": "imgur",
    "youTube": "youTube",
    "directMedia": "directMedia",
}
ORDER = ("directMedia", "tikTok", "instagram", "x", "pinterest", "snapchat", "kick", "threads", "tumblr", "imgur", "youTube")


def swift_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()

    data = json.loads(arguments.report.read_text(encoding="utf-8"))
    entries = data["platforms"] if isinstance(data, dict) else data
    report = {entry["platform"]: entry for entry in entries}
    lines = [
        "import Foundation",
        "",
        "// Generated from Artifacts/PlatformSupportReport.json by scripts/generate_capability_registry.py.",
        "// This file records only what a live contract run observed. It never widens what a shipped",
        "// adapter claims: PlatformCapabilityRegistry uses it to narrow the in-code baseline, so a",
        "// missing or failing contract can demote a source but can never promote one.",
        "enum PlatformContractEvidence {",
        "    static let all: [PlatformCapability] = [",
    ]
    for platform in ORDER:
        entry = report[platform]
        lines.append(
            f'        .init(platform: .{PLATFORM_CASES[platform]}, status: .{entry["status"]}, evidence: "{swift_string(entry["evidence"])}"),'
        )
    lines.extend(
        [
            '        .init(platform: .discord, status: .blocked, evidence: "Bot-only, permission-scoped integration is not configured")',
            "    ]",
            "}",
            "",
        ]
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text("\n".join(lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
