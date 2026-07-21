#!/usr/bin/env python3
"""Write the conservative capability report for the currently registered resolvers.

The report is deliberately fail-closed: a platform is never upgraded to ``passing`` by
configuration. A resolver's live contract must change this source and pass independently
before a release guard will admit it.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


UNSHIPPED = (
    "tikTok",
    "instagram",
    "x",
    "pinterest",
    "snapchat",
    "kick",
    "threads",
    "tumblr",
    "imgur",
    "youTube",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    platforms = [
        {
            "platform": platform,
            "status": "notShipped",
            "evidence": "No verified resolver is registered in this build.",
        }
        for platform in UNSHIPPED
    ]
    platforms.append(
        {
            "platform": "directMedia",
            "status": "passing",
            "evidence": "DirectMediaResolver deterministic contract passed in PlatformContractTests.",
        }
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps({"platforms": platforms}, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
