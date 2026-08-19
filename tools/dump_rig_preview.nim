## Dumps the articulated TURRET rig at several driving poses to a PNG, composited
## as the board emission will (segments z-stacked; head/arms → AIM, legs/wheels →
## movement heading). Verifies the Nim bake matches the Python reference and lets
## us eyeball the turret swivel / caster / inner-leg-shorten / carry before wiring.

import
  pixie,
  ../src/ctf/sim,
  toolutil

proc composePose(team: Team, aimBrads, velX, velY: int, carrying = false): Image =
  ## Drive several frames to settle the drive state, then stack the segments.
  var drive = initCogDriveState(aimBrads)
  for _ in 0 ..< 40:
    drive = stepCogDrive(drive, velX, velY, aimBrads)
  let
    aimStep = soldierRotIndex(aimBrads)
    baseHeading = clampBaseHeading(drive.bodyHeading, aimBrads)
    headStep = rigHeadingStep(baseHeading)
  var canvas = newImage(RigCanvas, RigCanvas)
  proc blit(dst: Image, seg: RigSeg, baseStep, artStep, shorten: int) =
    dst.draw(spriteToImage(
      rigSegPixels(team, seg, baseStep, artStep, shorten), RigCanvas, RigCanvas))
  # z: rear wheel/leg (behind), front wheels, front legs, head, arms
  blit(canvas, rsWheelRear, headStep, rigCasterStep(drive.casterRear, baseHeading), 0)
  blit(canvas, rsLegRear, headStep, rigLegSwingStep(rsLegRear, drive.turnAmt), 0)
  blit(canvas, rsWheelL, headStep, rigCasterStep(drive.casterFL, baseHeading), 0)
  blit(canvas, rsWheelR, headStep, rigCasterStep(drive.casterFR, baseHeading), 0)
  blit(canvas, rsLegFL, headStep, rigLegSwingStep(rsLegFL, drive.turnAmt),
    rigLegShortenStep(rsLegFL, drive.turnAmt))
  blit(canvas, rsLegFR, headStep, rigLegSwingStep(rsLegFR, drive.turnAmt),
    rigLegShortenStep(rsLegFR, drive.turnAmt))
  blit(canvas, rsHead, aimStep, 0, 0)
  # arms always drawn; reach (art 1) when carrying, tucked (art 0) at rest.
  let reach = 0  # arms no longer reach; shoulders rotate with aim only
  blit(canvas, rsArmL, aimStep, reach, 0)
  blit(canvas, rsArmR, aimStep, reach, 0)
  canvas

when isMainModule:
  # aim brads: 0=east, 64=north, 128=west, 192=south (aimVector: 0=east,64=north).
  let poses = [
    ("rest", 192, 0, 0, false),
    ("drive S", 192, 0, 40, false),
    ("strafe E", 192, 40, 0, false),
    ("turn left", 192, 30, 30, false),
    ("turn right", 192, -30, 30, false),
    ("aim E move S", 0, 0, 40, false),
    ("carry S", 192, 0, 40, true)]
  var canvas = newImage(RigCanvas * poses.len + 20, RigCanvas + 40)
  for i in 0 ..< canvas.width * canvas.height:
    canvas.data[i] = rgba(220, 216, 207, 255).rgbx()
  for i, (lbl, aim, vx, vy, carry) in poses:
    let pose = composePose(Blue, aim, vx, vy, carry)
    canvas.draw(pose, translate(vec2(float32(10 + i * RigCanvas), 30)))
  canvas.writeFile("/tmp/rig_nim_preview.png")
  echo "wrote /tmp/rig_nim_preview.png"
