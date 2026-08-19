#!/usr/bin/env python3
"""Turn the generated spray-paint-can illustrations into the game masters for the
cone weapon (renamed from "plasma arc" — this is paintball, the short-range
weapon sprays paint).

The can joins the painted bold-outline item family (heart gem, med kit, shield,
paint bomb): chunky silhouette, thick dark ink contour, warm saturated body.

CARD CHOICE: the raws are generated on a flat MEDIUM-GREY card (~rgb 203), not
the dark card the world objects use. On a near-black card nanobanana bakes an
ember-orange bloom around the silhouette, and that halo cannot be separated from
the can's own dark brown ink outline by luminance — every threshold that drops
the glow also eats the outline. A light card inverts the problem: background and
outline sit at opposite ends of the range, so one flood cuts cleanly.

The cut is `build_topdown_gun.py`'s shape (flood the CONNECTED card grey, so any
grey inside the can body is kept), plus a de-speckle and a hair of feather.

TWO MASTERS come out of this, from two different raws:
  * the ITEM (spraycan.png) — the upright can for the floor pickup and the
    carried marker. Square-padded, because loadRgbaSprite() scales the master
    into a square footprint and the padding is what preserves the drawn aspect.
  * the HELD can (spraycan_held.png) — the can lying horizontally with its
    nozzle EAST, mounted in the cog's grip by rigSprayCanPixels(). Tight-cropped
    with NO padding, matching the paintgun_topdown.png convention (muzzle east,
    barrel on the image's vertical mid-line) so the same mount math places it.

Inputs:  scripts/art/src_cvc/spraycan_raw.png, .../spraycan_held_raw.png
Outputs: data/spraycan.png, data/spraycan_held.png
Previews: /tmp/spraycan_master.png, /tmp/spraycan_held_master.png
"""
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "scripts/art/src_cvc"
DATA = ROOT / "data"

BG_TOL = 26      # |channel - card| below this on every channel = card grey
SAT_MAX = 18     # ...and near-neutral: the can's colors are all saturated


def flood_bg(bg_like):
    """The card pixels REACHABLE from the border — interior grey stays opaque."""
    h, w = bg_like.shape
    seen = np.zeros((h, w), bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if bg_like[y, x] and not seen[y, x]:
                seen[y, x] = True
                dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if bg_like[y, x] and not seen[y, x]:
                seen[y, x] = True
                dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not seen[ny, nx] and bg_like[ny, nx]:
                seen[ny, nx] = True
                dq.append((ny, nx))
    return seen


def cut(src: Path):
    """Knocks the card out of one raw, returning the tight-cropped RGBA + alpha."""
    a = np.asarray(Image.open(src).convert("RGB")).astype(np.int16)

    corners = np.concatenate([
        a[:12, :12].reshape(-1, 3), a[:12, -12:].reshape(-1, 3),
        a[-12:, :12].reshape(-1, 3), a[-12:, -12:].reshape(-1, 3)])
    card = corners.mean(0)

    sat = a.max(2) - a.min(2)
    bg_like = (np.abs(a - card).max(2) < BG_TOL) & (sat < SAT_MAX)
    exterior = flood_bg(bg_like)

    alpha = np.where(exterior, 0, 255).astype(np.uint8)
    am = Image.fromarray(alpha).filter(ImageFilter.MedianFilter(3)).filter(
        ImageFilter.GaussianBlur(0.6))
    alpha = np.asarray(am)

    out = Image.fromarray(np.dstack([a.astype(np.uint8), alpha]))
    bbox = Image.fromarray((alpha > 40).astype(np.uint8) * 255).getbbox()
    if bbox:
        out = out.crop(bbox)
    return out, alpha


def preview(img: Image.Image, path: str) -> None:
    """Composites onto a checker so any surviving card fringe is obvious."""
    prev = Image.new("RGBA", img.size)
    px = prev.load()
    for y in range(img.height):
        for x in range(img.width):
            px[x, y] = (210, 206, 197, 255) if ((x // 16 + y // 16) % 2 == 0) \
                else (188, 184, 175, 255)
    prev.alpha_composite(img)
    prev.convert("RGB").save(path)


def main():
    # The ITEM master: square-padded so loadRgbaSprite keeps the drawn aspect.
    item, alpha = cut(SRC / "spraycan_raw.png")
    iw, ih = item.size
    side = max(iw, ih)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(item, ((side - iw) // 2, (side - ih) // 2))
    sq.save(DATA / "spraycan.png")
    preview(sq, "/tmp/spraycan_master.png")
    print(f"wrote {DATA / 'spraycan.png'}  {iw}x{ih} -> {side}x{side}  "
          f"opaque {100 * (alpha > 128).mean():.1f}%")

    # The HELD master: tight-cropped, nozzle east, no padding — the rig mount
    # measures it like the gun master (barrel centered on the image mid-height).
    held, halpha = cut(SRC / "spraycan_held_raw.png")
    held.save(DATA / "spraycan_held.png")
    preview(held, "/tmp/spraycan_held_master.png")
    print(f"wrote {DATA / 'spraycan_held.png'}  {held.width}x{held.height}  "
          f"opaque {100 * (halpha > 128).mean():.1f}%")


if __name__ == "__main__":
    main()
