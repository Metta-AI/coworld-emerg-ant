## Pure map rasterization shared by the pool review and local map editor.
## Demo/curation tooling; not part of the server.
##
## Every geometry query is made against the supplied CtfMap. This module never
## installs a map and never reads the process-wide arena globals: mummy serves
## requests on a thread pool, so concurrent arbitrary-spec renders must not be
## able to replace or observe one another's geometry.
import std/math, pixie, ../src/ctf/sim

const
  FloorColor = rgba(214, 189, 150, 255)
  ZoneColor = rgba(226, 205, 172, 255)
  StoneColor = rgba(64, 48, 34, 255)
  GlassColor = rgba(80, 220, 255, 255)
  RedColor = rgba(210, 60, 50, 255)
  BlueColor = rgba(60, 110, 220, 255)
  GreenColor = rgba(45, 155, 85, 255)
  YellowColor = rgba(220, 175, 35, 255)
  KitColor = rgba(200, 30, 30, 255)
  KitIdleColor = rgba(120, 100, 80, 255)
  GrenadeColor = rgba(235, 145, 35, 255)
  ShieldColor = rgba(70, 120, 225, 255)
  PlasmaArcColor = rgba(180, 70, 210, 255)
  TrenchColor = rgba(120, 96, 62, 255)
  TrenchRimColor = rgba(88, 66, 38, 255)
  PuddleColor = rgba(168, 58, 196, 255)
  PuddleRimColor = rgba(96, 28, 116, 255)
  SpinTint = rgba(235, 150, 40, 110)
  SeedRegionTint = rgba(60, 110, 220, 150)
  SightlineTint = rgba(230, 45, 45, 190)
  ReachabilityTint = rgba(135, 55, 180, 105)

type
  MapOverlay* = enum
    ## Optional server-side annotations understood by the editor API.
    overlayProtected
    overlayPickups
    overlaySpin
    overlaySeedRegion
    overlaySightlines
    overlayReachability

  PickupKind* = enum
    ## Nominal pickup targets the renderer can mark. Shields, plasma arcs and
    ## med kits may be nudged later by SimServer.nearestWalkable at game start.
    pickupGrenade
    pickupShield
    pickupPlasmaArc
    pickupMedKitActive
    pickupMedKitCandidate

  MapRenderOptions* = object
    ## Raster size and overlay selection. maxDimension 0 means native size;
    ## positive values downscale to fit but never upscale the map.
    maxDimension*: int
    overlays*: set[MapOverlay]
    pickupKinds*: set[PickupKind]

  MapRenderResult* = object
    ## The rendered image and the exact spec-pixel to image-pixel scale used.
    image*: Image
    renderScale*: float

const AllPickupKinds* = {
  pickupGrenade,
  pickupShield,
  pickupPlasmaArc,
  pickupMedKitActive,
  pickupMedKitCandidate,
}

proc mapSeedRegion*(gameMap: CtfMap): MapRect =
  ## Returns the authored seed half (2-team) or top-left quadrant (rot90 /
  ## quad-mirror) whose shapes buildArenaObstacles expands into the complete
  ## symmetric obstacle set. Under symNone there is no fundamental domain —
  ## the authored set IS the full board, so the seed region is the whole map.
  case gameMap.symmetry
  of symNone:
    MapRect(x: 0, y: 0, w: gameMap.width, h: gameMap.height)
  of symMirror, symRot180:
    MapRect(x: 0, y: 0, w: gameMap.width div 2, h: gameMap.height)
  of symRot90, symQuadMirror:
    MapRect(
      x: 0, y: 0,
      w: gameMap.width div 2, h: gameMap.height div 2,
    )

proc overTint(base, tint: ColorRGBA): ColorRGBA =
  let alpha = int(tint.a)
  rgba(
    uint8((int(tint.r) * alpha + int(base.r) * (255 - alpha)) div 255),
    uint8((int(tint.g) * alpha + int(base.g) * (255 - alpha)) div 255),
    uint8((int(tint.b) * alpha + int(base.b) * (255 - alpha)) div 255),
    255,
  )

proc renderScale(gameMap: CtfMap, maxDimension: int): float =
  if maxDimension == 0:
    return 1.0
  min(
    1.0,
    float(maxDimension) / float(max(gameMap.width, gameMap.height)),
  )

proc logicalCoordinate(pixel: int, scale: float): float {.inline.} =
  ## Pixel-center mapping chosen so scale 1 samples the exact integer
  ## coordinates used by the legacy pool renderer.
  (float(pixel) + 0.5) / scale - 0.5

proc logicalPixel(pixel, limit: int, scale: float): int {.inline.} =
  clamp(int(round(logicalCoordinate(pixel, scale))), 0, limit - 1)

proc outputCoordinate(value: int, scale: float): int {.inline.} =
  int(round(float(value) * scale))

proc fillDisc(
  image: Image, cx, cy, radius: int, color: ColorRGBA
) =
  for y in max(0, cy - radius) .. min(image.height - 1, cy + radius):
    for x in max(0, cx - radius) .. min(image.width - 1, cx + radius):
      if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius:
        image.unsafe[x, y] = color

proc drawCross(
  image: Image, cx, cy, radius: int, color: ColorRGBA
) =
  for delta in -radius .. radius:
    for thickness in -1 .. 1:
      if cx + delta >= 0 and cx + delta < image.width and
          cy + thickness >= 0 and cy + thickness < image.height:
        image.unsafe[cx + delta, cy + thickness] = color
      if cx + thickness >= 0 and cx + thickness < image.width and
          cy + delta >= 0 and cy + delta < image.height:
        image.unsafe[cx + thickness, cy + delta] = color

proc drawPickupMarker(
  image: Image,
  point: tuple[x, y: int],
  radius: int,
  scale: float,
  color: ColorRGBA,
) =
  image.drawCross(
    outputCoordinate(point.x, scale),
    outputCoordinate(point.y, scale),
    max(1, outputCoordinate(radius, scale)),
    color,
  )

proc drawRectOutline(
  image: Image, rect: MapRect, scale: float, color: ColorRGBA
) =
  let
    x0 = clamp(outputCoordinate(rect.x, scale), 0, image.width - 1)
    y0 = clamp(outputCoordinate(rect.y, scale), 0, image.height - 1)
    x1 = clamp(outputCoordinate(rect.x + rect.w, scale), 0, image.width - 1)
    y1 = clamp(outputCoordinate(rect.y + rect.h, scale), 0, image.height - 1)
  for x in x0 .. x1:
    image.unsafe[x, y0] = color
    image.unsafe[x, y1] = color
  for y in y0 .. y1:
    image.unsafe[x0, y] = color
    image.unsafe[x1, y] = color

proc overlayMask(
  image: Image,
  mask: seq[bool],
  gameMap: CtfMap,
  scale: float,
  color: ColorRGBA,
) =
  for y in 0 ..< image.height:
    let mapY = logicalPixel(y, gameMap.height, scale)
    for x in 0 ..< image.width:
      let mapX = logicalPixel(x, gameMap.width, scale)
      if mask[mapY * gameMap.width + mapX]:
        image.unsafe[x, y] = overTint(image.unsafe[x, y].rgba, color)

proc renderMap*(
  gameMap: CtfMap,
  diagnostics: MapDiagnostics,
  options: MapRenderOptions,
): MapRenderResult =
  ## Renders one map without consulting installed arena globals. Callers that
  ## request reachability must supply diagnostics retaining corridorOpen and
  ## reachable; the overload below requests those artifacts automatically.
  let
    scale = renderScale(gameMap, options.maxDimension)
    outputWidth = int(ceil(float(gameMap.width) * scale))
    outputHeight = int(ceil(float(gameMap.height) * scale))
    obstacles = buildArenaObstacles(gameMap)
    cx = gameMap.center.x
    cy = gameMap.center.y
  result.renderScale = scale
  result.image = newImage(outputWidth, outputHeight)
  var
    wall = newSeq[bool](outputWidth * outputHeight)
    window = newSeq[bool](outputWidth * outputHeight)

  for y in 0 ..< outputHeight:
    let fy = logicalCoordinate(y, scale)
    for x in 0 ..< outputWidth:
      let
        fx = logicalCoordinate(x, scale)
        index = y * outputWidth + x
      if fx < float(ArenaBorder) or fy < float(ArenaBorder) or
          fx >= float(gameMap.width - ArenaBorder) or
          fy >= float(gameMap.height - ArenaBorder):
        wall[index] = true

  for shape in obstacles:
    let
      bounds = shapeBounds(shape)
      x0 = max(0, int(floor(float(bounds.x0) * scale)) - 1)
      y0 = max(0, int(floor(float(bounds.y0) * scale)) - 1)
      x1 = min(outputWidth - 1, int(ceil(float(bounds.x1) * scale)) + 1)
      y1 = min(outputHeight - 1, int(ceil(float(bounds.y1) * scale)) + 1)
    for y in y0 .. y1:
      let fy = logicalCoordinate(y, scale)
      for x in x0 .. x1:
        let
          fx = logicalCoordinate(x, scale)
          index = y * outputWidth + x
        if mapShapeWallAtF(gameMap, fx, fy, shape, cx, cy):
          wall[index] = true
          if shape.window:
            window[index] = true

  for y in 0 ..< outputHeight:
    let
      fy = logicalCoordinate(y, scale)
      mapY = logicalPixel(y, gameMap.height, scale)
    for x in 0 ..< outputWidth:
      let
        fx = logicalCoordinate(x, scale)
        mapX = logicalPixel(x, gameMap.width, scale)
        index = y * outputWidth + x
      var color = FloorColor
      if window[index]:
        color = GlassColor
      elif wall[index]:
        color = StoneColor
      elif overlayProtected in options.overlays and
          (if scale == 1.0:
            mapProtectedFloorAt(gameMap, mapX, mapY)
          else:
            mapProtectedFloorAtF(gameMap, fx, fy, cx, cy)):
        color = ZoneColor
      result.image.unsafe[x, y] = color

  for trench in gameMap.trenches:
    let
      tr = shapeAsRect(trench)
      x0 = max(0, outputCoordinate(tr.x - TrenchArtPadPx, scale))
      y0 = max(0, outputCoordinate(tr.y - TrenchArtPadPx, scale))
      x1 = min(
        outputWidth,
        outputCoordinate(tr.x + tr.w + TrenchArtPadPx, scale),
      )
      y1 = min(
        outputHeight,
        outputCoordinate(tr.y + tr.h + TrenchArtPadPx, scale),
      )
    for y in y0 ..< y1:
      let mapY = logicalPixel(y, gameMap.height, scale)
      for x in x0 ..< x1:
        let
          mapX = logicalPixel(x, gameMap.width, scale)
          # Rect trenches keep the rough-edge art; other kinds fill flat.
          edge =
            if trench.kind == shapeRect: trenchRoughEdge(tr, mapX, mapY)
            elif inShape(mapX, mapY, trench): 5.0
            else: -1.0
          existing = result.image.unsafe[x, y].rgba
        if edge < 0 or existing == StoneColor or existing == GlassColor:
          continue
        result.image.unsafe[x, y] =
          if edge < 3: TrenchRimColor else: TrenchColor

  for puddle in gameMap.puddles:
    ## Paint puddles are organic disc-union splats: the gameplay outline is
    ## the spill itself, drawn in the hazard's violet (rim by union depth)
    ## so previews tell them apart from the brown trenches.
    let
      pr = puddleBounds(puddle)
      x0 = max(0, outputCoordinate(pr.x - 1, scale))
      y0 = max(0, outputCoordinate(pr.y - 1, scale))
      x1 = min(outputWidth, outputCoordinate(pr.x + pr.w + 1, scale))
      y1 = min(outputHeight, outputCoordinate(pr.y + pr.h + 1, scale))
    for y in y0 ..< y1:
      let mapY = logicalPixel(y, gameMap.height, scale)
      for x in x0 ..< x1:
        let mapX = logicalPixel(x, gameMap.width, scale)
        var depth = -1.0
        for s in puddle.spots:
          let
            dx = float(mapX - s.cx)
            dy = float(mapY - s.cy)
          depth = max(depth, float(s.r) - sqrt(dx * dx + dy * dy))
        if depth < 0.0:
          continue
        let existing = result.image.unsafe[x, y].rgba
        if existing == StoneColor or existing == GlassColor:
          continue
        result.image.unsafe[x, y] =
          if depth < 3.0: PuddleRimColor else: PuddleColor

  if overlayReachability in options.overlays:
    var unreachableOpen = newSeq[bool](gameMap.width * gameMap.height)
    for i in 0 ..< unreachableOpen.len:
      unreachableOpen[i] =
        diagnostics.corridorOpen[i] and not diagnostics.reachable[i]
    overlayMask(
      result.image, unreachableOpen, gameMap, scale, ReachabilityTint)

  if overlaySpin in options.overlays:
    for shape in obstacles:
      if not gameMap.isSpinningDiamond(shape):
        continue
      let
        bounds = shapeBounds(shape)
        x0 = max(0, outputCoordinate(bounds.x0, scale))
        y0 = max(0, outputCoordinate(bounds.y0, scale))
        x1 = min(outputWidth - 1, outputCoordinate(bounds.x1, scale))
        y1 = min(outputHeight - 1, outputCoordinate(bounds.y1, scale))
      for y in y0 .. y1:
        let fy = logicalCoordinate(y, scale)
        for x in x0 .. x1:
          let fx = logicalCoordinate(x, scale)
          if inShapeF(fx, fy, shape):
            result.image.unsafe[x, y] =
              overTint(result.image.unsafe[x, y].rgba, SpinTint)

  if overlaySightlines in options.overlays:
    let
      x0 = clamp(
        outputCoordinate(gameMap.sightlineLoX(), scale),
        0,
        outputWidth - 1,
      )
      x1 = clamp(
        outputCoordinate(gameMap.sightlineHiX(), scale),
        0,
        outputWidth - 1,
      )
    for row in diagnostics.openSightlineRows:
      let y = clamp(outputCoordinate(row, scale), 0, outputHeight - 1)
      for x in x0 .. x1:
        result.image.unsafe[x, y] = SightlineTint

  if overlaySeedRegion in options.overlays:
    result.image.drawRectOutline(gameMap.mapSeedRegion(), scale, SeedRegionTint)

  let teamColors = [RedColor, BlueColor, GreenColor, YellowColor]
  for team in gameMap.teams():
    let home = gameMap.flagHome(team)
    result.image.fillDisc(
      outputCoordinate(home.x, scale),
      outputCoordinate(home.y, scale),
      max(1, outputCoordinate(7, scale)),
      teamColors[ord(team)],
    )

  if overlayPickups in options.overlays:
    if pickupMedKitCandidate in options.pickupKinds:
      for point in gameMap.medKitCandidates:
        result.image.drawPickupMarker(
          (point.x, point.y), 6, scale, KitIdleColor)
    if pickupMedKitActive in options.pickupKinds:
      for point in gameMap.medKitSpawns:
        result.image.drawPickupMarker((point.x, point.y), 8, scale, KitColor)
    if pickupGrenade in options.pickupKinds:
      for point in gameMap.grenadeSpawnPoints():
        result.image.drawPickupMarker(point, 6, scale, GrenadeColor)
    if pickupShield in options.pickupKinds:
      for point in gameMap.shieldSpawnPoints():
        result.image.drawPickupMarker(point, 6, scale, ShieldColor)
    if pickupPlasmaArc in options.pickupKinds:
      for point in gameMap.plasmaArcSpawnPoints():
        result.image.drawPickupMarker(point, 6, scale, PlasmaArcColor)

proc renderMap*(
  gameMap: CtfMap,
  options: MapRenderOptions,
): MapRenderResult =
  ## Renders one map and computes only the full-board artifacts required by
  ## the requested overlays.
  var diagnostics: MapDiagnostics
  if overlaySightlines in options.overlays or
      overlayReachability in options.overlays:
    let artifacts =
      if overlayReachability in options.overlays:
        {diagnosticCorridorOpen, diagnosticReachable}
      else:
        {}
    diagnostics = mapDiagnostics(gameMap, artifacts)
  renderMap(gameMap, diagnostics, options)
