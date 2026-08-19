## Broadcast-side art and asset loading: sprite-sheet/crew/relic PNG
## loaders, the HD soldier renderer (soldierRotPixels), the articulated
## turret rig (rig segments, gun, spray can), and the cog driving physics
## (stepCogDrive) — stage 2 of docs/plans/2026-08-01-sim-split.md.
##
## Everything here is BROADCAST-ONLY: no sim state, nothing in gameHash, no
## GameVersion bump for changes (the section carried that contract as a
## comment inside sim.nim). sim.nim imports and re-exports this module, so
## existing consumers (global.nim, preview tools, tests) are unchanged.

import
  std/[math, os, strutils],
  bitworld/aseprite,
  pixie,
  sim_types

when not defined(emscripten) and not defined(arenaComponent):
  import bitworld/client as bitworldClient

proc gameDir*(): string =
  ## Returns the CTF game directory.
  getCurrentDir()

proc clientDataDir*(): string =
  ## Returns the shared client data directory.
  when defined(emscripten) or defined(arenaComponent):
    gameDir() / "data"
  else:
    bitworldClient.clientDir() / "data"

proc spriteSheetPath(): string =
  ## Returns the sprite sheet aseprite path.
  gameDir() / SpriteSheetAsepritePath

proc loadSpriteSheet*(): Image =
  ## Loads the sprite sheet from aseprite.
  readAsepriteImage(spriteSheetPath())

proc crewSheetPath(): string =
  ## Returns the crew sprite sheet path. A hand-pixeled crew.png (the
  ## purpose-built tactical soldier) is preferred; the legacy crew.aseprite is
  ## the fallback so an art rollback needs no code change.
  for candidate in [
    gameDir() / "data" / "crew.png",
    clientDataDir() / "crew.png",
    clientDataDir() / "crew.aseprite",
    gameDir() / "data" / "crew.aseprite",
  ]:
    if fileExists(candidate):
      return candidate
  gameDir() / "data" / "crew.aseprite"

proc readCrewSheetImage(path: string): Image =
  ## Reads the crew sheet as a Pixie image from either a PNG or an aseprite
  ## file (both render to the same RGBA Image the crew tint path consumes).
  if path.toLowerAscii.endsWith(".png"):
    readImage(path)
  else:
    readAsepriteImage(path)

proc crewSpriteOffset*(sprite: CrewSprite, x, y: int): int =
  ## Returns the RGBA byte offset for one crew sprite pixel.
  (y * sprite.width + x) * 4

proc crewSpriteFromImage(image: Image, index, row: int): CrewSprite =
  ## Extracts one raw 16x16 crew sprite from one sheet row.
  result = CrewSprite(
    width: CrewSpriteSize,
    height: CrewSpriteSize,
    rgba: newSeq[uint8](CrewSpriteSize * CrewSpriteSize * 4)
  )
  let
    baseX = index * CrewSpriteSize
    baseY = row * CrewSpriteSize
  for y in 0 ..< CrewSpriteSize:
    for x in 0 ..< CrewSpriteSize:
      let
        pixel = image[baseX + x, baseY + y]
        offset = result.crewSpriteOffset(x, y)
      result.rgba[offset] = pixel.r
      result.rgba[offset + 1] = pixel.g
      result.rgba[offset + 2] = pixel.b
      result.rgba[offset + 3] = pixel.a

proc loadCrewSpriteRow*(row: int, label: string): seq[CrewSprite] =
  ## Loads eight 16x16 crew sprites from one sheet row.
  if row < 0:
    raise newException(CtfError, "Crew sprite sheet row is negative.")
  let
    path = crewSheetPath()
    image = readCrewSheetImage(path)
  if image.width < CrewSpriteSize * CrewSpriteVariants or
      image.height < CrewSpriteSize * (row + 1):
    raise newException(
      CtfError,
      label & " sprite sheet row is missing eight 16x16 sprites: " & path
    )
  for i in 0 ..< CrewSpriteVariants:
    result.add(image.crewSpriteFromImage(i, row))

proc loadCrewSprites*(): seq[CrewSprite] =
  ## Loads the first eight 16x16 living crew sprites.
  loadCrewSpriteRow(0, "Crew")

proc loadRgbaSprite*(name: string, size: int, alphaCutoff = 0'u8): seq[uint8] =
  ## Loads a hand-painted relic PNG from data/ and returns it as a straight-alpha
  ## RGBA buffer scaled to size×size for the Sprite v1 protocol. The PNGs carry
  ## real transparency (alpha-knocked from the art), and pixie stores
  ## premultiplied alpha internally, so we take `.rgba` to hand the protocol
  ## un-premultiplied colors.
  ##
  ## `alphaCutoff` > 0 snaps the resized alpha to a HARD edge (>= cutoff opaque,
  ## else fully clear). Pixie's `resize` is bilinear, so downscaling a big PNG
  ## feathers its bold dark outline into a ring of semi-transparent pixels that
  ## reads as a fuzzy colored halo bleeding onto the floor. Snapping the alpha
  ## keeps the SAME art but restores the crisp outline; the interior facets are
  ## untouched (they were already fully opaque). 128 is the sweet spot at both
  ## the carried (20px) and planted (60px) footprints.
  let image = readImage(gameDir() / name).resize(size, size)
  result = newSeq[uint8](size * size * 4)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        pixel = image[x, y].rgba
        offset = (y * size + x) * 4
        alpha = if alphaCutoff == 0'u8: pixel.a
                elif pixel.a >= alphaCutoff: 255'u8
                else: 0'u8
      result[offset] = pixel.r
      result[offset + 1] = pixel.g
      result[offset + 2] = pixel.b
      result[offset + 3] = alpha

proc loadHeartSprite*(team: Team, size: int): seq[uint8] =
  ## The CTF objective, a glowing team-colored heart-gem relic (0.7.0 renamed the
  ## "flag" a heart in-sim). Red = crimson life-crystal, Blue = frost life-crystal.
  ## Hard alpha edge (cutoff 128) so the bold painted outline stays crisp at the
  ## sprite footprint instead of feathering into a fuzzy halo on the floor.
  loadRgbaSprite(
    "data/heart_" & teamText(team) & ".png",
    size,
    alphaCutoff = 128'u8
  )

proc loadMedKitSprite*(size: int): seq[uint8] =
  ## The center-field healing pickup: a chunky white healer's kit with a red
  ## cross, matching the bold-outline painted item style (heart gem, paint
  ## bomb). Hard alpha edge keeps the outline crisp on the floor.
  loadRgbaSprite("data/medkit.png", size, alphaCutoff = 128'u8)

proc loadShieldSprite*(size: int): seq[uint8] =
  ## The endzone protective pickup: a chunky bold-outline heater shield in the
  ## same painted-item style as the med kit and paint bomb. Hard alpha edge
  ## keeps the outline crisp on the floor.
  loadRgbaSprite("data/shield.png", size, alphaCutoff = 128'u8)

proc loadPaintBombSprite*(size: int): seq[uint8] =
  ## The thrown grenade, a kid-friendly dungeon-crawler alchemical paint-bomb orb
  ## (cork-stopped rune bottle of swirling paint — NO fuse). Used for the corner
  ## pickup, the carried icon, and the in-flight projectile.
  loadRgbaSprite("data/paintbomb.png", size)

proc loadSprayCanSprite*(size: int): seq[uint8] =
  ## The side-column cone weapon: a chunky aerosol spray-paint can, in the same
  ## bold-outline painted style as the med kit, shield, and paint bomb (this is
  ## paintball — the short-range weapon sprays paint, it does not fire plasma).
  ## Used for the floor pickup and the carried marker. Hard alpha edge keeps the
  ## ink outline crisp on the floor instead of feathering into a halo.
  loadRgbaSprite("data/spraycan.png", size, alphaCutoff = 128'u8)

## --- HD top-down soldier: CvC cog + gun, rotated as one rigid unit ---
## Each team's master (soldier_red/blue.png) is the canonical Cogs-vs-Clips cog
## facing SOUTH, smile visor visible, used exactly as drawn. It is measured for
## its body pivot (solid-pixel centroid) and scaled so the body fills
## SoldierBodyPx. The shared gun master (paintgun.png: muzzle east, barrel
## centerline at image mid-height) mounts GunGripPx east of the body center
## with its barrel on the aim ray, and body + gun pre-rotate TOGETHER around
## the body center — the cog spins with its gun, so east aim (rot 0) shows the
## master exactly as drawn and tracers always line up with the muzzle.
const SoldierMasterPaths: array[Skin, array[Team, string]] = [
  DefaultSkin: [
    Red: "data/soldier_red.png",
    Blue: "data/soldier_blue.png",
    Green: "data/soldier_green.png",
    Yellow: "data/soldier_yellow.png"
  ],
  CrownSkin: [
    Red: "data/soldier_red_crown.png",
    Blue: "data/soldier_blue_crown.png",
    Green: "data/soldier_green_crown.png",
    Yellow: "data/soldier_yellow_crown.png"
  ]
]

var
  soldierMasters: array[Skin, array[Team, Image]]
  soldierPivotX, soldierPivotY: array[Skin, array[Team, float]]
  soldierScale: array[Skin, array[Team, float]]
  soldierLoaded: array[Skin, array[Team, bool]]
  soldierRotCache: array[
    Skin,
    array[Team, array[SoldierRotations, seq[tuple[
      scale: int, pixels: seq[uint8]
    ]]]]
  ]
  gunMaster: Image
  gunScale: float
  gunLoaded: bool
  sprayMaster: Image
  sprayScale: float
  sprayLoaded: bool

proc measureSoldierBody(skin: Skin, team: Team, master: Image) =
  ## Finds the body pivot and the master->canvas scale: the centroid and
  ## vertical span of the SOLID pixels (alpha >= 200 — the cog shell; the
  ## baked-in soft drop shadow sits below that and is excluded, so the cog
  ## itself, not its shadow, is what centers and fills SoldierBodyPx).
  var
    sumX = 0.0
    sumY = 0.0
    n = 0
    top = master.height
    bot = -1
  for y in 0 ..< master.height:
    for x in 0 ..< master.width:
      if master.data[y * master.width + x].a >= 200:
        sumX += float(x); sumY += float(y); inc n
        top = min(top, y); bot = max(bot, y)
  if n == 0:
    soldierPivotX[skin][team] = float(master.width) / 2
    soldierPivotY[skin][team] = float(master.height) / 2
    soldierScale[skin][team] =
      float(SoldierBodyPx) / max(1.0, float(master.height))
  else:
    soldierPivotX[skin][team] = sumX / float(n)
    soldierPivotY[skin][team] = sumY / float(n)
    soldierScale[skin][team] =
      float(SoldierBodyPx) / max(1.0, float(bot - top + 1))

proc ensureSoldierLoaded(skin: Skin, team: Team) =
  if soldierLoaded[skin][team]:
    return
  let master = readImage(gameDir() / SoldierMasterPaths[skin][team])
  soldierMasters[skin][team] = master
  measureSoldierBody(skin, team, master)
  soldierLoaded[skin][team] = true

proc ensureGunLoaded() =
  if gunLoaded:
    return
  # Top-down paintball marker, muzzle east, barrel on the image mid-line. Scaled
  # by WIDTH so GunLengthPx spans the full stock-to-muzzle length along the aim.
  gunMaster = readImage(gameDir() / "data/paintgun_topdown.png")
  gunScale = float(GunLengthPx) / max(1.0, float(gunMaster.width))
  gunLoaded = true

proc ensureSprayLoaded() =
  if sprayLoaded:
    return
  # The held spray can: same convention as the gun master (nozzle EAST, body on
  # the image mid-line) so the identical grip math mounts it. Scaled to
  # SprayHeldLengthPx — a can is a short fistful, not a long marker.
  sprayMaster = readImage(gameDir() / "data/spraycan_held.png")
  sprayScale = float(SprayHeldLengthPx) / max(1.0, float(sprayMaster.width))
  sprayLoaded = true

proc soldierRotPixels*(
  team: Team,
  skin: Skin,
  rot: int,
  renderScale = 1
): seq[uint8] =
  ## One pre-rendered soldier sprite (SoldierCanvas·renderScale square,
  ## straight-alpha RGBA): body + gun as one rigid unit, rotated to aim step
  ## `rot`. The master's FACE side (south) leads the aim with the gun held in
  ## front of it — aiming south shows the master exactly as drawn. The masters
  ## are ~120px art rendered down to a 34px body at 1×, so a renderScale > 1
  ## raster recovers genuine painted detail, not upscaled blocks.
  let r = ((rot mod SoldierRotations) + SoldierRotations) mod SoldierRotations
  for cached in soldierRotCache[skin][team][r]:
    if cached.scale == renderScale:
      return cached.pixels
  ensureSoldierLoaded(skin, team)
  ensureGunLoaded()
  let
    master = soldierMasters[skin][team]
    outCanvas = SoldierCanvas * renderScale
    # aim increases counter-clockwise on screen (0=east, 64=north); screen y is
    # down, so a positive brad step rotates the art clockwise in image space —
    # i.e. draw at angle -theta to match aimVector.
    angle = float(r) * 2.0 * PI / float(SoldierRotations)
    s = soldierScale[skin][team] * float(renderScale)
    center = float32(outCanvas) / 2
  var canvas = newImage(outCanvas, outCanvas)
  let
    unitRot =
      translate(vec2(center, center)) *
      rotate(float32(-angle))
    # Unit space: +x = aim. The extra -90° turns the master so its SOUTH side
    # (the smile visor) points along +x — the face leads the aim, right behind
    # the gun.
    bodyMat =
      unitRot *
      rotate(float32(-PI / 2)) *
      scale(vec2(float32(s), float32(s))) *
      translate(
        vec2(
          float32(-soldierPivotX[skin][team]),
          float32(-soldierPivotY[skin][team])
        )
      )
    # Gun-local (0, height/2) — the stock end of the barrel centerline — mounts
    # GunGripPx along the aim (stock behind the hub, barrel reaching out front)
    # and GunRightPx off the aim ray to the cog's RIGHT (+y = right when facing
    # +x/east); it spins with the unit so the marker rides the head's right.
    gunMat =
      unitRot *
      translate(vec2(
        float32(GunGripPx * renderScale), float32(GunRightPx * renderScale))) *
      scale(vec2(
        float32(gunScale * float(renderScale)),
        float32(gunScale * float(renderScale))
      )) *
      translate(vec2(0, float32(-gunMaster.height) / 2))
  canvas.draw(master, bodyMat)
  canvas.draw(gunMaster, gunMat)
  # Straight-alpha RGBA for the Sprite v1 protocol (pixie stores premultiplied).
  var pixels = newSeq[uint8](outCanvas * outCanvas * 4)
  for i in 0 ..< outCanvas * outCanvas:
    let c = canvas.data[i].rgba()
    pixels[i * 4] = c.r
    pixels[i * 4 + 1] = c.g
    pixels[i * 4 + 2] = c.b
    pixels[i * 4 + 3] = c.a
  soldierRotCache[skin][team][r].add((scale: renderScale, pixels: pixels))
  pixels

proc soldierRotIndex*(aimBrads: int): int =
  ## Quantizes an aim angle to the nearest pre-rotated sprite step.
  ((aimBrads + AimBradsTurn div (SoldierRotations * 2)) *
    SoldierRotations div AimBradsTurn) mod SoldierRotations

## --- Articulated TURRET rig: the REAL CvC cog, segmented (broadcast board only) ---
## The SAME real master art as soldierRotPixels, SLICED (scripts/art/build_cvc_rig.py)
## into 9 pieces that recompose to the south master at rest but articulate like a
## tank trike when moving:
##   head  - cube + cyan visor + center pistons + the held GUN. Faces AIM. Drawn
##           LAST so it covers the hub/leg-joins (no head-hole).
##   armL/R- the two shoulder assemblies. Face AIM. TUCKED at rest; reach FORWARD
##           to cradle the carried heart only while carrying (carry-gated caller).
##   legFL/FR/Rear - the three leg struts (tire removed). Face the MOVEMENT heading
##           (CogDriveState.bodyHeading), each hinged about its own hip with a
##           differential turn swing; the INNER leg SHORTENS into a turn.
##   wheelL/R/Rear - the three tires, cut out of the legs, each CASTERING (rotating
##           about its axle) toward the roll direction, capped so a tall top-down
##           tire only tilts to hint the turn (never swings fully broadside).
## The head/arms track AIM while the legs/wheels track MOVEMENT — a true turret
## swivel. All broadcast-only (no sim state, no GameVersion bump); POV keeps the
## unified soldierRotPixels sprite.
##
## Every segment is baked in the SAME 192px master frame space through ONE code
## path (rigSegPixels): rotate the segment about its ANCHOR by a base angle (aim
## for head/arms, bodyHeading for legs/wheels) plus an articulation, then place the
## HUB on the player. At rest everything rotates by the same aim delta about anchors
## that ARE its master pixels, so the composite == the south master.
type
  RigSeg* = enum
    rsHead, rsArmL, rsArmR, rsLegFL, rsLegFR, rsLegRear,
    rsWheelL, rsWheelR, rsWheelRear

const
  RigCanvas* = 96             ## px square rig segment canvas at 1x (fits the
                              ## swung legs + castered wheels + reaching arms).
  # Anchors in 192px master-frame space (scripts/art/build_cvc_rig.py anchors.json).
  RigHub: tuple[x, y: float] = (96.0, 88.0)   ## cog rotation center (head-cube
                              ## center); head, arms and leg-hips all measured here.
  RigAnchor: array[RigSeg, tuple[x, y: float]] = [
    (96.0, 88.0),     # rsHead      (== hub; head rotates about the hub to aim)
    (70.0, 84.0),     # rsArmL      left shoulder attach
    (120.0, 84.0),    # rsArmR      right shoulder attach
    (72.0, 100.0),    # rsLegFL     left front hip
    (120.0, 100.0),   # rsLegFR     right front hip
    (96.0, 80.0),     # rsLegRear   rear hip — flipped 180° about hub to the BACK
    # Wheels caster about their TIRE CENTROID (measured), not the axle at the top —
    # pivoting mid-tire spins the wheel in place, not swinging the tire body out.
    (73.5, 134.0),    # rsWheelL    left front tire centroid
    (117.3, 132.7),   # rsWheelR    right front tire centroid
    (94.7, 48.3)]     # rsWheelRear rear tire centroid — flipped 180° to the BACK
  # Articulation feel (degrees). Legs differential-steer: rest tuck ± splay on the
  # turn signal; the INNER leg shortens instead of splaying wide.
  RigRestTuckDeg = 2.0
  RigSplayDeg = 5.0           ## outer leg barely swings — the inner-leg SHORTEN +
                              ## wheel caster carry the turn read; a big swing on
                              ## the far leg reads as a splayed spider strut.
  RigRearCounterFrac = 0.3    ## rear leg counter-swings this fraction of splay.
  RigInnerShorten = 0.34      ## inner leg shrinks up to this fraction on a turn.
  RigArmReachDeg = 22.0       ## arms swing forward this far to cradle a carried
                              ## heart (art step 1); 0 at rest (tucked shoulders).
  RigShortenSteps* = 4        ## baked leg-length steps (0 = full .. this = shortest).
  RigSteps* = 16              ## baked steps per rotating quantity (aim / heading).
  RigLegSwingSteps* = 3       ## baked leg swing steps across the full turn range.
                              ## The swing range is only ±RigSplayDeg (5°), so a
                              ## handful of steps is already sub-2° — finer steps
                              ## just multiply the pose pool the replay viewer
                              ## must bake, ship, and hold as textures.
  # Wheel caster: capped TIGHT so a tall top-down tire only tilts to hint the roll
  # direction. Expressed in brads (AimBradsTurn=256): 16 brads ≈ 22°.
  RigCasterMaxBrads* = 16
  RigCasterSteps* = 4         ## baked caster tilt steps across ±RigCasterMaxBrads
                              ## (~5.5° per step — a tilt hint, not a smooth roll,
                              ## so coarse steps read fine; see RigLegSwingSteps
                              ## on why the pool is kept small).

var
  rigLoaded: array[Team, bool]
  rigSegImg: array[Team, array[RigSeg, Image]]
  rigHeadImg: array[Skin, array[Team, Image]]
  rigScale: array[Team, float]   ## master-frame px -> map px (body fills body px).
  # The head asset is skin-specific; all other rig segments are shared.
  # Bake cache keyed by skin and (baseStep, artStep, shortenStep, scale).
  # baseStep is the aim step (head/arms) or heading step (legs/wheels); artStep
  # is the leg swing or wheel caster; shortenStep is the leg-length index
  # (0 for non-legs).
  rigSegCache: array[Skin, array[Team, array[RigSeg, seq[tuple[
    baseStep, artStep, shortenStep, scale: int, pixels: seq[uint8]]]]]]

proc rigSegPath(seg: RigSeg): string =
  case seg
  of rsHead: "head"
  of rsArmL: "arm_l"
  of rsArmR: "arm_r"
  of rsLegFL: "leg_fl"
  of rsLegFR: "leg_fr"
  of rsLegRear: "leg_rear"
  of rsWheelL: "wheel_l"
  of rsWheelR: "wheel_r"
  of rsWheelRear: "wheel_rear"

proc rigSegIsLeg*(seg: RigSeg): bool =
  seg in {rsLegFL, rsLegFR, rsLegRear}

proc rigSegIsWheel*(seg: RigSeg): bool =
  seg in {rsWheelL, rsWheelR, rsWheelRear}

proc ensureRigLoaded(team: Team) =
  if rigLoaded[team]:
    return
  let dir = gameDir() / "data/rig_real" / teamText(team)
  for seg in RigSeg:
    rigSegImg[team][seg] = readImage(dir / rigSegPath(seg) & ".png")
  rigHeadImg[DefaultSkin][team] = rigSegImg[team][rsHead]
  rigHeadImg[CrownSkin][team] = readImage(dir / "head_crown.png")
  # Scale the rig so its body matches the unified soldier footprint. The solid
  # body spans ~99px in the 192px frame (y56..154); map that to SoldierBodyPx.
  ensureSoldierLoaded(DefaultSkin, team)
  rigScale[team] = float(SoldierBodyPx) / 99.0
  rigLoaded[team] = true

proc soldierCanvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA (Sprite v1 protocol) from a pixie canvas.
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc rigSegPixels*(team: Team, seg: RigSeg, baseStep, artStep: int,
    shortenStep = 0, renderScale = 1, skin = DefaultSkin): seq[uint8] =
  ## One rig segment baked into a RigCanvas sprite, HUB-centered.
  ##  - baseStep: the segment's base rotation step (RigSteps) — the AIM step for
  ##    the head/arms, the movement-HEADING step for legs/wheels. This IS the
  ##    turret swivel: head/arms and legs get DIFFERENT baseSteps.
  ##  - artStep: leg differential swing (signed, RigLegSwingSteps) or wheel caster
  ##    tilt (signed, RigCasterSteps); ignored for the head.
  ##  - shortenStep: leg-length index 0..RigShortenSteps (legs only; inner-leg
  ##    shorten). 0 for everything else.
  ## Each segment rotates about its ANCHOR by baseDeg + articulation, then the HUB
  ## lands at canvas center — so at rest (all baseSteps equal, art 0) the segments
  ## recompose to the south master exactly.
  let
    b = ((baseStep mod RigSteps) + RigSteps) mod RigSteps
    art = artStep
    sh = clamp(shortenStep, 0, RigShortenSteps)
    effectiveSkin = if seg == rsHead: skin else: DefaultSkin
  for cached in rigSegCache[effectiveSkin][team][seg]:
    if cached.baseStep == b and cached.artStep == art and
        cached.shortenStep == sh and cached.scale == renderScale:
      return cached.pixels
  ensureRigLoaded(team)
  let
    outCanvas = RigCanvas * renderScale
    img =
      if seg == rsHead:
        rigHeadImg[effectiveSkin][team]
      else:
        rigSegImg[team][seg]
    s = rigScale[team] * float(renderScale)
    center = float32(outCanvas) / 2
    anchor = RigAnchor[seg]
    hub = RigHub
    # base delta: rot 0 = east; the master faces SOUTH so the −90° turn makes the
    # face lead the base direction. Angle increases CCW; screen y down → rotate −.
    baseAngle = float(b) * 2.0 * PI / float(RigSteps)
    baseDeg = -baseAngle - PI / 2.0
    # The gun mounts in PURE aim space (no −90° — the master-south turn is only for
    # the body art), like soldierRotPixels: unitRot = rotate(−aimAngle).
    unitDeg = -baseAngle
  # Articulation about the segment's own anchor (radians, screen CCW+).
  var artDeg = 0.0
  if rigSegIsLeg(seg):
    let sw = float(art) / float(RigLegSwingSteps) * RigSplayDeg  # signed swing
    case seg
    of rsLegFL:  artDeg = (-RigRestTuckDeg + sw) * PI / 180.0
    of rsLegFR:  artDeg = ( RigRestTuckDeg + sw) * PI / 180.0
    of rsLegRear: artDeg = (sw * RigRearCounterFrac) * PI / 180.0
    else: discard
  elif rigSegIsWheel(seg):
    # caster tilt: art is the signed caster step; convert to a small angle.
    let tilt = float(art) / float(RigCasterSteps) *
      (float(RigCasterMaxBrads) * 2.0 * PI / float(AimBradsTurn))
    artDeg = -tilt
  elif seg in {rsArmL, rsArmR}:
    # Arms: art 0 = tucked (rest); art 1 = REACHING forward to cradle a carried
    # heart. The reach swings each shoulder inward-and-forward about its attach so
    # the two arms close in front of the aim (where the heart rides).
    if art != 0:
      artDeg = (if seg == rsArmL: RigArmReachDeg else: -RigArmReachDeg) *
        PI / 180.0
  # Leg-length shorten: scale the leg toward its hip along the hip→foot (down)
  # axis. The leg art hangs below its hip anchor, so scaling y about the anchor
  # pulls the foot (and its wheel, placed separately) up toward the hip.
  let shortenF = 1.0 - float(sh) / float(RigShortenSteps) * RigInnerShorten
  var canvas = newImage(outCanvas, outCanvas)
  let
    toCenter = translate(vec2(center, center))
    baseRot = rotate(float32(baseDeg))
    scl = scale(vec2(float32(s), float32(s)))
    hubToOrigin = translate(vec2(float32(-hub.x), float32(-hub.y)))
    artMat =
      translate(vec2(float32(anchor.x), float32(anchor.y))) *
      rotate(float32(artDeg)) *
      scale(vec2(1.0'f32, float32(shortenF))) *
      translate(vec2(float32(-anchor.x), float32(-anchor.y)))
    mat = toCenter * baseRot * scl * hubToOrigin * artMat
  # NB: the held gun is NO LONGER baked into the head — it is its own board object
  # (rigGunPixels), drawn ABOVE the head with a backlight glow so it reads clearly
  # and can be gated off if a cog is ever disarmed. The head is a clean turret.
  canvas.draw(img, mat)
  let pixels = soldierCanvasToPixels(canvas)
  rigSegCache[effectiveSkin][team][seg].add(
    (baseStep: b, artStep: art, shortenStep: sh, scale: renderScale,
     pixels: pixels))
  pixels

var rigGunCache: array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]]

proc rigHeldWeaponPixels(
  cache: var array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]],
  team: Team,
  aimStep, renderScale: int,
  master: Image,
  masterScale: float,
  gripPx: int
): seq[uint8] =
  ## Shared held-weapon compositor for the gun and the spray can: the weapon
  ## as its own HUB-centered rig object, mounted at the cog's RIGHT
  ## (GunRightPx off the aim ray, gripPx along aim) with its business end on
  ## +aim, and a warm backlight glow composited BEHIND it so the dark weapon
  ## pops off the dark floor/legs. Cached per team/aim-step/scale.
  let a = ((aimStep mod RigSteps) + RigSteps) mod RigSteps
  for cached in cache[team]:
    if cached.aimStep == a and cached.scale == renderScale:
      return cached.pixels
  let
    outCanvas = RigCanvas * renderScale
    center = float32(outCanvas) / 2
    baseAngle = float(a) * 2.0 * PI / float(RigSteps)
    unitDeg = -baseAngle                 # pure aim space (muzzle/nozzle on +aim)
    ws = masterScale * float(renderScale)
    mat =
      translate(vec2(center, center)) * rotate(float32(unitDeg)) *
      translate(vec2(
        float32(gripPx * renderScale), float32(GunRightPx * renderScale))) *
      scale(vec2(float32(ws), float32(ws))) *
      translate(vec2(0'f32, float32(-master.height) / 2))
  # 1) lay the weapon on a transparent canvas, 2) build a warm-amber backlight
  # from its silhouette (spread + blur), 3) draw glow THEN weapon.
  var weaponLayer = newImage(outCanvas, outCanvas)
  weaponLayer.draw(master, mat)
  let glow = weaponLayer.shadow(
    offset = vec2(0, 0),
    spread = float32(GunGlowSpread * float(renderScale)),
    blur = float32(GunGlowRadius * float(renderScale)),
    color = rgba(255, 214, 138, GunGlowAlpha).color)  # faint warm rim light
  var canvas = newImage(outCanvas, outCanvas)
  canvas.draw(glow)                      # subtle warm edge behind the weapon
  canvas.draw(weaponLayer)
  let pixels = soldierCanvasToPixels(canvas)
  cache[team].add((aimStep: a, scale: renderScale, pixels: pixels))
  pixels

proc rigGunPixels*(team: Team, aimStep: int, renderScale = 1): seq[uint8] =
  ## The held top-down paintball MARKER as its OWN HUB-centered rig object (not
  ## baked into the head): mounted at the cog's RIGHT (GunRightPx off the aim ray,
  ## stock GunGripPx along aim), barrel on +aim so tracers line up. A soft warm
  ## backlight glow is composited BEHIND the marker so the dark gun pops off the
  ## dark floor/legs. Team-independent shape, but cached per team for symmetry with
  ## the other rig segments. Emitted ABOVE the head z; gate the caller on a
  ## `hasGun` flag to hide it when a cog is disarmed.
  ensureGunLoaded()
  rigHeldWeaponPixels(
    rigGunCache, team, aimStep, renderScale, gunMaster, gunScale, GunGripPx)

var rigSprayCache: array[Team, seq[tuple[aimStep, scale: int, pixels: seq[uint8]]]]

proc rigSprayCanPixels*(team: Team, aimStep: int, renderScale = 1): seq[uint8] =
  ## The held SPRAY CAN, the swap-in for rigGunPixels while a cog carries one:
  ## same grip (the cog's RIGHT, GunRightPx off the aim ray) and the same
  ## nozzle-on-+aim convention, so the spray cone leaves the nozzle exactly where
  ## tracers leave the muzzle. Mounted SprayHeldGripPx along aim and scaled to
  ## SprayHeldLengthPx: a can is a short fistful, so its silhouette reads clearly
  ## different from the long marker — that difference is how a viewer tells which
  ## weapon a cog is holding.
  ensureSprayLoaded()
  rigHeldWeaponPixels(
    rigSprayCache, team, aimStep, renderScale, sprayMaster, sprayScale,
    SprayHeldGripPx)

proc soldierIconPixels*(team: Team, sizePx: int): seq[uint8] =
  ## A compact roster chip: the face-on cog scaled so the body fills the icon
  ## (no gun — the smile visor IS the identity). Used by the game-over list.
  ensureSoldierLoaded(DefaultSkin, team)
  let
    master = soldierMasters[DefaultSkin][team]
    s =
      float(sizePx) / float(SoldierBodyPx) *
        soldierScale[DefaultSkin][team]
  var canvas = newImage(sizePx, sizePx)
  let mat =
    translate(vec2(float32(sizePx) / 2, float32(sizePx) / 2)) *
    scale(vec2(float32(s), float32(s))) *
    translate(vec2(
      float32(-soldierPivotX[DefaultSkin][team]),
      float32(-soldierPivotY[DefaultSkin][team])
    ))
  canvas.draw(master, mat)
  result = newSeq[uint8](sizePx * sizePx * 4)
  for i in 0 ..< sizePx * sizePx:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a


## --- Cog driving physics: how the segmented trike steers/turns (broadcast-only) ---
## Ports the Maxwell-approved CogDriveState model (from maxwell/cog-base-turret-
## split): the body heading eases slowly toward travel; each wheel casters toward
## its foot's travel direction near-instantly (so tyres never scrape); the leg
## splay follows a smoothed turn signal. Everything derives from the already-known
## velocity, so it stays broadcast-only and replay-deterministic.
const
  CogBodyTurnRate* = 28       ## max brads/frame the body heading eases toward the
                              ## travel direction — the base is a TRUE TANK track
                              ## that snaps to where it rolls (fast + accurate),
                              ## fully independent of the head/aim.
  CogWheelTurnRate* = 48      ## brads/frame a wheel casters toward travel (even
                              ## faster than the base, so tyres never scrape).
  CogReverseMaxBrads* = 112   ## |heading-travel| beyond this (~158°) = reversing;
                              ## below it the base just turns to face travel.
  CogReverseCommitFrames* = 8   ## backward frames before committing to a U-turn.
  CogMoveMinSpeed* = StopThreshold
  CogTurnFullBrads* = 6       ## heading angular velocity mapped to full splay.
  CogTurnAmtEase* = 200       ## turnAmt eases toward target this many milli/frame.

type
  CogDriveState* = object
    ## Per-player broadcast animation state for the segmented trike. NOT in the
    ## sim / gameHash — lives in the viewer state, evolved once per frame.
    initialized*: bool
    bodyHeading*: int          ## brads the chassis currently faces.
    reverseFrames*: int        ## consecutive backward frames (commit counter).
    turnAmt*: int              ## signed steer signal, -1000..1000 (x1000). + = left.
    casterFL*, casterFR*, casterRear*: int  ## brads each wheel points.

proc bradDiff*(a, b: int): int =
  ## Shortest signed difference a-b wrapped to (-128, 128] brads.
  var d = ((a - b) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
  if d > AimBradsTurn div 2:
    d -= AimBradsTurn
  d

proc easeBrads*(cur, target, maxStep: int): int =
  ## Steps `cur` toward `target` by at most `maxStep` brads along the shortest
  ## arc, wrapping into 0..AimBradsTurn-1.
  let d = bradDiff(target, cur)
  let step = clamp(d, -maxStep, maxStep)
  ((cur + step) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn

proc initCogDriveState*(aimBrads: int): CogDriveState =
  ## A freshly-spawned cog faces where it aims, wheels aligned, not reversing,
  ## legs at rest. Reset on any scrub/respawn so a jump never inherits a stale pose.
  CogDriveState(initialized: true, bodyHeading: aimBrads, reverseFrames: 0,
    turnAmt: 0, casterFL: aimBrads, casterFR: aimBrads, casterRear: aimBrads)

proc stepCogDrive*(state: CogDriveState, velX, velY, aimBrads: int):
    CogDriveState =
  ## Advances the trike's driving animation ONE frame from the current velocity.
  ## Deterministic: same (state, vel, aim) always yields the same next state.
  if not state.initialized:
    return initCogDriveState(aimBrads)
  result = state
  let speed = abs(velX) + abs(velY)
  if speed < CogMoveMinSpeed:
    # Parked: hold heading, coast every caster back to the heading, relax legs.
    result.reverseFrames = max(0, state.reverseFrames - 1)
    result.turnAmt = state.turnAmt -
      clamp(state.turnAmt, -CogTurnAmtEase, CogTurnAmtEase)
    result.casterFL = easeBrads(state.casterFL, state.bodyHeading, CogWheelTurnRate)
    result.casterFR = easeBrads(state.casterFR, state.bodyHeading, CogWheelTurnRate)
    result.casterRear = easeBrads(state.casterRear, state.bodyHeading, CogWheelTurnRate)
    return
  let
    travel = bradsOfVector(velX, velY)
    offBody = bradDiff(travel, state.bodyHeading).abs
    goingBackward = offBody > CogReverseMaxBrads
  if goingBackward:
    result.reverseFrames = min(state.reverseFrames + 1, CogReverseCommitFrames * 2)
  else:
    result.reverseFrames = max(0, state.reverseFrames - 2)
  let committed = result.reverseFrames >= CogReverseCommitFrames
  let headingTarget =
    if goingBackward and not committed: state.bodyHeading
    else: travel
  # The base snaps toward travel at a FLAT fast rate (a tank track grips and
  # turns hard) — no speed penalty, so a direction change is tracked promptly and
  # accurately instead of lagging a quarter-second behind.
  result.bodyHeading = easeBrads(state.bodyHeading, headingTarget, CogBodyTurnRate)
  # turnAmt: smoothed signed heading angular velocity / CogTurnFull, ×1000.
  let w = bradDiff(result.bodyHeading, state.bodyHeading)
  let tInst = clamp(w * 1000 div max(1, CogTurnFullBrads), -1000, 1000)
  let smoothed = (state.turnAmt * 7 + tInst * 3) div 10
  result.turnAmt = state.turnAmt +
    clamp(smoothed - state.turnAmt, -CogTurnAmtEase, CogTurnAmtEase)
  # Each wheel casters toward the travel direction (with a small turn lean so the
  # wheels visibly lead the arc). Rear leans opposite (pivot foot).
  let lean = clamp(result.turnAmt * (AimBradsTurn div 8) div 1000,
    -(AimBradsTurn div 8), AimBradsTurn div 8)
  result.casterFL = easeBrads(state.casterFL, travel + lean, CogWheelTurnRate)
  result.casterFR = easeBrads(state.casterFR, travel + lean, CogWheelTurnRate)
  result.casterRear = easeBrads(state.casterRear, travel - lean, CogWheelTurnRate)

proc rigHeadingStep*(headingBrads: int): int =
  ## The base rotation step for the movement-facing legs/wheels (quantized to
  ## RigSteps). Same quantization as soldierRotIndex, on the body heading.
  soldierRotIndex(headingBrads)

proc rigLegSwingStep*(seg: RigSeg, turnAmt: int): int =
  ## SIGNED leg swing step (−RigLegSwingSteps..RigLegSwingSteps) from the turn
  ## signal (turnAmt ×1000, + = LEFT/CCW). Both front legs swing together with the
  ## turn (the outer leg widens, the inner one is SHORTENED separately); the rear
  ## counter-swings. Non-leg segments return 0.
  let t = clamp(turnAmt, -1000, 1000)
  if rigSegIsLeg(seg):
    int(round(float(t) / 1000.0 * float(RigLegSwingSteps)))
  else: 0

proc rigLegShortenStep*(seg: RigSeg, turnAmt: int): int =
  ## Leg-length shorten step (0..RigShortenSteps) for the INNER leg of the turn.
  ## +turnAmt = LEFT/CCW ⇒ the LEFT (inner) front leg shortens; −turnAmt ⇒ RIGHT.
  let t = clamp(turnAmt, -1000, 1000)
  case seg
  of rsLegFL:  int(round(float(max(0, t)) / 1000.0 * float(RigShortenSteps)))
  of rsLegFR:  int(round(float(max(0, -t)) / 1000.0 * float(RigShortenSteps)))
  else: 0

proc rigCasterStep*(casterBrads, headingBrads: int): int =
  ## SIGNED wheel caster tilt step (−RigCasterSteps..RigCasterSteps): the caster
  ## direction relative to the base HEADING (the wheel is baked rotated by the
  ## heading, so its extra tilt is caster − heading), clamped to ±RigCasterMaxBrads
  ## so a tall top-down tire only tilts to hint the turn.
  let capped = clamp(bradDiff(casterBrads, headingBrads),
    -RigCasterMaxBrads, RigCasterMaxBrads)
  int(round(float(capped) / float(RigCasterMaxBrads) * float(RigCasterSteps)))

const RigBaseMaxDivergeBrads* = 14  ## ~20°: the leg base only LEANS a little toward
                                    ## the movement heading — it never swings far
                                    ## sideways (the spidery look). The HEAD still
                                    ## aims freely for the full turret swivel.

proc clampBaseHeading*(headingBrads, aimBrads: int): int =
  ## Clamps the leg-base heading to within ±RigBaseMaxDivergeBrads of the aim, so
  ## the base only LEANS into a strafe/turn while the head swivels freely. Returns
  ## a wrapped 0..AimBradsTurn-1 heading.
  let d = clamp(bradDiff(headingBrads, aimBrads),
    -RigBaseMaxDivergeBrads, RigBaseMaxDivergeBrads)
  ((aimBrads + d) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
