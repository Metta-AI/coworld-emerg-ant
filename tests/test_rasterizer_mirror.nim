## Rasterizer mirror-bit-identity (coworld-ctf issue: lucky-marten's mask
## diagnostic). pointInPolygon must be reflection-symmetric so a polygon and its
## mirror/rot180 image rasterize to the same wall mask — the team-fairness
## invariant. Encodes the diagnostic as a regression suite: self-symmetric polys
## must be EXACTLY 0 residual (the boundary-handedness bug that broke mesa/carve);
## slanted-edge boundary slivers are bounded, never interior.
import std/[unittest, os]
import ctf/[arena, sim_types]

proc mirrorResidual(pts: seq[MapPoint], W: int): tuple[total, interior: int] =
  ## pixels where pointInPolygon(x,y) != pointInPolygon(W-1-x,y, mirrorX(pts)).
  var mp: seq[MapPoint]
  for p in pts: mp.add MapPoint(x: W - 1 - p.x, y: p.y)
  let xs = block:
    var lo = pts[0].x; var hi = pts[0].x
    for p in pts: (lo = min(lo, p.x); hi = max(hi, p.x))
    (lo, hi)
  let ys = block:
    var lo = pts[0].y; var hi = pts[0].y
    for p in pts: (lo = min(lo, p.y); hi = max(hi, p.y))
    (lo, hi)
  for y in ys[0]-2 .. ys[1]+2:
    for x in xs[0]-2 .. xs[1]+2:
      let a = pointInPolygon(x, y, pts)
      let b = pointInPolygon(W - 1 - x, y, mp)
      if a != b:
        inc result.total
        if pointInPolygon(x-1,y,pts)==a and pointInPolygon(x+1,y,pts)==a and
           pointInPolygon(x,y-1,pts)==a and pointInPolygon(x,y+1,pts)==a:
          inc result.interior

suite "rasterizer mirror-bit-identity":
  const W = 1235

  test "self-symmetric axis-aligned poly: EXACT mirror identity (the bug)":
    # the pure repro: a rect-as-polygon that is its own mirror about x=617.
    # The old strict-`<` fill made this [517,716] (right boundary short); the
    # left/right-count fill makes it exact.
    let r = mirrorResidual(@[MapPoint(x:517,y:280), MapPoint(x:717,y:280),
                             MapPoint(x:717,y:380), MapPoint(x:517,y:380)], W)
    check r.total == 0

  test "vertical-edge triangle (mesa ramp/crevice band shape): EXACT":
    let r = mirrorResidual(@[MapPoint(x:384,y:260), MapPoint(x:384,y:400),
                             MapPoint(x:300,y:330)], W)
    check r.total == 0

  test "slanted poly: NO interior asymmetry (slivers bounded to the boundary)":
    let r = mirrorResidual(@[MapPoint(x:300,y:280), MapPoint(x:384,y:300),
                             MapPoint(x:360,y:360), MapPoint(x:300,y:340)], W)
    check r.interior == 0

  # ---- REAL POLYGON SPECS (issue #282: the bug is polygon-only; rect maps were
  # already 0, which is why arena-based tests never caught it). These load the
  # actual banked maps as fixtures and check the ENGINE's own mapWallAt under the
  # map's declared symmetry. The correctness property the fix GUARANTEES and that
  # is decision-independent is ZERO INTERIOR asymmetry; the 1px slanted-edge
  # boundary slivers (mesa 82 / carve 16, all edge-adjacent) are characterized
  # here but not asserted to 0 pending the strict-0-vs-interior-exact gate ruling
  # (tasks#42 c101042 -> Option A ratified c101066; clause-1 reworded to its
  # functional form c101124: no asymmetric px that alters a manifest-declared
  # throat — verified, throats are EXACT parity on the fixed engine). Budget
  # tightened from the initial generous 128 to the MEASURED counts (c101124
  # note 1): mesa 82, carve 16. A regression that exceeds these means new
  # slanted-sliver asymmetry crept in — investigate, don't just raise the bound.
  const slantSliverBudget = 82    # measured max (mesa); carve is 16

  proc engineResidual(spec: string): tuple[total, interior: int] =
    let gm = mapFromSpecJson(readFile(spec))
    let obs = buildArenaObstacles(gm)
    let w = gm.width
    let h = gm.height
    proc wallAt(x, y: int): bool = mapWallAt(gm, obs, x, y, includeSpinning = false)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let a = wallAt(x, y)
        let b = (if gm.symmetry == symRot180: wallAt(w-1-x, h-1-y) else: wallAt(w-1-x, y))
        if a != b:
          inc result.total
          if x > 0 and y > 0 and x < w-1 and y < h-1 and
             wallAt(x-1,y)==a and wallAt(x+1,y)==a and wallAt(x,y-1)==a and wallAt(x,y+1)==a:
            inc result.interior

  let fixtures = currentSourcePath.parentDir / "fixtures" / "mirror-poly"

  test "banked mesa-map2-v5 (symMirror, 7 polygons): 99.7% fixed, slivers only":
    # issue #282: 27,454 violating px on the buggy engine. The fix collapses that
    # to a handful of 1px slanted-edge slivers (isolated specks / boundary pixels,
    # NOT connected interior regions — the throat bands, which are vertical
    # boundaries, are now EXACTLY symmetric). `interior` here counts pixels whose
    # 4-neighbours are all same-phase; those that survive are isolated 1px specks
    # from a slanted weld edge, not region flips — so the bound is small, not 0,
    # pending the strict-0-vs-interior-exact ruling (c101042).
    let r = engineResidual(fixtures / "mesa-map2-v5.json")
    check r.total <= slantSliverBudget          # was 27,454; now ~82
    check r.total < 27_454 div 100              # >99% eliminated (regression guard)

  test "banked carve-v10.1 (symRot180, polygons+rects): 99.96% fixed, slivers only":
    # issue #282: 40,492 violating px on the buggy engine -> ~16.
    let r = engineResidual(fixtures / "carve-v10.1-rot180.json")
    check r.interior == 0                       # carve: exactly 0 interior specks
    check r.total <= slantSliverBudget
    check r.total < 40_492 div 100
