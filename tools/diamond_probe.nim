import ../src/ctf/sim

## Verifies the rotating center diamonds block movement, shots, and vision AT
## EVERY SPIN FRAME, and that the mask they stamp is exactly the silhouette the
## renderer draws (GV28 — the spin is geometry, not decoration).
## Usage: nim r tools/diamond_probe.nim  (from the repo root)

when isMainModule:
  var simServer = initSimServer(defaultGameConfig())
  echo "animated diamonds: ", AnimatedDiamonds.len
  var bad = 0
  for frame in 0 ..< DiamondSpinFrames:
    ## The left half shows `frame` on this tick; the right half mirrors it.
    let tick = frame * DiamondSpinTicksPerFrame
    simServer.applyDiamondGeometry(tick)
    for spot in AnimatedDiamonds:
      let
        spotFrame = diamondSpinFrame(spot.cx, spot.cy, tick)
        leftX = spot.cx - spot.radius - 8
        rightX = spot.cx + spot.radius + 8
        y = spot.cy
        centerWall = simServer.wallMask[mapIndex(spot.cx, spot.cy)]
        losClear = simServer.lineOfSightClear(leftX, y, rightX, y)
        fovOpaque = simServer.fovBlocked[
          (spot.cy div FovCellSize) * FovGridW + spot.cx div FovCellSize]
        walkable = simServer.walkMask[mapIndex(spot.cx, spot.cy)]
      var maskMismatch = 0
      for py in spot.cy - spot.radius - 1 .. spot.cy + spot.radius + 1:
        for px in spot.cx - spot.radius - 1 .. spot.cx + spot.radius + 1:
          let expected = simServer.isArtWall(px, py) or
            animatedDiamondCovers(spot, spotFrame, px, py)
          if simServer.wallMask[mapIndex(px, py)] != expected:
            inc maskMismatch
      if frame == 0:
        echo "diamond (", spot.cx, ",", spot.cy, ") r=", spot.radius,
          " wall=", centerWall,
          " shotBlocked=", not losClear,
          " fovBlocked=", fovOpaque,
          " walkable=", walkable
      if not centerWall or losClear or not fovOpaque or walkable or
          maskMismatch > 0:
        echo "  FAIL frame ", spotFrame, " at (", spot.cx, ",", spot.cy,
          "): mask mismatches=", maskMismatch
        inc bad
  if bad > 0:
    echo "PROBLEM: ", bad, " diamond/frame pairs are not full cover"
    quit(1)
  echo "all diamonds are full cover at all ", DiamondSpinFrames,
    " spin frames (move+shot+vision blocked, mask == drawn silhouette)"
