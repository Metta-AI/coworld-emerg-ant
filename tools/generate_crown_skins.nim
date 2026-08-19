## Generates the crown skin masters from the canonical team soldier art and
## the articulated crown heads from the canonical team rig art.
##
## Run from the repository root:
##   nim r tools/generate_crown_skins.nim
##
## The crown is drawn in the masters' painted style: a shaded gold band that
## hugs the helmet dome (centered on the measured helmet center, x~43), three
## ball-tipped points, a team-colored jewel, and a thin warm outline. Geometry
## uses each asset's master-pixel coordinate system.

import pixie

type TeamArt = object
  sourcePath: string
  outputPath: string
  rigHeadPath: string
  rigCrownHeadPath: string
  jewel: Color

const SoldierSkins = [
  TeamArt(
    sourcePath: "data/soldier_red.png",
    outputPath: "data/soldier_red_crown.png",
    rigHeadPath: "data/rig_real/red/head.png",
    rigCrownHeadPath: "data/rig_real/red/head_crown.png",
    jewel: color(0.90, 0.28, 0.30, 1)
  ),
  TeamArt(
    sourcePath: "data/soldier_blue.png",
    outputPath: "data/soldier_blue_crown.png",
    rigHeadPath: "data/rig_real/blue/head.png",
    rigCrownHeadPath: "data/rig_real/blue/head_crown.png",
    jewel: color(0.30, 0.55, 0.91, 1)
  ),
  TeamArt(
    sourcePath: "data/soldier_green.png",
    outputPath: "data/soldier_green_crown.png",
    rigHeadPath: "data/rig_real/green/head.png",
    rigCrownHeadPath: "data/rig_real/green/head_crown.png",
    jewel: color(0.29, 0.75, 0.42, 1)
  ),
  TeamArt(
    sourcePath: "data/soldier_yellow.png",
    outputPath: "data/soldier_yellow_crown.png",
    rigHeadPath: "data/rig_real/yellow/head.png",
    rigCrownHeadPath: "data/rig_real/yellow/head_crown.png",
    jewel: color(0.93, 0.81, 0.24, 1)
  )
]

const
  CrownCx = 43.0      ## helmet dome center in master pixels.
  CrownHalfW = 17.0   ## half-width of the band: x 26..60 on a ~43px helmet.
  BandTopY = 14.0     ## band upper edge at the band ends.
  BandBotY = 21.0     ## band lower edge at the ends; sags 3px mid-dome.
  BandSag = 3.0       ## downward bow so the band reads as wrapped on the dome.
  SidePointTipY = 4.0
  MidPointTipY = 0.5
  TipBallR = 2.6
  Outline = 2.2
  RigCrownCx = 96.0
  RigCrownYOffset = 30.0

proc crownBody(cx, yOffset: float): Path =
  ## One closed path: base band with a sagging bottom arc, three points
  ## rising off the band top. Left/right points lean slightly outward.
  let
    l = cx - CrownHalfW
    r = cx + CrownHalfW
  result = newPath()
  # Bottom edge, left to right, bowed down mid-dome.
  result.moveTo(l, BandBotY + yOffset)
  result.quadraticCurveTo(
    cx, BandBotY + BandSag * 2 + yOffset, r, BandBotY + yOffset)
  # Right side up to the right point tip (leaning slightly outward).
  result.lineTo(r, BandTopY + yOffset)
  result.lineTo(r + 1.0, SidePointTipY + yOffset)
  # Valley, then the taller middle point.
  result.lineTo(cx + 6.5, BandTopY + 1.5 + yOffset)
  result.lineTo(cx, MidPointTipY + yOffset)
  result.lineTo(cx - 6.5, BandTopY + 1.5 + yOffset)
  # Left point, mirroring the right.
  result.lineTo(l - 1.0, SidePointTipY + yOffset)
  result.lineTo(l, BandTopY + yOffset)
  result.closePath()

proc tipBall(cx, cy: float): Path =
  result = newPath()
  result.circle(cx, cy, TipBallR)

proc addCrown(
  master: Image,
  jewel: Color,
  cx = CrownCx,
  yOffset = 0.0
): Image =
  ## Composites the crown over the cog's helmet in the painted house style.
  result = newImage(master.width, master.height)
  result.draw(master)

  let
    outlineColor = color(0.36, 0.24, 0.09, 1)
    goldPaint = newPaint(LinearGradientPaint)
  # Vertical gold gradient: sunlit top, brassy base — matches the soft
  # shading of the painted masters better than a flat fill.
  goldPaint.gradientHandlePositions = @[
    vec2(cx, MidPointTipY + yOffset),
    vec2(cx, BandBotY + BandSag * 2 + yOffset)
  ]
  goldPaint.gradientStops = @[
    ColorStop(color: color(0.99, 0.90, 0.55, 1), position: 0),
    ColorStop(color: color(0.87, 0.66, 0.22, 1), position: 1)
  ]

  let body = crownBody(cx, yOffset)
  result.fillPath(body, goldPaint)
  result.strokePath(body, outlineColor, strokeWidth = Outline)

  # Ball tips: a slightly lighter gold so they read as separate knobs.
  let ballGold = color(0.98, 0.86, 0.45, 1)
  for (cx, cy) in [
    (cx - CrownHalfW - 1.0, SidePointTipY + yOffset),
    (cx, MidPointTipY + yOffset),
    (cx + CrownHalfW + 1.0, SidePointTipY + yOffset)
  ]:
    let ball = tipBall(cx, cy - 1.0)
    result.fillPath(ball, ballGold)
    result.strokePath(ball, outlineColor, strokeWidth = 1.6)

  # Team-colored jewel centered on the band, with a small white glint.
  var gem = newPath()
  gem.ellipse(cx, BandTopY + 4.5 + yOffset, 3.2, 3.8)
  result.fillPath(gem, jewel)
  result.strokePath(gem, outlineColor, strokeWidth = 1.4)
  var glint = newPath()
  glint.circle(cx - 1.0, BandTopY + 3.2 + yOffset, 0.9)
  result.fillPath(glint, color(1, 1, 1, 0.85))

when isMainModule:
  for art in SoldierSkins:
    let master = readImage(art.sourcePath)
    master.addCrown(art.jewel).writeFile(art.outputPath)
    echo "wrote ", art.outputPath
    let rigHead = readImage(art.rigHeadPath)
    rigHead.addCrown(
      art.jewel,
      cx = RigCrownCx,
      yOffset = RigCrownYOffset
    ).writeFile(art.rigCrownHeadPath)
    echo "wrote ", art.rigCrownHeadPath
