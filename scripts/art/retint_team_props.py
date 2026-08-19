#!/usr/bin/env python3
"""Derive green/yellow heart and pedestal masters from the red ones.

The red heart/pedestal are hand-generated art with no white-shell master to
tint (unlike the soldiers), so the green/yellow variants hue-rotate the red
master's warm band instead: saturated reddish pixels move to the target team
hue with value/saturation structure preserved, while neutral pixels (stone,
outlines, highlights) stay put.

Run from the repository root:
  python3 scripts/art/retint_team_props.py

Outputs: data/heart_green.png, data/heart_yellow.png,
         data/ped_green.png, data/ped_yellow.png
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"

# Target hues (degrees) matching the viewer palette: --green #45a85e ~ 133,
# --yellow #ddc531 ~ 52.
TARGETS = {"green": 133.0, "yellow": 52.0}

# The red masters' team band: hues within this many degrees of 0 move.
RED_BAND = 45.0
MIN_SAT = 0.25  # leave near-neutral pixels (outline, stone, glints) alone.


def retint(src: Path, dst: Path, hue_deg: float) -> None:
    rgba = np.asarray(Image.open(src).convert("RGBA")).astype(np.float32)
    rgb = rgba[..., :3] / 255.0
    mx = rgb.max(axis=2)
    mn = rgb.min(axis=2)
    delta = mx - mn
    sat = np.where(mx > 0, delta / np.maximum(mx, 1e-6), 0)

    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    hue = np.zeros_like(mx)
    nz = delta > 1e-6
    rmax = nz & (mx == r)
    gmax = nz & (mx == g) & ~rmax
    bmax = nz & ~rmax & ~gmax
    hue[rmax] = (60 * ((g - b) / np.maximum(delta, 1e-6)) % 360)[rmax]
    hue[gmax] = (60 * ((b - r) / np.maximum(delta, 1e-6)) + 120)[gmax]
    hue[bmax] = (60 * ((r - g) / np.maximum(delta, 1e-6)) + 240)[bmax]

    dist = np.minimum(hue, 360 - hue)  # angular distance from red (0 deg)
    move = (dist < RED_BAND) & (sat > MIN_SAT)

    hue = np.where(move, hue_deg, hue)

    # HSV -> RGB
    h6 = (hue / 60.0) % 6
    f = h6 - np.floor(h6)
    v = mx
    p = v * (1 - sat)
    q = v * (1 - sat * f)
    t = v * (1 - sat * (1 - f))
    i = np.floor(h6).astype(int) % 6
    out = np.zeros_like(rgb)
    for idx, (rr, gg, bb) in enumerate(
        [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)]
    ):
        m = i == idx
        out[..., 0][m] = rr[m]
        out[..., 1][m] = gg[m]
        out[..., 2][m] = bb[m]

    keep = ~move
    out[keep] = rgb[keep]
    rgba[..., :3] = np.clip(out * 255.0, 0, 255)
    Image.fromarray(rgba.astype(np.uint8)).save(dst)
    print("wrote", dst)


def main() -> None:
    for name, hue in TARGETS.items():
        retint(DATA / "heart_red.png", DATA / f"heart_{name}.png", hue)
        retint(DATA / "ped_red.png", DATA / f"ped_{name}.png", hue)


if __name__ == "__main__":
    main()
