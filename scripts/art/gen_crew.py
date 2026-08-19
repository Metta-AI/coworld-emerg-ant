#!/usr/bin/env python3
"""Hand-pixel the CTF crew sprite sheet: a purpose-built TOP-DOWN trooper that
replaces the reused astronaut cells (ux.replay art direction #2).

Painterly gen art turns to mush at a 16px footprint, so — like the flag banner —
the actor is authored pixel-by-pixel to the crew tint contract the renderer
already speaks (bitworld crewPixel*):
  • EXACT white  (255,255,255) → the player's team color   (tint marker)
  • EXACT (155,173,183)        → the team color's shade      (shade marker)
  • anything else              → drawn literally (helmet, outline, rim)
  • alpha < 20                 → transparent

DESIGN (revised after review):
  • NO WEAPON on the body. The directional weapon is the game's separate aim
    indicator (the dots that ride out in front of each unit, showing rotation).
    A gun baked into the sprite read as a SECOND gun — and worse, it could only
    point left/right (flipH) while the aim dots point in the true 360° heading,
    so the two visibly disagreed. One gun, one source of truth.
  • LEFT-RIGHT SYMMETRIC. With no weapon there is no "facing" to carry, so the
    trooper is mirror-symmetric; the renderer's flipH then does nothing visible
    and can never spawn a phantom gun / offset backpack on the wrong side.
  • Reads as a trooper from directly ABOVE: a helmet dome crown at center, broad
    team-colored shoulder pauldrons (the widest, dominant mass = team color per
    research #1), a tapering torso, a centered vest seam for structure, and two
    small boot nubs. A 1px warm near-black outline floats it off the floor and
    an ember rim light catches the helmet crown (torch-lit dungeon).

Output: data/crew.png — one row of 8 cells, 16x16 each (128x16). Cells share the
one trooper with a small SYMMETRIC per-variant chest/helmet accent so a squad
reads as individuals without breaking the single designed silhouette.

Usage: python3 scripts/art/gen_crew.py
"""
from pathlib import Path

from PIL import Image

CELL = 16
VARIANTS = 8

# Literal (non-marker) colors.
CLEAR = (0, 0, 0, 0)
OUTLINE = (26, 22, 18, 255)      # warm near-black ink, not pure #000
TINT = (255, 255, 255, 255)      # → team color   (marker)
SHADE = (155, 173, 183, 255)     # → team shade    (marker)
HELM = (92, 96, 92, 255)         # neutral tactical gray-green
HELM_HI = (150, 156, 148, 255)   # helmet crown highlight
HELM_LO = (58, 62, 60, 255)      # helmet shadow ring / visor lip
RIM = (255, 163, 0, 255)         # ember rim light (palette idx 7)
BAND = [                          # per-variant chest/helmet accent (symmetric)
    (176, 84, 56, 255), (96, 132, 120, 255), (150, 120, 70, 255),
    (120, 108, 140, 255), (170, 150, 90, 255), (90, 140, 150, 255),
    (150, 90, 110, 255), (110, 130, 90, 255),
]

CX = 7.5   # cell center x between the two center columns → symmetric halves


def disc(cx, cy, r):
    """Yields integer (x,y) inside a filled disc of radius r."""
    r2 = r * r
    for y in range(CELL):
        for x in range(CELL):
            dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= r2:
                yield x, y


def paint_trooper(variant):
    """Returns a 16x16 RGBA pixel grid for one symmetric top-down trooper."""
    px = [[CLEAR] * CELL for _ in range(CELL)]

    def put(x, y, c):
        if 0 <= x < CELL and 0 <= y < CELL:
            px[y][x] = c

    accent = BAND[variant % len(BAND)]

    # --- Body: shoulder-dominant, rounded team-colored mass (NOT a taper) ---
    # A top-down trooper is widest at the shoulder line and stays a rounded body
    # below — never a downward point (a taper read as a ribcage/mandible). Per
    # row, a symmetric half-width about the center gives clean rounded edges.
    #   y :  8   9  10  11  12  13
    #  hw :  5   5   5   4   4   3
    body_halfwidth = {8: 5, 9: 5, 10: 5, 11: 4, 12: 4, 13: 3}
    for y, hw in body_halfwidth.items():
        for x in range(CELL):
            if abs(x - CX) <= hw:      # symmetric about the center seam
                put(x, y, TINT)
    # Round the four body corners so the mass reads organic, not a brick.
    for (bx, by) in [(3, 8), (12, 8), (4, 13), (11, 13)]:
        put(bx, by, CLEAR)

    # Keep the torso a SOLID team-color mass (dominant, unbroken). Structure it
    # with a single thin dark collar line just under the helmet — a horizontal
    # neck seam, NOT a vertical stripe (a center stripe punched a hole through
    # the body and made the team color read as a horseshoe).
    for x in range(5, 11):
        if px[9][x] == TINT:
            put(x, 9, SHADE)
    # Symmetric per-variant collar accent, 2px centered on the seam.
    put(7, 9, accent)
    put(8, 9, accent)

    # Grounding shade: the lowest team-color pixel of each column drops to shade
    # so the body seats on the floor instead of floating (a thin 1px underline).
    for x in range(CELL):
        col = [y for y in range(CELL) if px[y][x] == TINT]
        if col:
            put(x, max(col), SHADE)
    # Two small symmetric boot nubs poking out the front (toward the viewer).
    put(6, 14, SHADE)
    put(9, 14, SHADE)

    # --- Helmet: a domed crown seen from above, centered over the shoulders ---
    for x, y in disc(CX, 5.4, 3.1):
        put(x, y, HELM)
    for x, y in disc(CX, 4.9, 1.9):
        put(x, y, HELM_HI)
    # Visor / brow shadow line where the helmet meets the shoulders.
    for x in range(5, 11):
        if px[7][x] == HELM:
            put(x, 7, HELM_LO)
    # A centered front-to-back helmet ridge (symmetric) for a per-variant tint.
    for y in range(3, 7):
        if px[y][7] in (HELM, HELM_HI):
            put(7, y, accent)
        if px[y][8] in (HELM, HELM_HI):
            put(8, y, accent)

    # --- Ember rim light: the topmost solid helmet pixel of each column glows ---
    for x in range(CELL):
        for y in range(CELL):
            if px[y][x] != CLEAR:
                if y <= 5 and px[y][x] in (HELM, HELM_HI, accent):
                    px[y][x] = RIM
                break

    # --- 1px warm outline: any empty pixel 4-adjacent to a solid one ---
    solid = [[px[y][x] != CLEAR for x in range(CELL)] for y in range(CELL)]
    for y in range(CELL):
        for x in range(CELL):
            if solid[y][x]:
                continue
            near = ((x > 0 and solid[y][x - 1]) or
                    (x < CELL - 1 and solid[y][x + 1]) or
                    (y > 0 and solid[y - 1][x]) or
                    (y < CELL - 1 and solid[y + 1][x]))
            if near:
                px[y][x] = OUTLINE
    return px


def main():
    sheet = Image.new("RGBA", (CELL * VARIANTS, CELL), CLEAR)
    for v in range(VARIANTS):
        grid = paint_trooper(v)
        for y in range(CELL):
            for x in range(CELL):
                sheet.putpixel((v * CELL + x, y), grid[y][x])
    out = Path(__file__).resolve().parents[2] / "data" / "crew.png"
    sheet.save(out)
    # A zoomed preview for eyeballing.
    prev = sheet.resize((sheet.width * 12, sheet.height * 12), Image.NEAREST)
    prev.save(Path("/tmp/crew_preview.png"))
    print(f"wrote {out}  ({sheet.width}x{sheet.height}, {VARIANTS} cells)")
    print("preview /tmp/crew_preview.png")


if __name__ == "__main__":
    main()
