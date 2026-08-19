#!/usr/bin/env python3
"""Cut the REAL Cogs-vs-Clips cog (src_cvc/agent_s.png) into TURRET-RIG segments.

Same source + tint mask as build_cvc_masters.py — the art is SLICED, never
regenerated. The rig is a tank-style trike: a HEAD (cube + cyan visor, aims) that
swivels independently of a 3-legged base that tracks MOVEMENT, with the wheels cut
out of the legs as separate CASTER segments, plus ARMS (the shoulder pads) that
tuck when idle and reach forward to cradle the heart only when carrying.

Segments (192px frame space; recompose to the south master at rest):
  head    - cube + cyan visor (x73-118, y52-109). Faces AIM. Gun mounts on it.
  arm_l   - left shoulder assembly (post+strut+pad, x59-72). Tuck/extend about a
  arm_r     shoulder bone. RIGHT mirrored (x118-131).
  leg_fl  - left front strut (leg column minus its tire). Faces MOVEMENT, hinges
  leg_fr    at its hip, shortens on a turn. RIGHT + REAR (rear = recentred strut).
  leg_rear
  wheel_l - left front tire (oval cut out of the leg), casters about its axle.
  wheel_r   RIGHT + REAR tires.
  wheel_rear

Outputs (per team, tinted through the official CvC mask):
  data/rig_real/{team}/{head,arm_l,arm_r,leg_fl,leg_fr,leg_rear,
                        wheel_l,wheel_r,wheel_rear}.png   (all 192px frame-space)
  data/rig_real/anchors.json
Preview: /tmp/cvc_rig_segments.png
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent / "src_cvc"
OUT = ROOT / "data" / "rig_real"

RED = np.array([255, 70, 60], np.float32)
BLUE = np.array([70, 140, 255], np.float32)
GREEN = np.array([70, 200, 110], np.float32)
YELLOW = np.array([240, 210, 60], np.float32)
STRENGTH = 0.75
SOLID = 200
FRAME = 192

# --- Geometry in 192px agent_s frame space (measured this session) ---
HUB = (96.0, 88.0)            # cog rotation center (head-cube center); head + legs
                              # + arms all measured from here.

# Head cube + visor block.
HEAD_X0, HEAD_X1 = 73, 118
HEAD_Y0, HEAD_Y1 = 50, 110
# The two central leg-struts hang from the cube below the visor in this narrow
# x-band; they are CUT from the head (below the smile) so the aim-tracking head
# doesn't wave them forward as prongs. The smile/eyes end ~y108.
HEAD_CENTER_X0, HEAD_CENTER_X1 = 84, 108
HEAD_STRUT_CUT_Y = 109

# Arms = the two shoulder assemblies (post + strut + rounded pad).
ARM_L_X0, ARM_L_X1 = 52, 73
ARM_R_X0, ARM_R_X1 = 118, 141
ARM_Y0, ARM_Y1 = 68, 96
ARM_L_BONE = (70.0, 84.0)     # where the left arm attaches to the head side.
ARM_R_BONE = (120.0, 84.0)

# Front legs: solid pixels below the hip line, in the outer x-bands.
LEG_L_LO, LEG_L_HI = 56.0, 86.0
LEG_R_LO, LEG_R_HI = 106.0, 134.0
HIP_LINE_Y = 100.0
HIP_FL = (72.0, 100.0)        # leg swing pivots.
HIP_FR = (120.0, 100.0)
HIP_REAR = (96.0, 96.0)       # rear hip, centered behind the cube.

# Tire ovals (front wheels) cut OUT of the legs.
WHEEL_FL = dict(cx=75.0, cy=132.0, rx=13.0, ry=24.0, ang=-6.0)
WHEEL_FR = dict(cx=116.0, cy=131.0, rx=13.0, ry=24.0, ang=6.0)
AXLE_FL = (75.0, 132.0)       # wheel caster centers (tire centroid ~ oval center).
AXLE_FR = (116.0, 131.0)
REAR_FOOT_LEN = 30.0          # rear axle distance below the rear hip.


def load_mask():
    return np.asarray(Image.open(SRC / "agent_s_mask.png").convert("L"),
                      np.float32) / 255.0


def tint(rgba, team, mask):
    a = rgba.astype(np.float32)
    al = a[..., 3]
    m = mask * (al >= SOLID)
    m = (m * STRENGTH)[..., None]
    mult = a[..., :3] * (team[None, None, :] / 255.0)
    out = a[..., :3] * (1 - m) + mult * m
    return np.dstack([np.clip(out, 0, 255), al]).astype(np.uint8)


def ellipse_soft(spec):
    yy, xx = np.mgrid[0:FRAME, 0:FRAME].astype(np.float32)
    t = np.radians(spec["ang"])
    dx, dy = xx - spec["cx"], yy - spec["cy"]
    u = dx * np.cos(t) + dy * np.sin(t)
    v = -dx * np.sin(t) + dy * np.cos(t)
    r = np.sqrt((u / spec["rx"]) ** 2 + (v / spec["ry"]) ** 2)
    return np.clip((1.15 - r) / 0.30, 0.0, 1.0)


def box(x0, x1, y0, y1):
    yy, xx = np.mgrid[0:FRAME, 0:FRAME]
    return (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)


def apply_alpha(rgba, factor):
    out = rgba.copy()
    out[..., 3] = np.clip(rgba[..., 3].astype(np.float32) * factor, 0,
                          255).astype(np.uint8)
    return out


def shift(rgba, dx, dy):
    out = np.zeros_like(rgba)
    x0s, x1s = max(0, dx), min(FRAME, FRAME + dx)
    y0s, y1s = max(0, dy), min(FRAME, FRAME + dy)
    x0d, x1d = max(0, -dx), min(FRAME, FRAME - dx)
    y0d, y1d = max(0, -dy), min(FRAME, FRAME - dy)
    out[y0s:y1s, x0s:x1s] = rgba[y0d:y1d, x0d:x1d]
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    mask = load_mask()
    raw = np.asarray(Image.open(SRC / "agent_s.png").convert("RGBA")).copy()
    solid = raw[..., 3] >= SOLID
    # Drop the baked soft drop-shadow: each segment carries its own slice and,
    # stacked, sub-solid shadow makes bright halos. Segments are pure cog shell.
    base = raw.copy()
    base[..., 3] = np.where(solid, raw[..., 3], 0).astype(np.uint8)

    solidf = solid.astype(np.float32)
    # Region masks.
    head_m = box(HEAD_X0, HEAD_X1, HEAD_Y0, HEAD_Y1) & solid
    arm_l_m = box(ARM_L_X0, ARM_L_X1, ARM_Y0, ARM_Y1) & solid & ~head_m
    arm_r_m = box(ARM_R_X0, ARM_R_X1, ARM_Y0, ARM_Y1) & solid & ~head_m
    reg_l = box(LEG_L_LO, LEG_L_HI, HIP_LINE_Y, FRAME) & solid
    reg_r = box(LEG_R_LO, LEG_R_HI, HIP_LINE_Y, FRAME) & solid
    wl = ellipse_soft(WHEEL_FL) * reg_l
    wr = ellipse_soft(WHEEL_FR) * reg_r
    strut_l = np.clip(reg_l.astype(np.float32) - wl, 0, 1)
    strut_r = np.clip(reg_r.astype(np.float32) - wr, 0, 1)

    # The head segment takes the remaining solid pixels the others didn't (the
    # body shell), so the head — drawn last — covers the hub/leg-joins (no
    # head-hole). BUT it must NOT keep the two central leg-struts that hang below
    # the visor: the head tracks AIM, so those struts would always point forward
    # like two thin parallel prongs. The trike already has 3 dedicated
    # movement-legs + 3 wheels for the undercarriage, so we DROP the head's
    # center struts (the narrow x-band below the visor) — the head becomes a clean
    # turret (cube + visor + smile) that swivels alone.
    center_strut = box(HEAD_CENTER_X0, HEAD_CENTER_X1, HEAD_STRUT_CUT_Y, FRAME) \
        & solid
    taken = np.clip(head_m.astype(np.float32) + arm_l_m + arm_r_m
                    + reg_l.astype(np.float32) + reg_r.astype(np.float32), 0, 1)
    head_f = np.clip(solidf - (arm_l_m.astype(np.float32) + arm_r_m
                     + reg_l.astype(np.float32) + reg_r.astype(np.float32)
                     + center_strut.astype(np.float32)), 0, 1)

    # Rear leg+wheel = a real front leg, recentred under the rear hip, then
    # ROTATED 180° ABOUT THE HUB so it points to the REAR (behind the body,
    # north/up in the south frame) instead of forward between the front legs.
    # A rear pivot wheel casters opposite the fronts, which only reads correctly
    # when the wheel actually sits at the BACK — hence the flip.
    front_axle = (HIP_REAR[0], HIP_REAR[1] + REAR_FOOT_LEN)  # pre-flip foot spot
    dx = int(round(front_axle[0] - WHEEL_FR["cx"]))
    dy = int(round(front_axle[1] - WHEEL_FR["cy"]))
    rdx = int(round(HIP_REAR[0] - HIP_FR[0]))
    rdy = int(round(HIP_REAR[1] - HIP_FR[1]))
    # 180° about the hub maps a point p -> 2*hub - p.
    rear_hip = (2 * HUB[0] - HIP_REAR[0], 2 * HUB[1] - HIP_REAR[1])
    rear_axle = (2 * HUB[0] - front_axle[0], 2 * HUB[1] - front_axle[1])

    def rot180_about_hub(arr):
        """Rotate a full-frame RGBA array 180° about the HUB (keeps 192 canvas)."""
        im = Image.fromarray(arr)
        return np.asarray(im.rotate(180, resample=Image.NEAREST, center=HUB,
                                    expand=False))

    for team_name, team_rgb in (
            ("red", RED), ("blue", BLUE),
            ("green", GREEN), ("yellow", YELLOW)):
        d = OUT / team_name
        d.mkdir(parents=True, exist_ok=True)
        T = lambda f: tint(apply_alpha(base, f), team_rgb, mask)
        segs = {
            "head": T(head_f),
            "arm_l": T(arm_l_m.astype(np.float32)),
            "arm_r": T(arm_r_m.astype(np.float32)),
            "leg_fl": T(strut_l),
            "leg_fr": T(strut_r),
            "wheel_l": T(wl),
            "wheel_r": T(wr),
            "leg_rear": rot180_about_hub(shift(T(strut_r), rdx, rdy)),
            "wheel_rear": rot180_about_hub(shift(T(wr), dx, dy)),
        }
        for name, arr in segs.items():
            Image.fromarray(arr).save(d / f"{name}.png")

    anchors = dict(
        frame=FRAME, hub=HUB,
        anchor=dict(
            head=HUB, arm_l=ARM_L_BONE, arm_r=ARM_R_BONE,
            leg_fl=HIP_FL, leg_fr=HIP_FR, leg_rear=list(rear_hip),
            wheel_l=list(AXLE_FL), wheel_r=list(AXLE_FR),
            wheel_rear=list(rear_axle),
        ),
        hip=dict(fl=HIP_FL, fr=HIP_FR, rear=list(rear_hip)),
        axle=dict(fl=list(AXLE_FL), fr=list(AXLE_FR), rear=list(rear_axle)),
        _note="frame-space (192px agent_s). head+arms rotate to AIM about hub; "
              "legs rotate to MOVEMENT about their hip; wheels caster about axle. "
              "The rear leg+wheel are flipped 180° about the hub to sit at the "
              "BACK. Segments recompose to the south master at rest.")
    (OUT / "anchors.json").write_text(json.dumps(anchors, indent=2))

    # preview sheet
    def checker(w, h, s=8):
        img = Image.new("RGBA", (w, h))
        dd = ImageDraw.Draw(img)
        for y in range(0, h, s):
            for x in range(0, w, s):
                c = (205, 205, 205, 255) if ((x//s+y//s) % 2 == 0) \
                    else (165, 165, 165, 255)
                dd.rectangle([x, y, x+s, y+s], fill=c)
        return img
    names = ["head", "arm_l", "arm_r", "leg_fl", "leg_fr", "leg_rear",
             "wheel_l", "wheel_r", "wheel_rear"]
    cell = 175
    sheet = checker(cell * len(names), cell + 30)
    dd = ImageDraw.Draw(sheet)
    for i, n in enumerate(names):
        im = Image.open(OUT / "blue" / f"{n}.png").convert("RGBA")
        arr = np.array(im)
        ys, xs = np.where(arr[..., 3] > 10)
        if len(xs):
            im = im.crop((xs.min()-2, ys.min()-2, xs.max()+3, ys.max()+3))
        im = im.resize((im.width*3, im.height*3), Image.NEAREST)
        if im.width > cell-10 or im.height > cell-10:
            im.thumbnail((cell-10, cell-10), Image.NEAREST)
        sheet.alpha_composite(im, (i*cell+5, 25+(cell-im.height)//2))
        dd.text((i*cell+5, 4), n, fill=(0, 0, 0, 255))
    sheet.convert("RGB").save("/tmp/cvc_rig_segments.png")
    print("segments ->", OUT, "\npreview /tmp/cvc_rig_segments.png")


if __name__ == "__main__":
    main()
