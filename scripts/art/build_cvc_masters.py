#!/usr/bin/env python3
"""Team soldier masters from the REAL Cogs-vs-Clips cog sprite.

Body = src_cvc/agent_s.png: the canonical CvC agent facing SOUTH with the cyan
smile visor — used EXACTLY as drawn (no hat, no repaint). The renderer keeps the
body upright and sweeps only the gun (sim.nim soldierRotPixels), so the smile
stays visible at every aim angle.

Team = multiplicative tint of the bright/near-neutral white shell toward the
team colour. The cyan smile, dark details, and the baked soft shadow keep their
own colours. Shadow alpha is remapped below the renderer's solid threshold (64)
so outlines/measurement hug the body, not the shadow.

Gun = src_cvc/paintgun_east.png (muzzle pointing east), padded so the BARREL
CENTERLINE sits exactly at the vertical center of the image — sim.nim mounts
gun-local (0, h/2) on the aim ray, so the tracer lines up with the barrel.

Outputs: data/soldier_red.png, data/soldier_blue.png, data/paintgun.png
Preview: /tmp/cvc_masters_preview.png
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent / "src_cvc"
DATA = ROOT / "data"

# White shell -> team colour. Strong tint: the team read has to survive the
# brown floor and 34px scale; shading still comes through the multiply.
RED = np.array([255, 70, 60], np.float32)
BLUE = np.array([70, 140, 255], np.float32)
GREEN = np.array([70, 200, 110], np.float32)
YELLOW = np.array([240, 210, 60], np.float32)
TEAMS = (("red", RED), ("blue", BLUE), ("green", GREEN), ("yellow", YELLOW))
STRENGTH = 0.75

SOLID = 200          # alpha >= SOLID = the cog body proper.
SHADOW_MAX = 60      # remap sub-solid alpha to 0..SHADOW_MAX (< renderer's 64).


def tint(rgba, team):
    """Multiply the shell toward team colour through the OFFICIAL CvC tint mask
    (agent_s_mask.png, the same selective-coloring mask mettascope uses at
    runtime) — the cyan smile, wheels, and shadow are outside it."""
    a = rgba.astype(np.float32)
    al = a[..., 3]
    mask = np.asarray(
        Image.open(SRC / "agent_s_mask.png").convert("L"), np.float32
    ) / 255.0
    m = mask * (al >= SOLID)
    m = (m * STRENGTH)[..., None]
    mult = a[..., :3] * (team[None, None, :] / 255.0)
    out = a[..., :3] * (1 - m) + mult * m
    return np.dstack([np.clip(out, 0, 255), al]).astype(np.uint8)


def soften_shadow(rgba):
    """Remap sub-solid alpha into 0..SHADOW_MAX so the baked drop shadow never
    trips the renderer's alpha-64 solid tests (outline, pivot measurement)."""
    a = rgba[..., 3].astype(np.float32)
    soft = a * (SHADOW_MAX / float(SOLID))
    rgba[..., 3] = np.where(a >= SOLID, a, soft).astype(np.uint8)
    return rgba


def trim(rgba, pad=4):
    a = rgba[..., 3]
    ys, xs = np.where(a > 0)
    x0 = max(0, xs.min() - pad)
    y0 = max(0, ys.min() - pad)
    x1 = min(rgba.shape[1] - 1, xs.max() + pad)
    y1 = min(rgba.shape[0] - 1, ys.max() + pad)
    return rgba[y0:y1 + 1, x0:x1 + 1]


def build_body(team):
    rgba = np.asarray(Image.open(SRC / "agent_s.png").convert("RGBA")).copy()
    return Image.fromarray(trim(soften_shadow(tint(rgba, team))))


def keep_largest_component(rgba, thresh=32):
    """Zero out every opaque blob except the largest (kills stray specks)."""
    from collections import deque

    a = rgba[..., 3] >= thresh
    h, w = a.shape
    seen = np.zeros((h, w), bool)
    best = None
    for sy, sx in zip(*np.where(a)):
        if seen[sy, sx]:
            continue
        blob = [(sy, sx)]
        seen[sy, sx] = True
        q = deque(blob)
        while q:
            y, x = q.popleft()
            for ny, nx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)):
                if 0 <= ny < h and 0 <= nx < w and a[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    blob.append((ny, nx))
                    q.append((ny, nx))
        if best is None or len(blob) > len(best):
            best = blob
    keep = np.zeros((h, w), bool)
    if best:
        ys, xs = zip(*best)
        keep[list(ys), list(xs)] = True
    rgba[..., 3] = np.where(a & ~keep, 0, rgba[..., 3])
    return rgba


def build_gun():
    rgba = np.asarray(
        Image.open(SRC / "paintgun_east.png").convert("RGBA")
    ).copy()
    rgba = keep_largest_component(rgba)
    # Drop sub-threshold haze the component pass can't see (faint smudges).
    rgba[..., 3] = np.where(rgba[..., 3] < 32, 0, rgba[..., 3])
    rgba = trim(rgba, pad=0)
    # Barrel centerline = solid rows within the rightmost quarter (the bare
    # barrel tube). Pad top/bottom so that line sits at exactly height/2.
    a = rgba[..., 3]
    right = a[:, int(a.shape[1] * 0.75):]
    rows = np.where((right >= 128).any(axis=1))[0]
    barrel = (rows.min() + rows.max()) / 2.0
    h = rgba.shape[0]
    top_pad = max(0, int(round(h - 2 * barrel)))
    bot_pad = max(0, int(round(2 * barrel - h)))
    rgba = np.pad(rgba, ((top_pad, bot_pad), (0, 0), (0, 0)))
    return Image.fromarray(rgba)


def main():
    bodies = [(name, build_body(colour)) for name, colour in TEAMS]
    gun = build_gun()
    for name, im in bodies:
        im.save(DATA / f"soldier_{name}.png")
    gun.save(DATA / "paintgun.png")
    print(" ".join(f"{name} {im.size}" for name, im in bodies),
          "gun", gun.size)
    red, blue = bodies[0][1], bodies[1][1]

    paper = (238, 236, 229, 255)
    prev = Image.new("RGBA", (1150, 560), paper)
    d = ImageDraw.Draw(prev)
    x = 30
    for im, lbl in ((red, "RED"), (blue, "BLUE"), (gun, "GUN")):
        big = im.copy()
        big.thumbnail((260, 260), Image.LANCZOS)
        prev.paste(big, (x, 90), big)
        map_h = 34 if lbl != "GUN" else 15
        mw = max(1, round(im.width * map_h / im.height))
        small = im.resize((mw, map_h), Image.LANCZOS)
        z = small.resize((mw * 5, map_h * 5), Image.NEAREST)
        prev.paste(z, (x, 380), z)
        d.text((x, 60), f"{lbl}  (big / true on-map @5x)", fill=(40, 40, 40, 255))
        x += 380
    out = "/tmp/cvc_masters_preview.png"
    prev.save(out)
    print("preview", out)


if __name__ == "__main__":
    main()
