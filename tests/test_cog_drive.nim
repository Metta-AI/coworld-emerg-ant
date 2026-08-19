import
  std/[unittest, math],
  ctf/sim

## Drives the broadcast-only cog steering controller (stepCogDrive) through the
## scenarios that motivated it, asserting the BEHAVIOR rather than exact angles:
## wheels always caster toward travel (never scrape), the body heading tracks
## travel, a brief reverse does NOT flip the body, and a sustained reverse DOES
## commit to turning around.
##
## These are pure state-machine checks — no art, no sim state, no gameHash — so
## they pin the feel of the trike animation without touching the engine contract.
## They also lock REPLAY DETERMINISM: the same (state, velocity, aim) must always
## yield the same next state, or a scrub would desync the pose from the frame.

const
  East = 0
  North = 64
  West = 128
  South = 192
  Fast = MaxSpeed          ## a full-speed velocity component.

proc runFrames(state: var CogDriveState, velX, velY, aim, n: int) =
  for _ in 0 ..< n:
    state = stepCogDrive(state, velX, velY, aim)

suite "cog driving physics":
  test "shortest-arc brad helpers wrap correctly":
    check bradDiff(10, 0) == 10
    check bradDiff(0, 10) == -10
    check bradDiff(200, 0) == 200 - AimBradsTurn   # -56, the short way
    check bradDiff(0, 200) == AimBradsTurn - 200   # +56
    check easeBrads(0, 100, 10) == 10              # steps +10 toward target
    check easeBrads(0, 200, 10) == AimBradsTurn - 10  # steps the SHORT way (down)
    check easeBrads(0, 5, 10) == 5                 # never overshoots

  test "a fresh cog faces where it aims, wheels aligned":
    let s = initCogDriveState(North)
    check s.bodyHeading == North
    check s.casterFL == North
    check s.casterFR == North
    check s.casterRear == North
    check s.reverseFrames == 0
    check s.turnAmt == 0

  test "driving forward turns the body heading toward travel":
    var s = initCogDriveState(East)
    # travel NORTH (velY negative = north in screen coords), aim stays east.
    runFrames(s, 0, -Fast, East, 30)
    # body should have turned to face north (travel), not stayed east.
    check abs(bradDiff(s.bodyHeading, North)) <= 4

  test "wheels caster to travel faster than the body turns (no scrape)":
    var s = initCogDriveState(East)
    # One frame of hard strafe north: the wheels must already be closer to north
    # than the body is — the tyres lead so they roll instead of scraping.
    s = stepCogDrive(s, 0, -Fast, East)
    check abs(bradDiff(s.casterFL, North)) < abs(bradDiff(s.bodyHeading, North))
    # After a few frames the wheels are essentially aligned with travel.
    runFrames(s, 0, -Fast, East, 4)
    check abs(bradDiff(s.casterFL, North)) <= CogWheelTurnRate

  test "a BRIEF reverse does not flip the body 180 degrees":
    var s = initCogDriveState(East)
    # travel WEST (backward) for just a couple frames — under the commit window.
    runFrames(s, -Fast, 0, East, 3)
    check s.reverseFrames < CogReverseCommitFrames
    # body must still be essentially facing east (backed up, did not turn around).
    check abs(bradDiff(s.bodyHeading, East)) <= 2 * CogBodyTurnRate
    # but the wheels have castered toward west so they roll, not scrape.
    check abs(bradDiff(s.casterFL, West)) <= 2 * CogWheelTurnRate

  test "a SUSTAINED reverse commits to turning around":
    var s = initCogDriveState(East)
    # hold backward (west) travel well past the commit window.
    runFrames(s, -Fast, 0, East, CogReverseCommitFrames + 40)
    # the body should have committed and turned to face the travel direction.
    check abs(bradDiff(s.bodyHeading, West)) <= 6

  test "parked cog holds its heading and decays reverse commitment":
    var s = initCogDriveState(North)
    s.reverseFrames = CogReverseCommitFrames
    # zero velocity: parked.
    runFrames(s, 0, 0, North, 20)
    check s.bodyHeading == North
    check s.reverseFrames == 0
    # and every caster coasts back in line with the heading.
    check s.casterFL == North
    check s.casterFR == North
    check s.casterRear == North

  test "deterministic: same inputs reproduce the same state (replay-safe)":
    var a = initCogDriveState(South)
    var b = initCogDriveState(South)
    for i in 0 ..< 50:
      # a wandering velocity, identical for both runs.
      let vx = int(Fast * cos(float(i) * 0.3))
      let vy = int(Fast * sin(float(i) * 0.3))
      a = stepCogDrive(a, vx, vy, South)
      b = stepCogDrive(b, vx, vy, South)
    check a == b

  test "an uninitialized state re-inits from the aim (scrub-safe)":
    # A zeroed state is what a fresh scrub/seek hands us: it must snap to the
    # aim rather than inherit heading 0 (east) and swing across the board.
    var s = CogDriveState()
    check not s.initialized
    s = stepCogDrive(s, 0, 0, North)
    check s.initialized
    check s.bodyHeading == North

  test "differential: fresh + parked cog has narrow legs (turnAmt ~ 0)":
    var s = initCogDriveState(North)
    check s.turnAmt == 0                      # rest = narrow
    runFrames(s, 0, -Fast, North, 20)         # drive straight north
    check abs(s.turnAmt) <= 60                # straight line => still ~narrow

  test "differential: a sustained curve builds and HOLDS a turn signal":
    var s = initCogDriveState(East)
    # feed a velocity that keeps rotating CCW so the heading keeps changing (a curve).
    for i in 0 ..< 40:
      let a = float(i) * 0.12                 # travel direction sweeps CCW
      s = stepCogDrive(s, int(Fast * cos(a)), int(-Fast * sin(a)), East)
    # turning left (CCW) => turnAmt goes POSITIVE and is sustained (not collapsed).
    check s.turnAmt > 200
    # and it is decoupled from the body turn rate: the signal persists through the
    # whole curve instead of spiking for one frame and relaxing.

  test "differential: turnAmt sign flips with turn direction":
    var l = initCogDriveState(East)
    var r = initCogDriveState(East)
    for i in 0 ..< 30:
      let a = float(i) * 0.12
      l = stepCogDrive(l, int(Fast * cos(a)), int(-Fast * sin(a)), East)   # CCW / left
      r = stepCogDrive(r, int(Fast * cos(-a)), int(-Fast * sin(-a)), East) # CW / right
    check l.turnAmt > 0
    check r.turnAmt < 0

  test "turnAmt drives the leg articulation (splay sign + inner-leg shorten)":
    # The turn signal is only worth carrying if it reaches the ART. A LEFT (CCW)
    # turn must swing the legs one way and shorten the INNER (left) leg; a RIGHT
    # turn mirrors it. This is the seam where drive state meets the rig bake.
    check rigLegSwingStep(rsLegFL, 1000) > 0
    check rigLegSwingStep(rsLegFL, -1000) < 0
    check rigLegSwingStep(rsHead, 1000) == 0        # non-legs never swing
    # +turnAmt = LEFT/CCW => the LEFT front leg is the inner one and shortens.
    check rigLegShortenStep(rsLegFL, 1000) > 0
    check rigLegShortenStep(rsLegFR, 1000) == 0
    # and mirrored for a right turn.
    check rigLegShortenStep(rsLegFR, -1000) > 0
    check rigLegShortenStep(rsLegFL, -1000) == 0

  test "casters stay replay-deterministic through a curve":
    var a = initCogDriveState(South)
    var b = initCogDriveState(South)
    for i in 0 ..< 40:
      let ang = float(i) * 0.15
      let vx = int(Fast * cos(ang)); let vy = int(-Fast * sin(ang))
      a = stepCogDrive(a, vx, vy, South)
      b = stepCogDrive(b, vx, vy, South)
    check a.casterFR == b.casterFR
    check a.casterFL == b.casterFL
    check a.casterRear == b.casterRear
    check a.turnAmt == b.turnAmt

  test "casters never wander outside a legal brad angle":
    # Every caster is fed into rigCasterStep, which indexes a baked art table.
    # An out-of-range angle there is an art glitch or a range crash, so pin it.
    var s = initCogDriveState(East)
    for i in 0 ..< 60:
      let ang = float(i) * 0.21
      s = stepCogDrive(s, int(Fast * cos(ang)), int(-Fast * sin(ang)), East)
      for caster in [s.casterFL, s.casterFR, s.casterRear]:
        check caster >= 0
        check caster < AimBradsTurn
      check abs(s.turnAmt) <= 1000
