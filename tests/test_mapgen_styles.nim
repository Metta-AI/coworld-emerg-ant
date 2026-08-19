## Unit + integration tests for the mapkit terrain-style generators.
##
## Fairness itself is the sim's job (symmetry + carve + validators); these
## tests prove the generators are deterministic, stay inside their placement
## band, round-trip through mapSpec, and CAN produce maps the real validator
## accepts.

import
  std/unittest,
  ctf/[sim, mapgen_styles]

const styles = [styleBsp, styleCaves, styleMaze, styleScatter]

proc sampleRegion(): MapRect =
  MapRect(x: 64, y: 64, w: 420, h: 520)

proc withinBounds(shapes: seq[ArenaShape], region: MapRect): bool =
  for s in shapes:
    case s.kind
    of shapeRect:
      if s.rect.x < region.x or s.rect.y < region.y: return false
      if s.rect.x + s.rect.w > region.x + region.w: return false
      if s.rect.y + s.rect.h > region.y + region.h: return false
    of shapeDisc, shapeDiamond:
      if s.cx - s.radius < region.x or s.cy - s.radius < region.y: return false
      if s.cx + s.radius > region.x + region.w: return false
      if s.cy + s.radius > region.y + region.h: return false
    of shapeDiagonal:
      discard
    of shapePolygon:
      for p in s.points:
        if p.x < region.x or p.y < region.y or
            p.x > region.x + region.w or p.y > region.y + region.h:
          return false
  true

proc testRegion(base: CtfMap): MapRect =
  ## Mirrors mapkit.placementRegion (kept local to avoid a pixie dependency
  ## in the test binary via tools/map_render).
  const
    vMargin = 2
    hMargin = 40
    seam = 20
  let halfW = base.width div 2
  case base.symmetry
  of symNone:
    ## Full-board: no seam. Span the whole width inset by hMargin off both home
    ## borders — mirrors mapkit.placementRegion's symNone arm. (Generated maps
    ## are never symNone, so this test path is not exercised at runtime; the arm
    ## exists for exhaustiveness and matches the tool it mirrors.)
    MapRect(x: hMargin, y: vMargin,
            w: base.width - 2 * hMargin, h: base.height - 2 * vMargin)
  of symMirror, symRot180:
    MapRect(x: hMargin, y: vMargin,
            w: halfW - hMargin - seam, h: base.height - 2 * vMargin)
  of symRot90, symQuadMirror:
    MapRect(x: hMargin, y: vMargin,
            w: halfW - hMargin - seam, h: base.height div 2 - vMargin - seam)

suite "mapgen styles":
  test "parseStyle round-trips the names":
    check parseStyle("bsp") == styleBsp
    check parseStyle("caves") == styleCaves
    check parseStyle("maze") == styleMaze
    check parseStyle("scatter") == styleScatter
    expect ValueError:
      discard parseStyle("nope")

  test "deterministic for a fixed seed":
    let region = sampleRegion()
    for style in styles:
      let
        a = generateShapes(style, 12345, region, defaultParams(style))
        b = generateShapes(style, 12345, region, defaultParams(style))
      check a == b
      check a.len > 0

  test "different seeds give different layouts":
    let region = sampleRegion()
    for style in styles:
      let
        a = generateShapes(style, 1, region, defaultParams(style))
        b = generateShapes(style, 2, region, defaultParams(style))
      check a != b

  test "every shape stays inside the placement region":
    let region = sampleRegion()
    for style in styles:
      for seed in 1 .. 20:
        let shapes = generateShapes(style, seed, region, defaultParams(style))
        check shapes.len > 0
        check withinBounds(shapes, region)

  test "spec round-trips the generated obstacle set":
    var base = generateMapAttempt(
      7, MapGenOverrides(size: "standard", windows: -1, pits: 0, pitDensity: -1))
    base.leftObstacles =
      generateShapes(styleCaves, 7, testRegion(base), defaultParams(styleCaves))
    let rt = mapFromSpecJson(mapSpecJson(base))
    check rt.leftObstacles.len == base.leftObstacles.len
    check buildArenaObstacles(rt).len > 0

  test "each style can produce a map the validator accepts":
    for style in styles:
      var passed = 0
      for seed in 1 .. 16:
        var base = generateMapAttempt(
          seed,
          MapGenOverrides(size: "standard", windows: -1, pits: 0, pitDensity: -1))
        base.leftObstacles =
          generateShapes(style, seed xor 0x9E3779B1, testRegion(base),
                         defaultParams(style))
        if validateGeneratedMap(base).len == 0:
          inc passed
      check passed >= 1

suite "polygon obstacles":
  test "pointInPolygon matches a known square":
    let sq = @[MapPoint(x: 100, y: 100), MapPoint(x: 200, y: 100),
               MapPoint(x: 200, y: 200), MapPoint(x: 100, y: 200)]
    check pointInPolygon(150, 150, sq)
    check pointInPolygon(101, 101, sq)
    check not pointInPolygon(50, 150, sq)
    check not pointInPolygon(250, 150, sq)
    check not pointInPolygon(150, 250, sq)

  test "a polygon obstacle builds an exactly mirror-symmetric wall set":
    ## The fairness invariant: integer vertex transforms make a polygon and its
    ## image rasterize to bit-identical mirror masks (no boundary drift).
    var base = generateMapAttempt(5, MapGenOverrides(
      size: "standard", symmetry: "mirror", windows: -1, pits: 0, pitDensity: -1))
    base.leftObstacles = @[ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 210, y: 150), MapPoint(x: 268, y: 172),
      MapPoint(x: 252, y: 262), MapPoint(x: 188, y: 250),
      MapPoint(x: 172, y: 198)])]
    let obstacles = buildArenaObstacles(base)
    var sawWall = false
    var y = 30
    while y < base.height - 30:
      var x = 30
      while x < base.width - 30:
        let inside = mapWallAt(base, obstacles, x, y)
        check inside == mapWallAt(base, obstacles, base.width - 1 - x, y)
        if inside: sawWall = true
        x += 9
      y += 9
    check sawWall

  test "a polygon obstacle round-trips through mapSpec":
    var base = generateMapAttempt(
      5, MapGenOverrides(size: "standard", windows: -1, pits: 0, pitDensity: -1))
    let poly = ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 210, y: 150), MapPoint(x: 268, y: 172),
      MapPoint(x: 252, y: 262), MapPoint(x: 188, y: 250)])
    base.leftObstacles = @[poly]
    base.trenches = @[poly]  # trenches are shapes too now
    let rt = mapFromSpecJson(mapSpecJson(base))
    check rt.leftObstacles == @[poly]
    check rt.trenches == @[poly]
