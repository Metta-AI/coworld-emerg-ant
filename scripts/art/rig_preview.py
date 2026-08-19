#!/usr/bin/env python3
"""Reference compositor for the TURRET-style real-cog rig — the spec the Nim
port must reproduce. Head+arms face AIM; legs face MOVEMENT (bodyHeading) and the
INNER leg shortens on a turn; wheels caster toward travel; arms extend only when
carrying; heart cradled perpendicular between head and arms.

  /tmp/cvc_rig_poses.png   motion montage
  /tmp/cvc_rig_rest.png    rest vs original master
"""
from pathlib import Path
import json
import math
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
RIG = ROOT / "data" / "rig_real"
A = json.loads((RIG / "anchors.json").read_text())
TEAM = "blue"
FRAME = A["frame"]
HUB = tuple(A["hub"])
ANC = {k: tuple(v) for k, v in A["anchor"].items()}
HIP = {k: tuple(v) for k, v in A["hip"].items()}
AXLE = {k: tuple(v) for k, v in A["axle"].items()}
IMG = {n: Image.open(RIG / TEAM / f"{n}.png").convert("RGBA") for n in ANC}
HEART = Image.open(ROOT / "data" / "heart_blue.png").convert("RGBA")

# feel
REST_TUCK = 6.0        # deg: front legs tuck slightly inward at rest
SPLAY = 20.0           # deg: outer leg swings out into a turn (kept modest)
INNER_SHORTEN = 0.32   # inner leg shrinks up to this fraction on a full turn


def rot_about(img, pivot, deg):
    return img.rotate(deg, resample=Image.BICUBIC, expand=False, center=pivot)


def scale_about(img, pivot, sx, sy):
    """Scale img about a pivot point, same canvas size."""
    px, py = pivot
    # affine: translate pivot->origin, scale, translate back. PIL transform uses
    # inverse mapping (dst->src).
    inv = (1.0/sx, 0, px - px/sx, 0, 1.0/sy, py - py/sy)
    return img.transform(img.size, Image.AFFINE, inv, resample=Image.BICUBIC)


def rot_pt(px, py, cx, cy, deg):
    t = math.radians(deg)
    dx, dy = px - cx, py - cy
    return (cx + dx*math.cos(-t) - dy*math.sin(-t),
            cy + dx*math.sin(-t) + dy*math.cos(-t))


def compose(aim_deg, move_deg, turn, carrying=False):
    """aim/move screen degrees (0=east, CCW+); turn in [-1,1] (+ = left/CCW)."""
    base = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    aim_delta = aim_deg - 90.0          # south-facing art -> +x = aim
    head_layer = lambda name, extra=0.0: rot_about(IMG[name], HUB, aim_delta+extra)

    # --- legs stay roughly UNDER the body; only the WHEELS caster to travel ---
    # The whole leg-base does NOT swing to the travel heading (that made a strafe
    # rotate the base 90° = spidery). Instead the base holds near the aim/heading
    # and the differential swing + inner-leg shorten express the turn; the wheels
    # caster to the true travel direction so the motion still reads.
    BASE_FOLLOW = 0.0          # base rotation follows aim (legs sit under body).
    move_delta = aim_delta * (1.0 - BASE_FOLLOW) + (move_deg - 90.0) * BASE_FOLLOW
    swing = {"leg_fl": -REST_TUCK + turn*SPLAY,
             "leg_fr":  REST_TUCK + turn*SPLAY,
             "leg_rear": -turn*(SPLAY*0.5)}
    # inner leg (the one on the turn side) shortens. +turn=left -> left is inner.
    shorten = {"leg_fl": 1.0 - max(0.0, turn)*INNER_SHORTEN,
               "leg_fr": 1.0 - max(0.0, -turn)*INNER_SHORTEN,
               "leg_rear": 1.0}
    # wheels caster to travel RELATIVE to the base heading, capped TIGHT: a tall
    # top-down tire swept even 45° reads as a splayed ski, so we only let it TILT
    # ~22° to hint the roll direction while staying a wheel under the body.
    CASTER_CAP = 22.0
    rel = ((move_deg - aim_deg + 180) % 360) - 180   # travel vs aim, [-180,180]
    caster = max(-CASTER_CAP, min(CASTER_CAP, rel))

    def limb_layer(items):
        layer = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
        for kind, name in items:
            if kind == "leg":
                hip = HIP[{"leg_fl": "fl", "leg_fr": "fr", "leg_rear": "rear"}[name]]
                im = IMG[name]
                # shorten along hip->down axis (scale y about the hip)
                s = shorten[name]
                if s < 0.999:
                    im = scale_about(im, hip, 1.0, s)
                im = rot_about(im, hip, swing[name])
            else:  # wheel
                axle = AXLE[{"wheel_l": "fl", "wheel_r": "fr", "wheel_rear": "rear"}[name]]
                im = rot_about(IMG[name], axle, caster)
            layer.alpha_composite(im)
        return rot_about(layer, HUB, move_delta)

    # z: rear wheel/leg (behind), front wheels, front legs, head, [heart], arms
    base.alpha_composite(limb_layer([("wheel", "wheel_rear"), ("leg", "leg_rear")]))
    base.alpha_composite(limb_layer([("wheel", "wheel_l"), ("wheel", "wheel_r")]))
    base.alpha_composite(limb_layer([("leg", "leg_fl"), ("leg", "leg_fr")]))
    base.alpha_composite(head_layer("head"))
    if carrying:
        # heart cradled OUT FRONT along aim (well beyond the visor), perpendicular
        # (rotate so the pointed end faces to the side), between head and arms.
        h = HEART.copy()
        hs = 26
        h.thumbnail((hs, hs), Image.LANCZOS)
        h = h.rotate(90 - aim_deg, expand=True)   # point faces sideways to aim
        fwd = 30.0                                 # forward of the hub, past the face
        ax = math.cos(math.radians(-aim_deg)) * fwd
        ay = math.sin(math.radians(-aim_deg)) * fwd
        cx, cy = HUB[0]+ax, HUB[1]+ay
        base.alpha_composite(h, (int(cx-h.width/2), int(cy-h.height/2)))
    # arms: tucked when idle, extended forward when carrying
    arm_extra = 0.0
    if carrying:
        arm_extra = 0.0  # (art already reaches; extension is a pose swap later)
    base.alpha_composite(head_layer("arm_l", arm_extra))
    base.alpha_composite(head_layer("arm_r", arm_extra))
    return base


def crop_content(im, pad=3):
    a = np.array(im)
    ys, xs = np.where(a[..., 3] > 10)
    if not len(xs):
        return im
    return im.crop((xs.min()-pad, ys.min()-pad, xs.max()+pad, ys.max()+pad))


def checker(w, h, s=10):
    img = Image.new("RGBA", (w, h))
    dd = ImageDraw.Draw(img)
    for y in range(0, h, s):
        for x in range(0, w, s):
            c = (218, 214, 205, 255) if ((x//s+y//s) % 2 == 0) else (198, 194, 185, 255)
            dd.rectangle([x, y, x+s, y+s], fill=c)
    return img


def main():
    poses = [
        ("rest\naim S", 90, 90, 0.0, False),
        ("drive S", 90, 90, 0.0, False),
        ("strafe E\naim S", 90, 0, 0.0, False),
        ("turn L\nmove SE", 90, 45, 1.0, False),
        ("turn R\nmove SW", 90, 135, -1.0, False),
        ("aim E\nmove S (turret)", 0, 90, 0.3, False),
        ("carry\naim S", 90, 90, 0.0, True),
    ]
    cell = 250
    sheet = checker(cell*len(poses), cell+40)
    dd = ImageDraw.Draw(sheet)
    for i, (lbl, aim, mv, turn, carry) in enumerate(poses):
        c = crop_content(compose(aim, mv, turn, carry))
        f = 2
        c = c.resize((c.width*f, c.height*f), Image.NEAREST)
        if c.width > cell-8 or c.height > cell-20:
            c.thumbnail((cell-8, cell-20), Image.LANCZOS)
        sheet.alpha_composite(c, (i*cell+(cell-c.width)//2, 40))
        for j, line in enumerate(lbl.split("\n")):
            dd.text((i*cell+6, 4+j*14), line, fill=(20, 20, 20, 255))
    sheet.convert("RGB").save("/tmp/cvc_rig_poses.png")

    rest = crop_content(compose(90, 90, 0.0))
    orig = Image.open(ROOT / "data" / "soldier_blue.png").convert("RGBA")
    f = 4
    R = rest.resize((rest.width*f, rest.height*f), Image.NEAREST)
    O = orig.resize((orig.width*f, orig.height*f), Image.NEAREST)
    H = max(R.height, O.height)+40
    comp = Image.new("RGBA", (R.width+O.width+60, H), (220, 216, 207, 255))
    d2 = ImageDraw.Draw(comp)
    comp.alpha_composite(R, (10, 30+(H-40-R.height)//2)); d2.text((10, 8), "RIGGED REST", fill=(0, 0, 0, 255))
    comp.alpha_composite(O, (R.width+40, 30+(H-40-O.height)//2)); d2.text((R.width+40, 8), "ORIGINAL", fill=(0, 0, 0, 255))
    comp.convert("RGB").save("/tmp/cvc_rig_rest.png")
    print("poses /tmp/cvc_rig_poses.png ; rest /tmp/cvc_rig_rest.png")


if __name__ == "__main__":
    main()
