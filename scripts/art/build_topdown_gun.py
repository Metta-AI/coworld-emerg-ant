#!/usr/bin/env python3
"""Turn the generated top-down paintball marker (nanobanana paintba_3) into the
game gun master: data/paintgun_topdown.png.

The generated sprite is a tall top-down marker on a flat grey (203,203,203) card,
barrel pointing NORTH, with a baked soft drop-shadow. We:
  1. flood-fill the connected grey background to transparent (interior grey fills of
     the gun body are KEPT — only bg reachable from the border is cut);
  2. knock the baked light-grey soft shadow out (light + desaturated obj pixels);
  3. crop to the gun, then ROTATE 90° clockwise so the muzzle points EAST and the
     barrel centerline runs horizontally — matching the paintgun.png mount
     convention (muzzle east, barrel on the image's vertical mid-line). The mount
     code in sim.nim then places grip->hub and offsets it to the head's right.

Output: data/paintgun_topdown.png  (muzzle east, barrel centered vertically)
Preview: /tmp/topdown_gun.png
"""
from pathlib import Path
from collections import deque
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "nanobanana-output" / "topdown_game_sprite_of_a_paintba_3.png"
OUT = ROOT / "data" / "paintgun_topdown.png"

BG = 203              # flat card grey
BG_TOL = 20           # |channel-BG| below this (all channels) = card-grey
SHADOW_MIN = 150      # light-grey ...
SHADOW_MAX = 205      # ... soft baked shadow band (min channel)
SHADOW_SAT = 16       # ... and near-neutral (low chroma)


def flood_bg(bg_like):
    h, w = bg_like.shape
    seen = np.zeros((h, w), bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if bg_like[y, x]:
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


def main():
    im = Image.open(SRC).convert("RGBA")
    a = np.asarray(im).astype(np.int16)
    rgb = a[..., :3]
    mn = rgb.min(axis=2)
    sat = rgb.max(axis=2) - mn

    bg_like = (np.abs(rgb - BG).max(axis=2) < BG_TOL)
    bg = flood_bg(bg_like)                       # connected card grey only
    # baked soft shadow: light, near-neutral object pixels that survived the flood
    shadow = (~bg) & (mn >= SHADOW_MIN) & (mn <= SHADOW_MAX) & (sat < SHADOW_SAT)
    keep = (~bg) & (~shadow)

    alpha = np.where(keep, 255, 0).astype(np.uint8)
    # de-speckle + 0.6px feather so no bright card fringe survives the cut
    am = Image.fromarray(alpha).filter(ImageFilter.MedianFilter(3)) \
        .filter(ImageFilter.GaussianBlur(0.6))
    alpha = np.asarray(am)

    out = np.dstack([a[..., :3].astype(np.uint8), alpha])
    im2 = Image.fromarray(out)
    # crop to content
    ys, xs = np.where(alpha > 20)
    im2 = im2.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
    # barrel points NORTH -> rotate 90° CLOCKWISE so it points EAST (muzzle right)
    im2 = im2.transpose(Image.ROTATE_270)
    im2.save(OUT)

    # preview on a checker
    prev = Image.new("RGBA", im2.size, (0, 0, 0, 0))
    dd = Image.new("RGBA", im2.size)
    px = dd.load()
    for y in range(im2.height):
        for x in range(im2.width):
            c = (210, 206, 197, 255) if ((x // 8 + y // 8) % 2 == 0) \
                else (188, 184, 175, 255)
            px[x, y] = c
    dd.alpha_composite(im2)
    dd.convert("RGB").save("/tmp/topdown_gun.png")
    print(f"wrote {OUT}  size={im2.size}  preview /tmp/topdown_gun.png")


if __name__ == "__main__":
    main()
