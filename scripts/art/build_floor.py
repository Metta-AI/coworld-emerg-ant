#!/usr/bin/env python3
"""Bake data/arena_floor.png: a seamless 256x256 polished-concrete tile.

Replaces the old brown flagstone floor with grey polished concrete: broad
troweled mottle, fine aggregate grain, subtle embossed panel seams on the
tile borders and center lines (so the tile seam IS a seam and tiling stays
seamless), and a few meandering hairline cracks per panel.

The luminance envelope is a CONTRACT with sim.nim's endzone ember glow
(emberThroughCracks): pixels at/above EndzoneFaceLevel (66) get no glow,
pixels at/below EndzoneCrackLevel (34) glow fully. The polished surface —
including the light bevel seams — sits safely above 66; only the hairline
crack bottoms dip to ~26..34, so team ember confines to the actual cracks.

Usage: python3 scripts/art/build_floor.py  (writes data/arena_floor.png)
"""

import numpy as np
from PIL import Image
from pathlib import Path

SIZE = 256
rng = np.random.default_rng(1177)

# Neutral-warm grey ramp (the house style forbids cold blue-slate): each
# pixel's luminance v maps to rgb with a whisper of warmth, never a hue.
def to_rgb(v):
    r = np.clip(v * 1.020 + 1.5, 0, 255)
    g = np.clip(v, 0, 255)
    b = np.clip(v * 0.965 - 1.0, 0, 255)
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def tileable_noise(size, cutoff, power):
    """FFT-synthesized noise — periodic by construction, hence seamless."""
    spec = rng.normal(size=(size, size)) + 1j * rng.normal(size=(size, size))
    fy = np.fft.fftfreq(size)[:, None]
    fx = np.fft.fftfreq(size)[None, :]
    f = np.hypot(fx, fy)
    f[0, 0] = 1.0
    falloff = np.where(f <= cutoff, 1.0 / (f ** power), 0.0)
    falloff[0, 0] = 0.0
    field = np.real(np.fft.ifft2(spec * falloff))
    field -= field.mean()
    return field / (field.std() + 1e-9)


# --- Surface: troweled mottle + faint drift + fine grain -------------------
lum = np.full((SIZE, SIZE), 88.0)
lum += tileable_noise(SIZE, 0.04, 1.6) * 7.0    # broad trowel blotches
lum += tileable_noise(SIZE, 0.12, 1.3) * 4.0    # mid-scale clouding
lum += tileable_noise(SIZE, 0.50, 0.9) * 2.2    # fine sanded grain

# Aggregate specks: sparse 1px flecks a touch lighter/darker, plus rare
# pinholes (polished slabs always carry a few).
n_flecks = 900
ys = rng.integers(0, SIZE, n_flecks)
xs = rng.integers(0, SIZE, n_flecks)
lum[ys, xs] += rng.normal(0, 5.5, n_flecks)
n_pin = 70
ys = rng.integers(0, SIZE, n_pin)
xs = rng.integers(0, SIZE, n_pin)
lum[ys, xs] -= rng.uniform(14, 26, n_pin)

lum = np.clip(lum, 72, 112)  # polished surface stays above the glow gate (66)

# depth[y,x] in 0..1: how far a pixel dips toward crack-bottom darkness.
# Joints and cracks write into this, then one final composite applies it.
depth = np.zeros((SIZE, SIZE))


def carve(y, x, d):
    yy, xx = int(y) % SIZE, int(x) % SIZE
    depth[yy, xx] = max(depth[yy, xx], d)


# --- Control joints on tile borders + center lines ------------------------
# Placing joints AT the wrap seam hides it; the 256 tile reads as 2x2
# polished panels of 128px. The joints are NOT dark cuts: each is a subtle
# emboss bevel — a soft shade line beside a light catch line — so the grid
# reads as panel seams in polished concrete, not a painted black grid. Only
# the hairline cracks dip into the ember-glow band; joint pixels stay in
# no-glow surface territory. A touch of noise keeps the lines from reading
# machine-perfect.
joint_bevel = np.zeros((SIZE, SIZE))
for c in (0, SIZE // 2):
    for off, dv in ((-2, -5.0), (-1, -13.0), (0, 11.0), (1, 4.5)):
        wobble_r = 1.0 + 0.2 * tileable_noise(SIZE, 0.30, 1.0)[(c + off) % SIZE, :]
        wobble_c = 1.0 + 0.2 * tileable_noise(SIZE, 0.30, 1.0)[:, (c + off) % SIZE]
        joint_bevel[(c + off) % SIZE, :] += dv * wobble_r
        joint_bevel[:, (c + off) % SIZE] += dv * wobble_c
lum += joint_bevel
lum = np.clip(lum, 72, 112)  # bevels stay inside the no-glow surface band

# --- Hairline cracks: momentum random walks confined to panel interiors ---
# Each panel gets 2-3 cracks seeded off a panel edge. They never cross the
# edges, so tiling stays seamless without wrap logic.
PANELS = [(oy, ox) for oy in (0, 128) for ox in (0, 128)]
for oy, ox in PANELS:
    for _ in range(rng.integers(2, 4)):
        edge = rng.integers(0, 4)
        if edge == 0:   y, x, ang = oy + 3.0, ox + rng.uniform(20, 108), rng.uniform(0.6, 2.5)
        elif edge == 1: y, x, ang = oy + 125.0, ox + rng.uniform(20, 108), -rng.uniform(0.6, 2.5)
        elif edge == 2: y, x, ang = oy + rng.uniform(20, 108), ox + 3.0, rng.uniform(-0.9, 0.9)
        else:           y, x, ang = oy + rng.uniform(20, 108), ox + 125.0, np.pi - rng.uniform(-0.9, 0.9)
        steps = rng.integers(45, 110)
        strength = rng.uniform(0.55, 0.9)
        branch_left = 1
        for i in range(steps):
            ang += rng.normal(0, 0.28)
            y += np.sin(ang)
            x += np.cos(ang)
            if not (oy + 2 < y < oy + 126 and ox + 2 < x < ox + 126):
                break
            taper = strength * (1.0 - 0.5 * i / steps)
            carve(y, x, taper)
            # hairline sections read as ~1px; occasionally widen a hair
            if rng.random() < 0.35:
                carve(y + rng.integers(-1, 2), x + rng.integers(-1, 2), taper * 0.45)
            if branch_left and rng.random() < 0.02 and i > 12:
                branch_left -= 1
                by, bx, bang = y, x, ang + rng.choice([-1, 1]) * rng.uniform(0.7, 1.3)
                for j in range(int(steps * 0.4)):
                    bang += rng.normal(0, 0.3)
                    by += np.sin(bang)
                    bx += np.cos(bang)
                    if not (oy + 2 < by < oy + 126 and ox + 2 < bx < ox + 126):
                        break
                    carve(by, bx, taper * (1.0 - 0.6 * j / (steps * 0.4)))

# --- Composite: dip lum toward crack-bottom, add a spall highlight --------
# Full depth lands at lum ~27 (below EndzoneCrackLevel 34 -> full ember glow);
# hairline taper passes through the 34..66 partial-glow band naturally.
CRACK_BOTTOM = 27.0
lum = lum * (1.0 - depth) + CRACK_BOTTOM * depth

# 1px light catch on the lower-right of deep cuts: reads as the polished
# edge catching light, and keeps cracks crisp instead of muddy.
spall = np.roll(np.roll(depth, 1, axis=0), 1, axis=1) - depth
lum += np.clip(spall, 0, 1) * 6.0

img = Image.fromarray(to_rgb(np.clip(lum, 24, 118)))
out = Path(__file__).resolve().parents[2] / "data" / "arena_floor.png"
img.save(out)

a = np.asarray(img).astype(int)
l = (a[..., 0] * 30 + a[..., 1] * 59 + a[..., 2] * 11) // 100
print(f"wrote {out}")
print(f"lum min/max/mean: {l.min()}/{l.max()}/{l.mean():.0f}")
print(f"pixels below CrackLevel(34): {(l <= 34).mean() * 100:.1f}%  "
      f"above FaceLevel(66): {(l >= 66).mean() * 100:.1f}%")
