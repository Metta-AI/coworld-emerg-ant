#!/usr/bin/env python3
"""Front-view (eye-level) cog masters for the EYES first-person PiP billboards.

WHY THIS EXISTS: data/soldier_{red,blue}.png is the TOP-DOWN board master (the
cog as seen from ABOVE, "facing SOUTH" per sim.nim). The PiP is an eye-level
raycaster, so blitting the top-down master there shows the body PLATE with the
smile foreshortened onto its lower lip — it reads as "a head on the ground".
No trim/pose math fixes that: an overhead projection is simply the wrong camera.

So the PiP gets its OWN master, drawn from a HORIZONTAL camera with the face
tilted up toward the viewer: data/soldier_{red,blue}_front.png. The board keeps
the top-down master (build_cvc_masters.py) — the two are independent.

Sources (both front-on, generated from the real top-down master so the character
and style match, then hand-picked):
  src_cvc/agent_front.png      — the cog standing, empty-handed.
  src_cvc/agent_front_gun.png  — the same cog holding its paintball marker
                                 forward at the camera (hopper, barrel, grip),
                                 the barrel foreshortened nearly end-on, face
                                 still clear above it.
Nanobanana paints "transparent background" as a literal white/grey CHECKERBOARD
with no alpha, so we knock that out here (same rule as knockout-bg.py: keep
saturated OR dark-ink pixels) before tinting.

Team tint mirrors build_cvc_masters.py: a multiplicative push of the near-neutral
shell toward the team colour at STRENGTH, leaving the cyan smile visor, the dark
ink outline, and the black tires their own colours. Unlike the board master there
is NO baked drop shadow to soften — the billboard draws its own contact shadow —
so alpha stays binary and the whole opaque box is the cog (COG_TRIM_FRONT in
client/replay_broadcast.html is measured from the output printed below).

Outputs: data/soldier_{red,blue}_front.png       (standing, unarmed)
         data/soldier_{red,blue}_front_gun.png   (holding the paintball marker)
Preview: /tmp/cvc_front_preview.png
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent / "src_cvc"
DATA = ROOT / "data"

# Same team colours + strength as the board master, so a cog reads as the same
# team in the PiP as on the board.
RED = np.array([255, 70, 60], np.float32)
BLUE = np.array([70, 140, 255], np.float32)
GREEN = np.array([70, 200, 110], np.float32)
YELLOW = np.array([240, 210, 60], np.float32)
STRENGTH = 0.75

# Checkerboard knockout (see knockout-bg.py): a pixel belongs to the cog if it is
# saturated (coloured shell / cyan visor) OR dark (ink outline, tires).
SAT_KEEP = 26
DARK_KEEP = 95

# Tint mask: push only the near-neutral-to-red SHELL. The cyan visor (high blue+
# green, low red) and the near-black ink/tires must keep their own colour.
CYAN_B = 110         # blue/green at/above this with low red = visor, never tint
CYAN_R = 130
DARK_MAX = 70        # max-channel below this = ink outline / tire, never tint

# Mean luminance the (hue-stripped) shell is normalised to before the team
# multiply — chosen so the tinted result matches the BOARD master's shell
# brightness (~[191,100,94] red / ~[80,98,120] blue), since the source front art
# is far darker than the board master's near-white shell.
NEUTRAL_MEAN = 218.0

TARGET_H = 192       # output height in px (matches the rig masters' scale)


def knockout(rgba):
    """Drop the baked nanobanana checkerboard, leaving clean alpha."""
    a = rgba.astype(np.int16)
    rgb = a[..., :3]
    mn = rgb.min(axis=2)
    sat = rgb.max(axis=2) - mn
    is_object = (sat >= SAT_KEEP) | (mn < DARK_KEEP)
    alpha = np.where(is_object, 255, 0).astype(np.uint8)
    # De-speckle grid remnants, then keep alpha BINARY: the billboard blits the
    # opaque box and draws its own shadow, so a feathered edge would only bleed
    # checker grey into the silhouette.
    am = Image.fromarray(alpha).filter(ImageFilter.MedianFilter(5))
    alpha = (np.asarray(am) >= 128).astype(np.uint8) * 255
    return np.dstack([rgba[..., :3], alpha])


def keep_largest_component(rgba):
    """Zero every opaque blob but the largest — kills stray checker islands."""
    from collections import deque

    a = rgba[..., 3] >= 128
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
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
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
    rgba[..., 3] = np.where(keep, rgba[..., 3], 0)
    return rgba


def tint(rgba, team):
    """Recolour the shell to the team colour, sparing visor + ink + tires.

    The SOURCE cog is red, so a plain multiply (what the board master does over
    its near-neutral white shell) would leave red in the blue team and yield a
    purple cog. So the shell is first flattened to its LUMINANCE — keeping every
    highlight and shading gradient, discarding the source hue — and the team
    colour is multiplied onto that neutral base. Red and blue then read as true
    team colours with identical shading.
    """
    a = rgba.astype(np.float32)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    al = a[..., 3]
    visor = (b >= CYAN_B) & (g >= CYAN_B) & (r < CYAN_R)
    dark = a[..., :3].max(axis=2) < DARK_MAX
    m = ((al >= 128) & ~visor & ~dark).astype(np.float32) * STRENGTH
    m = m[..., None]
    # Rec.601 luma, then normalised to NEUTRAL_MEAN. The source art is much
    # darker than the board master's white shell (raw shell luma ~88 vs ~255),
    # so without this the PiP cog would read as a dim maroon/navy next to the
    # bright board sprite. Normalising the neutral base makes the tinted shell
    # land at the board master's brightness, so the same cog reads as the same
    # team colour in the PiP as on the board.
    lum = (0.299 * r + 0.587 * g + 0.114 * b)
    shell_mean = lum[(al >= 128) & ~visor & ~dark].mean()
    lum = np.clip(lum * (NEUTRAL_MEAN / max(shell_mean, 1.0)), 0, 255)[..., None]
    mult = lum * (team[None, None, :] / 255.0)
    out = a[..., :3] * (1 - m) + mult * m
    return np.dstack([np.clip(out, 0, 255), al]).astype(np.uint8)


def trim(rgba):
    a = rgba[..., 3]
    ys, xs = np.where(a >= 128)
    return rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def build(team, src):
    raw = np.asarray(Image.open(SRC / src).convert("RGBA")).copy()
    rgba = keep_largest_component(knockout(raw))
    rgba = trim(tint(rgba, team))
    im = Image.fromarray(rgba)
    # Scale to a fixed HEIGHT; the billboard sizes off height and derives width
    # from the aspect, so height is the meaningful dimension.
    w = max(1, round(im.width * TARGET_H / im.height))
    return im.resize((w, TARGET_H), Image.LANCZOS)


def main():
    # Two poses per team: the plain standing cog, and the same cog holding its
    # paintball marker forward at the camera (what an ARMED cog shows in the
    # PiP — every live cog carries the gun, so this is the default billboard;
    # the plain pose stays for downed/unarmed reads).
    out = {}
    for label, src in (("", "agent_front.png"), ("_gun", "agent_front_gun.png")):
        for team, colour in (
                ("red", RED), ("blue", BLUE),
                ("green", GREEN), ("yellow", YELLOW)):
            im = build(colour, src)
            im.save(DATA / f"soldier_{team}_front{label}.png")
            out[f"{team}{label}"] = im
            print(f"soldier_{team}_front{label}.png {im.size}"
                  f"  aspect {im.width / im.height:.4f}")
    print("   ^ aspects -> COG_ASPECT / COG_GUN_ASPECT in"
          " client/replay_broadcast.html")

    # Preview on a mid-grey card (checker would hide alpha bugs).
    pad = 16
    order = [out["red"], out["blue"], out["red_gun"], out["blue_gun"]]
    w = sum(i.width for i in order) + pad * (len(order) + 1)
    card = Image.new("RGBA", (w, TARGET_H + pad * 2), (110, 108, 104, 255))
    x = pad
    for i in order:
        card.alpha_composite(i, (x, pad))
        x += i.width + pad
    card.save("/tmp/cvc_front_preview.png")
    print("preview /tmp/cvc_front_preview.png")


if __name__ == "__main__":
    main()
