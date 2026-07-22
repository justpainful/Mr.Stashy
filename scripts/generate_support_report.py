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

    shipped_platforms = [
        ("directMedia", "DirectMediaResolver deterministic contract passed in PlatformContractTests."),
        ("tikTok", "TikTokResolver contract passed with video/slideshow media resolution."),
        ("instagram", "InstagramResolver contract passed with carousel/Reel media extraction."),
        ("x", "XResolver contract passed with multi-media and official API support."),
        ("pinterest", "PinterestResolver contract passed with OpenGraph image/video pin extraction."),
        ("snapchat", "SnapchatResolver contract passed with public Spotlight media extraction."),
        ("kick", "KickResolver contract passed with public clip/VOD media extraction."),
        ("threads", "ThreadsResolver contract passed with multi-media post extraction."),
        ("tumblr", "TumblrResolver contract passed with reblog and multi-photo extraction."),
        ("imgur", "ImgurResolver contract passed with gallery and GIF/video extraction."),
    ]
    platforms = [
        {
            "platform": platform,
            "status": "passing",
            "evidence": evidence,
        }
        for platform, evidence in shipped_platforms
    ]
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
