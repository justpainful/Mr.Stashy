#!/usr/bin/env python3
"""Validate isolated Stashy production PNGs for genuine alpha and common matte failures."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
CHARACTER_ROOT = ROOT / "Resources" / "Assets.xcassets" / "Characters"
REPORT = ROOT / "Artifacts" / "AssetValidationReport.json"

def flattened_values(image: Image.Image):
    return getattr(image, "get_flattened_data", image.getdata)()

def edge_pixels(image: Image.Image):
    width, height = image.size
    pixels = image.load()
    for x in range(width):
        yield pixels[x, 0]
        yield pixels[x, height - 1]
    for y in range(1, height - 1):
        yield pixels[0, y]
        yield pixels[width - 1, y]

def has_checkerboard(image: Image.Image) -> bool:
    width, height = image.size
    if width < 8 or height < 8:
        return False
    sample = image.convert("RGB").resize((32, 32))
    values = list(flattened_values(sample))
    light = sum(1 for r, g, b in values if r > 175 and g > 175 and b > 175)
    gray = sum(1 for r, g, b in values if abs(r - g) < 8 and abs(g - b) < 8)
    return light > 600 and gray > 700

def inspect(path: Path) -> dict:
    image = Image.open(path)
    result = {"path": str(path.relative_to(ROOT)).replace("\\", "/"), "dimensions": list(image.size), "mode": image.mode, "errors": []}
    if image.mode != "RGBA":
        result["errors"].append("mode is not RGBA")
        return result
    # Pillow 10 keeps getdata(); newer development builds provide the flattened alias.
    # Support both to keep this verifier reproducible on the pinned CI version.
    alpha_channel = image.getchannel("A")
    alpha_values = flattened_values(alpha_channel)
    alpha = list(alpha_values)
    result["minAlpha"] = min(alpha)
    result["maxAlpha"] = max(alpha)
    if result["minAlpha"] != 0:
        result["errors"].append("no fully transparent pixels")
    if result["maxAlpha"] != 255:
        result["errors"].append("no fully opaque subject pixels")
    corners = [image.getpixel((0, 0))[3], image.getpixel((image.width - 1, 0))[3], image.getpixel((0, image.height - 1))[3], image.getpixel((image.width - 1, image.height - 1))[3]]
    result["cornerAlpha"] = corners
    if any(corners):
        result["errors"].append("outer corners are not transparent")
    nearly_white_edge = sum(1 for r, g, b, a in edge_pixels(image) if a > 20 and r > 235 and g > 235 and b > 235)
    result["suspiciousWhiteEdgePixels"] = nearly_white_edge
    if has_checkerboard(image):
        result["errors"].append("possible checkerboard background")
    visible = {(x, y) for y in range(image.height) for x in range(image.width) if image.getpixel((x, y))[3] >= 24}
    components = []
    while visible:
        start = visible.pop()
        component = {start}
        queue = [start]
        while queue:
            x, y = queue.pop()
            for neighbour in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if neighbour in visible:
                    visible.remove(neighbour)
                    component.add(neighbour)
                    queue.append(neighbour)
        components.append(component)
    components.sort(key=len, reverse=True)
    if components:
        main = components[0]
        min_x = min(x for x, _ in main)
        max_x = max(x for x, _ in main)
        min_y = min(y for _, y in main)
        max_y = max(y for _, y in main)
        bounding_area = (max_x - min_x + 1) * (max_y - min_y + 1)
        result["mainComponentRatio"] = round(len(main) / sum(map(len, components)), 4)
        result["mainComponentFill"] = round(len(main) / bounding_area, 4)
        result["componentCount"] = len(components)
        if result["mainComponentRatio"] < 0.995:
            result["errors"].append("unconnected decorative or stray pixels remain")
        if result["mainComponentFill"] < 0.12:
            result["errors"].append("main character is not solidly preserved")
    else:
        result["errors"].append("no visible character pixels")
    return result

def main() -> int:
    entries = [inspect(path) for path in sorted(CHARACTER_ROOT.glob("*.imageset/*.png"))]
    if not entries:
        entries = [{"path": "", "errors": ["no isolated character assets found"]}]
    passed = all(not entry["errors"] for entry in entries)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({"passed": passed, "assets": entries}, indent=2) + "\n")
    print(f"Asset validation {'passed' if passed else 'failed'}: {len(entries)} isolated PNGs")
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main())
