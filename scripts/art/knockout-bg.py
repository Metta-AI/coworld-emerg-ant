#!/usr/bin/env python3
"""Knock the nanobanana transparency-checkerboard (and the baked soft shadow) out
of the world OBJECT assets, leaving clean PNG+alpha.

THE BUG this fixes: nanobanana renders "transparent background" as a literal
checkerboard of WHITE + LIGHT-GREY squares painted into the image. An earlier
white-only cutout removed the white squares but left the grey ones as opaque
polka-dots, and each asset ALSO carries its own soft grey contact shadow — so the
renderer drew a SECOND ellipse shadow on top (double shadow).

THE FIX: keep ONLY pixels that are part of the drawn object — saturated (coloured)
OR dark (the warm-brown ink outline). Everything neutral-and-not-dark (the checker
grid AND the soft grey baked shadow) is knocked to full transparency. The object's
dark outline walls off interior bright regions (sheep fleece, window glints, the
cow's white patches) so a global rule is safe without a flood fill. The single
clean contact shadow is then owned by the renderer (WorldFarm's <ellipse>), not the
art — so it's consistent across the whole set and never doubled.

Ground tiles (grass/soil) are full-bleed textures with no object/shadow — skipped.

Usage:  python3 knockout-bg.py <world_art_dir>   (defaults to the live game dir)
Outputs in place; originals backed up once to <dir>/.raw-with-checker/.
"""
import sys
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

# Ground textures fill the square edge-to-edge (no object, no shadow) — never knock.
GROUND = {"grass.png", "soil.png"}

# Pixel is "object" if it is opaque-ish AND (saturated colour OR dark ink outline).
ALPHA_FLOOR = 60   # ignore near-transparent pixels
SAT_KEEP = 26      # chroma at/above this = a coloured object pixel
DARK_KEEP = 95     # min-channel below this = ink outline / deep shadow detail of the object


def knockout(src: Path, dst: Path) -> tuple[float, float]:
    im = Image.open(src).convert("RGBA")
    a = np.asarray(im).astype(np.int16)
    rgb, al = a[..., :3], a[..., 3]
    mn = rgb.min(axis=2)
    sat = rgb.max(axis=2) - mn

    is_object = (al > ALPHA_FLOOR) & ((sat >= SAT_KEEP) | (mn < DARK_KEEP))
    alpha = np.where(is_object, al.clip(0, 255), 0).astype(np.uint8)

    # de-speckle isolated grid remnants, then feather the cut edge 1px so no bright fringe survives
    am = Image.fromarray(alpha).filter(ImageFilter.MedianFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
    alpha2 = np.asarray(am)

    out = Image.fromarray(np.dstack([a[..., :3].astype(np.uint8), alpha2]))
    out.save(dst)
    return 100 * (al < 30).mean(), 100 * (alpha2 < 30).mean()


def main() -> None:
    art = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        "~/metta/packages/cogweb/games/agricogla/public/art/world"
    ).expanduser()
    backup = art / ".raw-with-checker"
    backup.mkdir(exist_ok=True)
    for png in sorted(art.glob("*.png")):
        if png.name in GROUND:
            print(f"  {png.name:18s} (ground tile — skipped)")
            continue
        raw = backup / png.name
        if not raw.exists():
            shutil.copy2(png, raw)  # one-time backup of the checker original
        before, after = knockout(raw, png)  # always knock from the pristine raw
        print(f"  {png.name:18s} transp {before:5.1f}% -> {after:5.1f}%")
    print("done — clean RGBA PNGs in place; raw originals in .raw-with-checker/")


if __name__ == "__main__":
    main()
