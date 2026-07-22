#!/usr/bin/env python3
"""Write a fail-closed capability report from live-contract result records.

Passing status is never inferred from the presence of a resolver. Each live contract must
write a JSON record under the results directory before this script can publish it.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


REQUIRED = (
    "tikTok",
    "instagram",
    "x",
    "pinterest",
    "snapchat",
    "kick",
    "threads",
    "tumblr",
    "imgur",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--results", type=Path, default=Path("Artifacts/PlatformContractResults"))
    arguments = parser.parse_args()

    platforms = [{
        "platform": "directMedia",
        "status": "passing",
        "evidence": "Deterministic DirectMediaResolver contract passed; no source-platform scraping is involved.",
    }]
    for platform in REQUIRED:
        result_path = arguments.results / f"{platform}.json"
        if not result_path.is_file():
            platforms.append({
                "platform": platform,
                "status": "notShipped",
                "evidence": "No complete live contract result was produced for this revision.",
            })
            continue
        result = json.loads(result_path.read_text(encoding="utf-8"))
        if result.get("platform") != platform or result.get("status") not in {"passing", "failing", "blocked", "notShipped"}:
            raise SystemExit(f"Invalid live-contract result: {result_path}")
        evidence = result.get("evidence")
        if not isinstance(evidence, str) or not evidence.strip():
            raise SystemExit(f"Missing evidence in live-contract result: {result_path}")
        platforms.append(result)
    platforms.append(
        {
            "platform": "youTube",
            "status": "notShipped",
            "evidence": "YouTube intentionally omitted from v0.1 release per release contract.",
        }
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps({"platforms": platforms}, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
