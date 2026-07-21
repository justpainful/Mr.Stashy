#!/usr/bin/env python3
"""Derive clean, genuinely transparent production character assets.

The approved exploration sheet has a light paper background and characters with cream
fills. A colour-key approach removes those light fills, while loose crops retain nearby
sparkles. This script flood-fills the exterior against a dilated ink barrier and then
keeps only the main connected character component.
"""
from __future__ import annotations

from collections import deque
from pathlib import Path
import json

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "Assets" / "ChatGPT Image Jul 22, 2026, 12_53_15 AM.png"
ENSEMBLE = ROOT / "Assets" / "ChatGPT Image Jul 22, 2026, 12_46_41 AM.png"
CATALOG = ROOT / "Resources" / "Assets.xcassets"

CHARACTERS = {
    # These boxes include safe paper margin; the component pass removes decorations.
    "humanA": (180, 130, 440, 585),
    "humanB": (565, 115, 910, 595),
    "orbit": (995, 190, 1375, 585),
    "bloom": (115, 665, 410, 1030),
    "sprout": (470, 650, 700, 1025),
    "round": (675, 730, 925, 1025),
    "geo": (930, 660, 1195, 1035),
    "cloud": (1145, 685, 1445, 1035),
}


def is_paper(pixel: tuple[int, int, int, int]) -> bool:
    """Match the low-saturation cream paper, not a generic white key colour."""
    r, g, b, _ = pixel
    return min(r, g, b) > 145 and max(r, g, b) - min(r, g, b) < 65


def main_component(image: Image.Image) -> Image.Image:
    """Remove isolated marks while retaining antialiased pixels adjacent to the character."""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    width, height = rgba.size
    visited: set[tuple[int, int]] = set()
    largest: set[tuple[int, int]] = set()
    for start_y in range(height):
        for start_x in range(width):
            if (start_x, start_y) in visited or pixels[start_x, start_y][3] < 24:
                continue
            component: set[tuple[int, int]] = set()
            queue = deque([(start_x, start_y)])
            visited.add((start_x, start_y))
            while queue:
                x, y = queue.popleft()
                component.add((x, y))
                for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                    if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in visited and pixels[nx, ny][3] >= 24:
                        visited.add((nx, ny))
                        queue.append((nx, ny))
            if len(component) > len(largest):
                largest = component
    selected = set(largest)
    for x, y in list(largest):
        for nx in range(max(0, x - 1), min(width, x + 2)):
            for ny in range(max(0, y - 1), min(height, y + 2)):
                if pixels[nx, ny][3] > 0:
                    selected.add((nx, ny))
    for y in range(height):
        for x in range(width):
            if (x, y) not in selected:
                r, g, b, _ = pixels[x, y]
                pixels[x, y] = (r, g, b, 0)
    return rgba


def exterior_mask(image: Image.Image) -> Image.Image:
    """Remove exterior paper while preserving light fills enclosed by ink."""
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    width, height = rgba.size
    transparent: set[tuple[int, int]] = set()
    queue = deque()
    barrier = Image.new("L", (width, height), 0)
    barrier.putdata([0 if is_paper(pixel) else 255 for pixel in rgba.get_flattened_data()])
    # Morphologically close fine gaps in generated line art only for the flood-fill decision.
    # A matching erosion restores the normal stroke boundary, avoiding a cream halo.
    barrier = barrier.filter(ImageFilter.MaxFilter(11)).filter(ImageFilter.MinFilter(11))
    barrier_pixels = barrier.load()

    def is_exterior_candidate(x: int, y: int) -> bool:
        return barrier_pixels[x, y] == 0 and is_paper(pixels[x, y])

    for x in range(width):
        for y in (0, height - 1):
            if is_exterior_candidate(x, y):
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if is_exterior_candidate(x, y):
                queue.append((x, y))

    while queue:
        x, y = queue.popleft()
        if (x, y) in transparent or not is_exterior_candidate(x, y):
            continue
        transparent.add((x, y))
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in transparent:
                queue.append((nx, ny))

    for x, y in transparent:
        r, g, b, _ = pixels[x, y]
        pixels[x, y] = (r, g, b, 0)
    return main_component(rgba)

def write_imageset(name: str, image: Image.Image) -> None:
    folder = CATALOG / "Characters" / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    out = folder / f"{name}.png"
    alpha_box = image.getchannel("A").getbbox()
    if alpha_box is None:
        raise RuntimeError(f"No visible pixels remained for {name}")
    left, top, right, bottom = alpha_box
    padding = max(8, round(max(right - left, bottom - top) * 0.055))
    image = image.crop((max(0, left - padding), max(0, top - padding), min(image.width, right + padding), min(image.height, bottom + padding)))
    image.thumbnail((688, 688), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (768, 768), (0, 0, 0, 0))
    canvas.alpha_composite(image, ((768 - image.width) // 2, (768 - image.height) // 2))
    canvas.save(out)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": out.name, "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n")

def main() -> None:
    if not REFERENCE.exists():
        raise SystemExit(f"Missing approved reference: {REFERENCE}")
    source = Image.open(REFERENCE)
    for name, box in CHARACTERS.items():
        write_imageset(name, exterior_mask(source.crop(box)))

    icon_dir = CATALOG / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    ensemble = Image.open(ENSEMBLE).convert("RGB")
    width, height = ensemble.size
    side = min(width, height)
    crop = ensemble.crop(((width - side) // 2, 0, (width + side) // 2, side)).resize((1024, 1024), Image.Resampling.LANCZOS)
    crop.save(icon_dir / "AppIcon-1024.png")
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n")

if __name__ == "__main__":
    main()
