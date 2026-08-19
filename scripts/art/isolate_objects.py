#!/usr/bin/env python3
"""Isolate the nanobanana OBJECT sprites onto transparent alpha.

This batch renders each object on a SOLID near-neutral warm-dark background
(~rgb 25, warmth r-b ≈ 0). Two naive approaches both fail:
  • binary border flood — LEAKS through gaps in the bright rim into the object's
    own dark interior crevices (mortar/seams are the same near-black as the bg);
  • pure color-key distance matte — EATS the dark object body (a shadowed barrel
    or dark-stone barricade scores almost like the background).

THE FIX — seal-then-flood:
  1. CORE = confident object pixels, keyed on WARMTH (r-b, the bg is neutral) OR
     BRIGHTNESS above the corner-sampled bg. This reliably grabs the ember rim
     and every lit surface; the bg (warmth≈0, score p95≈1) is excluded cleanly.
  2. DILATE the core (MaxFilter) to seal the thin gaps in the rim where crevices
     touch the exterior.
  3. Border FLOOD the not-core field from the corners → the TRUE exterior only.
     Interior dark crevices are walled off by the sealed rim, so they stay part
     of the object (they blend onto the board's own warm-dark floor — no seam).
  4. Feather 1px, tight-crop to the opaque bbox, square-pad (renderer scales the
     footprint to a collision shape, aspect preserved).

Usage: python3 isolate_objects.py <dir>   (operates in place on *.png)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

WARM_T = 6.0    # r-b at/above this = warm object pixel (bg is neutral)
BRIGHT_T = 16.0  # max-channel this far above bg = lit object pixel
SEAL = 9        # MaxFilter window to dilate/seal the core rim


def isolate(src: Path) -> tuple[float, tuple[int, int]]:
    im = Image.open(src).convert("RGB")
    a = np.asarray(im).astype(np.float32)
    h, w, _ = a.shape

    corners = np.concatenate([
        a[:12, :12].reshape(-1, 3), a[:12, -12:].reshape(-1, 3),
        a[-12:, :12].reshape(-1, 3), a[-12:, -12:].reshape(-1, 3)])
    bg = corners.mean(0)

    warmth = a[..., 0] - a[..., 2]
    bright = a.max(2) - bg.max()
    core = (warmth >= WARM_T) | (bright >= BRIGHT_T)

    # dilate core to seal rim gaps
    cm = Image.fromarray((core * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(SEAL))
    sealed = np.asarray(cm) > 128

    # border-flood the exterior: white = flood-candidate (not sealed core).
    # Flood in RGB — PIL's L-mode floodfill is broken (never fills) in this build.
    field = np.where(sealed[..., None], 0, 255).astype(np.uint8).repeat(3, axis=2)
    cand = Image.fromarray(field, "RGB")
    SENT = (255, 0, 255)
    for xy in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
               (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]:
        ImageDraw.floodfill(cand, xy, SENT, thresh=10)
    exterior = np.all(np.asarray(cand) == SENT, axis=2)

    alpha = np.where(exterior, 0, 255).astype(np.uint8)
    am = Image.fromarray(alpha).filter(ImageFilter.MedianFilter(3)).filter(
        ImageFilter.GaussianBlur(0.8))
    alpha2 = np.asarray(am)

    out = Image.fromarray(np.dstack([a.astype(np.uint8), alpha2]))
    bbox = Image.fromarray((alpha2 > 40).astype(np.uint8) * 255).getbbox()
    if bbox:
        out = out.crop(bbox)
    ow, oh = out.size
    side = max(ow, oh)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(out, ((side - ow) // 2, (side - oh) // 2))
    sq.save(src)
    return 100 * (alpha2 > 128).mean(), (ow, oh)


def main() -> None:
    d = Path(sys.argv[1])
    for name in ["crate", "barrel", "barricade", "machinery", "ped_red", "ped_blue"]:
        p = d / f"{name}.png"
        if not p.exists():
            continue
        raw = d / ".raw-with-checker" / p.name
        src_from = raw if raw.exists() else p
        Image.open(src_from).convert("RGB").save(p)  # start from pristine
        opaque, (ow, oh) = isolate(p)
        print(f"  {name:10s} opaque {opaque:5.1f}%  cropped→{ow}x{oh}")
    print("done.")


if __name__ == "__main__":
    main()
