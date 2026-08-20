## The sim's shared vocabulary: the core constants (including GameVersion
## and its changelog), the gameplay/wire types, the process-wide map
## dimension globals, and the pure helpers both sides of every seam need —
## split out of sim.nim (docs/plans/2026-08-01-sim-split.md) so the leaf
## modules (rig_art, arena, map_art, sim_config, sim_state, roster) share
## them without importing gameplay. Leaf modules may declare their own
## section-local consts/types; anything two modules need lives here.
##
## MOVED VERBATIM from sim.nim: SimServer and friends are flatty-serialized
## POSITIONALLY into replay keyframes, so declaration/field order here is
## wire format — reorder nothing without a GameVersion bump.

import
  std/[math, random],
  bitworld/pixelfonts,
  bitworld/server,
  pixie

const
  GameName* = "ctf"
  GameVersion* = "53"  ## GV53 (colony rule): SMELL FOOD; FEED THE QUEEN; GROW.
    ## Emerg-ant is a 1v1 policy duel over neutral food at deterministic-random
    ## walkable field positions. Loose food is globally sensed as scent while
    ## ants and terrain remain local. Each colony begins with one immobile,
    ## crown-and-wings queen plus one worker; each delivery feeds the queen and
    ## wakes one dormant copy of that entrant's policy. Queen death collapses
    ## the colony. Every round has one winner: tied finishes compare food,
    ## living ants, colony health, and contact kills, then seed parity. Guns,
    ## projectiles, pickups, barriers, and barrage are absent; same-tick
    ## mandible damage is simultaneous and requires physical contact.
    ## Claimed after scanning origin on 2026-08-20: main used GV52 and no remote
    ## branch claimed GV53 or above.
    ##
    ## Previously GV52 (pre-NAnts restoration): RETURN TO THE CACHE RAID.
    ## Restores the complete pre-NAnts game snapshot from commit a292bf5:
    ## replenishing enemy food caches, public pheromone trails, contact combat,
    ## and fixed colonies without queens, brood, global food odor, or neural
    ## policy machinery. The NAnts-style v0.6 release remains preserved on the
    ## `nants-v0.6` branch and `v0.6.0-nants` tag. This restores GV44 behavior,
    ## not its already-spent version number; every fixture is re-recorded as
    ## GV52 so new replays cannot be mistaken for historical GV44 recordings.
    ## Claimed after scanning origin on 2026-08-20: main and nants-v0.6 used
    ## GV51, and no remote branch claimed GV52 or above.
    ##
    ## Previously GV44 (Emerg-ant mode): FOLLOW THE TRAIL, RAID THE NEST.
    ## Adds the opt-in `emerg-ant` competitive foraging ruleset. Enemy hearts
    ## become replenishing food caches: returning one to the colony scores a
    ## forage point instead of eliminating its owner, and the first colony to
    ## `forageGoal` wins. A unique score leader also wins at the time limit.
    ## Moving ants deposit public, expiring pheromone marks; nearby opposing
    ## deposits erase one another simultaneously, so the field itself is the
    ## colonies' shared memory without an input-order advantage. The mode is
    ## config-gated and default `ctf` remains behavior-identical, but ant-mode
    ## replays contain new hashed state and cannot run as GV43.
    ## Authored as GV44 after scanning origin on 2026-08-19: main and every
    ## open remote claim at/above main used GV43; no GV44 claim was present.
    ##
    ## Previously GV43 (puddle rule): PUDDLES BITE TWICE AS HARD.
    ## `DefaultPuddleDamagePct` goes 10 -> 20: a full second of continuous
    ## paint-puddle occupancy now rolls a 20% chance of 1 damage instead of
    ## 10%. The default matters because spec-pinned puddles (the campaign's
    ## per-cell maps) ride `mapSpec` with no `puddleDamagePct` in the config,
    ## so their replays echo NO pct key and re-simulate on whatever the
    ## binary's default is — the roll's RNG draw happens on every completed
    ## second regardless of outcome, so the stream is unchanged up to the
    ## first draw in [10,20), where the outcome flips and the sims diverge.
    ## (mapPuddles-knob replays are safe: the echo pins their pct
    ## explicitly.) GV42 spec-pinned puddle replays therefore re-simulate
    ## differently: fixtures re-recorded.
    ##
    ## Previously GV42 (heart rule): STAND ON THE PEDESTAL, TAKE THE
    ## HEART. `FlagPickupRange` goes 12 -> 34, keyed to the drawn art instead
    ## of a bare point: the planted heart is 60px across on a 96px pedestal,
    ## so the old radius demanded the pinpoint CENTER of a target five times
    ## its size. Players and policies stood visibly on the heart and did not
    ## pick it up. GV42 makes the visual promise the mechanical one — heart
    ## pixels under your feet means the steal fires. This is the second half
    ## of the 2026-08-08 fix, which corrected a 28px sprite-center OFFSET but
    ## left the precision demand in place. Steals now happen earlier (and at
    ## all, in cases that used to fail), so no GV41 replay re-simulates:
    ## fixtures re-recorded.
    ##
    ## Previously GV41 (clock rule): NO MORE OVERTIME. The GV23
    ## action floor (kills/heart steals guaranteeing 500 ticks of clock,
    ## banked as overtimeTicks) is removed outright: the clock only ever
    ## counts down, and `maxTicks` is the exact scheduled draw ceiling.
    ## With the grenade-barrage endgame configured the ceiling does not end
    ## the game at all — the bombardment grinds on past 0:00 until at most
    ## one team stands, so a draw needs the last players of two teams to
    ## die on the same tick. overtimeTicks left the hash, so every replay
    ## re-simulates differently: fixtures re-recorded.
    ##
    ## Previously GV40 (aim rule): RESTORE CONTINUOUS TURRET AIM.
    ## `aimBrads` again spans all 256 integer headings, and `aimTurnRate` is
    ## again brads/tick (default 5, ~7 degrees/tick, full turn ~2.1s), exactly
    ## as introduced with decoupled aim. GV36's reinterpretation of the same
    ## config value as 32-way rotation slots made the published value 5 turn
    ## 40 brads/tick, overshooting bot targets and trapping held actions.
    ## GV39 replays do not re-simulate under the restored aim arithmetic.
    ##
    ## GV39 (map format): QUAD-MIRROR SYMMETRY — 4-team
    ## maps may be RECTANGULAR. A new `symQuadMirror` map symmetry authors the
    ## TOP-LEFT quadrant and completes the board by reflecting it across both
    ## center axes (mirrorX, mirrorY, and their composition rot180 — the
    ## Klein four-group), instead of rot90's quarter turns, which demand a
    ## square. Reflections preserve congruence exactly, so team fairness stays
    ## bit-exact; mirror-image spinning diamonds counter-rotate (the rot180
    ## image co-rotates). Default 4-team draws stay rot90/square; the
    ## "quadmirror" mapSymmetry override opts a map in. Older viewers cannot
    ## parse "quadmirror" specs.
    ##
    ## GV38 (spray rule): THE SPRAY IS ONE DIRECTIONAL
    ## SHOT, NOT A SWEEP. A fired cone locks its aim at the fire instant and
    ## points that way for its whole active window (`arcAimBrads`): turning the
    ## cog mid-spray no longer rotates the cone across a fan of targets. The
    ## cone's ORIGIN still rides its owner, so a moving sprayer drags the stream
    ## forward — only the rotation is pinned. GV37 replays do not re-simulate.
    ##
    ## GV37 (obstacle format): map obstacles and trenches
    ## may be `polygon` shapes (integer vertex rings), so curved / organic
    ## terrain is authorable. Older viewers cannot parse the new spec kind.
                       ## GV36 (superseded by GV40): the aim angle was changed
                       ## to one of 32 discrete slots (8 brads
                       ## = 11.25 deg apart), the classic fixed-rotation-count
                       ## scheme. A held rotate button steps whole slots
                       ## (aimTurnRate slots/tick, default 1); spawn aims sit
                       ## on the grid; there are no finer-grained aim angles.
                       ## Brads remain the wire unit — aim values are now
                       ## always multiples of 8. Shot jitter and the cosmetic
                       ## render fuzz are unchanged and apply on top.
                       ##
                       ## GV35 (stats rule): ELIMINATION DEATHS ARE NOT
                       ## COMBAT DEATHS. When a team's heart is captured
                       ## (GV32) every player on that team still dies with
                       ## no respawn, but the fold no longer increments the
                       ## per-player deaths stat and no longer logs a
                       ## per-player "killed by" line — nobody shot these
                       ## players; the team lost. The endscreen's D column,
                       ## the reward-account stat lines, and the killfeed
                       ## markers diffed from the deaths counter all stay
                       ## records of combat only. The captor was never
                       ## credited kills for the fold (kills are credited
                       ## at weapon damage sites), so K already read clean.
                       ## The deaths counter is hashed state, so GV34
                       ## capture-ending replays do not re-simulate.
                       ##
                       ## GV34 (operator rule): THE GUN HAS ONE REAL RANGE,
                       ## ITS AIM IS FUZZED, AND SIGHT REACHES 1.5x AS FAR.
                       ## Three coupled changes:
                       ## 1. Every map def ships the same fixed gunRange —
                       ## 1050 px, the SMALL generated map's field width —
                       ## instead of scaling it with the field (1300 arena,
                       ## 1690 arena-large, up to 3380 giant). The gun is
                       ## map-wide only on the smallest board; on anything
                       ## larger paint falls short and closing distance
                       ## matters. League configs can still override
                       ## gunRange per game; old replays carry their own
                       ## recorded value.
                       ## 2. Each RELEASED shot's direction gets Gaussian
                       ## angular noise on the deterministic sim RNG,
                       ## calibrated from the live gunRange so a FULLY
                       ## VISIBLE body at MAX range is hit exactly 80% of
                       ## the time (~0.6 degrees sigma at 1050 px; ~99% at
                       ## half range, ~100% close in — see AimJitterCentralZ
                       ## for the derivation). The fuzzed direction drives
                       ## target selection AND the tracer/stain march, so
                       ## the paint flies where the roll says; events keep
                       ## the intended locked heading. The extra RNG draw
                       ## per shot shifts every later roll, so GV33 replays
                       ## do not re-simulate.
                       ## 3. The vision CONE cuts off at 1.5x the gun range
                       ## (visionRange, 1575 px stock — it was unlimited,
                       ## LOS permitting): sight outranges paint by half
                       ## again, and both scale together under a config
                       ## override. The close-quarters bubble is exempt.
                       ## The first-person strip's wall march follows
                       ## visionRange too. Broadcast-only (fog never enters
                       ## the hash), but bot behavior depends on what bots
                       ## see, so the fixtures are re-recorded with it in.
                       ##
                       ## GV33 (dead-team rule): A DEAD TEAM'S HEART LEAVES
                       ## PLAY. A team wiped from the field (no live player
                       ## and no lives left) has its heart retired on the
                       ## spot exactly like a captured one — including a
                       ## heart riding an enemy carrier's back, which drops
                       ## from the carrier (freeing their speed and fire
                       ## rate) instead of lingering as a live-looking
                       ## objective nobody can score. Retired hearts also
                       ## stop DRAWING entirely (GV32 left a captured heart
                       ## lying flat where it fell): a dead team keeps its
                       ## dim pedestal, but no heart anywhere on the board.
                       ## The retire flips hashed flag state on wipes, so
                       ## GV32 replays do not re-simulate.
                       ##
                       ## GV32 (4ffa rule): A CAPTURE ELIMINATES, THE LAST
                       ## TEAM STANDING WINS. Capturing a heart no longer
                       ## ends the game outright: the captured team is
                       ## eliminated on the spot (every player dies with no
                       ## respawn) and its heart leaves play where it was
                       ## captured. The game ends when at most one team
                       ## still stands — a 4-team winner has to capture all
                       ## three rival hearts or outlive the field. Classic
                       ## 2-team play is unchanged in outcome (eliminating
                       ## the only rival ends the game on the first
                       ## capture), but the end-state differs (losers dead,
                       ## heart retired), so GV31 replays do not re-simulate.
                       ##
                       ## GV31 (operator rule): WEAPONS HIT BODIES, NOT
                       ## POINTS. Three changes, all closing the same gap —
                       ## paint visibly covering a cog that walked away clean.
                       ## 1. The cone hits BODIES, not center points: a victim
                       ## is tested as a disc of PlasmaArcBodyRadius (half a
                       ## cog), where it used to be the bare point its 1px
                       ## collision box describes. Largest effect point-blank,
                       ## where the cone was narrower than the cog it covered.
                       ## 2. The reach grew 4 -> 5 squares, with the width
                       ## grown to match so the 14-degree half-angle did NOT
                       ## change. The 5th square is exactly what it takes to
                       ## cover the tip of the plume the game draws: the mist
                       ## is a chain of round puffs drawn oversize so they
                       ## merge, so it always reached past the cone that sized
                       ## it. test_plasma_arc pins the containment.
                       ## A cog can still be grazed by the plume's edge
                       ## without damage (the overlap makes the mist ~15px
                       ## wider than the cone); closing that too would need a
                       ## 31-degree cone, which is a different weapon.
                       ## 3. The GRENADE BLAST catches a cog whose SOLID BODY
                       ## BOX (±PlayerHalf) touches the blast circle, not
                       ## merely one whose position point falls inside it —
                       ## the same point-vs-body gap as (1), in the last
                       ## weapon that still had it. The gun already sampled
                       ## its bullet corridor across ±PlayerHalf, so once the
                       ## cone hits bodies the blast is the lone hold-out, and
                       ## a cog visibly standing in the splat could take
                       ## nothing. On-axis reach is now GrenadeBlastRadius +
                       ## PlayerHalf (58px); the radius constant and the splat
                       ## art are unchanged, so the splat now slightly
                       ## UNDER-sells its reach (the mirror of the plume's
                       ## overhang in (2)).
                       ## NOTE "body" is deliberately two sizes here: the cone
                       ## uses the DRAWN body (PlasmaArcBodyRadius, 17px)
                       ## because its whole point is covering visible paint,
                       ## while the gun and the blast use the SOLID footprint
                       ## (PlayerHalf, 6px) they have always used. Widening
                       ## the blast to the drawn body would take it from +31%
                       ## to +76% effective area, which is a balance change,
                       ## not a consistency fix.
                       ## GV30 (operator rule): every team's shield and spray
                       ## can is RED's spot carried over by the map's OWN
                       ## symmetry, not by a mirror. Mirroring a pickup on a
                       ## rot180 board lands it in the rotation of Red's OTHER
                       ## pickup, so Blue fought for a shield sitting in the
                       ## cans' terrain — different cover, different sightlines
                       ## to the same item. The 4-team boards had the rot90
                       ## version of the same bug (a mirrored copy lands in the
                       ## TRANSPOSE of Red's surroundings). Pickup positions
                       ## move on every map, including the hand-authored
                       ## arenas, so replays recorded under GV29 no longer
                       ## reproduce and the fixtures are re-recorded.
                       ## GV29 (operator rule): live spinning-diamond geometry
                       ## extends to GENERATED terrain, fairly. Selection is
                       ## closed under each map's symmetry group (a cross on
                       ## rot90 maps, where a vertical band is not invariant),
                       ## and spin DIRECTION follows it too: reflections turn
                       ## image diamonds opposite ways, rotations turn them
                       ## together. validateGeneratedMap now bounds the turn
                       ## from both sides, which re-curated the map pool.
                       ## GV28 (operator rule): on the HAND-AUTHORED arenas
                       ## the spinning center diamonds are REAL GEOMETRY, not
                       ## decoration. Their collision, bullet, and vision
                       ## footprint is the rotated diamond the art draws —
                       ## recomputed whenever the spin frame advances
                       ## (DiamondSpinTicksPerFrame) — so cover you can see is
                       ## cover you get, and a corner that has swept past no
                       ## longer stops a shot. The rotation is derived from
                       ## tickCount, so replays and every viewer agree; a
                       ## player the sweep would engulf is pushed to the
                       ## nearest free floor, never onto another body.
                       ## Generated terrain (pool/gen, and so every 4-team
                       ## map) keeps the GV27 baked static diamonds — see
                       ## isSpinningDiamond for why.
                       ## GV27 (operator rule): the default arena's
                       ## column-1 glass windows alternate from both ends
                       ## (stone, glass, stone, glass) — stubs 2, 4, and 6
                       ## of 7 (y=108, 300, 491), a top/bottom-symmetric
                       ## set replacing GV26's stubs 2, 5, 6; x-mirrored
                       ## like every column-1 shape.
                       ## TRENCHES are CONFIG-GATED and ship without a
                       ## version bump, exactly like procedural terrain:
                       ## the default arena has none, so its rules are
                       ## byte-identical, and a league opts in through its
                       ## own config (generated maps place pits per seed;
                       ## mapPits/mapPitDensity steer them). A trench is a
                       ## walkable dug-pit square — never a wall to
                       ## movement, bullets, or vision. Dropping in and
                       ## moving around inside are full speed; CLIMBING OUT
                       ## (motion away from the pit's center while inside)
                       ## is 1/5 speed (TrenchSpeedDivisor). Occupants fire
                       ## at 1/3 rate (TrenchFireSlowdown,
                       ## max-composed with the shield/carrier multiplier),
                       ## and TrenchMissPct percent of gun shots that would
                       ## hit an occupant fly straight over instead — the
                       ## bullet continues down the ray and can hit a body
                       ## behind (shots from inside the same trench are
                       ## exempt). Replays pin the exact trench set via
                       ## mapSpec, so playback is exact either way.
                       ## Procedural terrain itself (mapPath "gen"/"pool",
                       ## curated pool in map_pool.nim) is CONFIG-GATED and
                       ## shipped without a version bump: the default arena
                       ## layout is unchanged, and a league that enables it
                       ## does so through its own config. Replays carry the
                       ## exact geometry (mapSpec) either way.
                       ## GV26 (three operator rules): (a) the SELF marker
                       ## renders TRUE aim again — the fuzz hides OTHERS'
                       ## aim, never your own state; (b) HEART carriers fire
                       ## at 1/3 rate (CarrierFireSlowdown, shield-pattern);
                       ## (c) column-1's FIFTH vertical bar (y=395 +
                       ## x-mirror) is a glass window.
                       ## GV25: dead players respawn at a RANDOM spot in
                       ## their endzone (uniform over the home capture
                       ## column, deterministic sim RNG) — a fixed respawn
                       ## point can no longer be camped.
                       ## GV24: soldier sprites in PLAYER views render with
                       ## FUZZED gun rotation (±~20°, deterministic, both
                       ## sides, self included) — exact aim is never readable
                       ## off a sprite; broadcast board unaffected.
                       ## GV23: a depleted shield layer breaks the shield
                       ## outright (icon + fire slowdown end with the bubble).
                       ## (GV23 also floored the clock on kills/steals; that
                       ## action-floor overtime was removed in GV41.)
  ReplayFps* = 24
  DefaultMapPath* = "arena"
  DarkBgPath* = "data/darkbg.aseprite"
  SpriteSheetAsepritePath* = "data/spritesheet.aseprite"
  SpriteSize* = 12
  CrewSpriteSize* = 16
  CrewSpriteVariants* = 8
  ## HD top-down soldier: the real Cogs-vs-Clips cog, one tinted master per team
  ## (soldier_red/blue.png, facing SOUTH, smile visor visible) plus the shared
  ## paintball gun master (paintgun.png, muzzle east). Body and gun are mounted
  ## as ONE rigid unit — the gun held in FRONT of the face, both pointing the
  ## same way — and pre-rotated together through SoldierRotations aim steps:
  ## the cog looks where it aims. The canvas is larger than the body only so
  ## the extended gun never clips as the unit rotates. Emitted through the
  ## existing player sprite id pool (16 ids per color) — this replaces the
  ## flat 8-variant + h-flip crew.
  SoldierRotations* = 16      ## pre-rendered aim steps (16 brads apart).
  SoldierCanvas* = 72         ## px square sprite canvas (fits the swinging gun).
  SoldierBodyPx* = 34         ## cog body target size on the map (full-body unit).
  GunLengthPx* = 34           ## top-down gun master length on the map (stock-tip to
                              ## muzzle, along the aim ray).
  GunGripPx* = -13            ## gun stock-tip offset from the body center, along
                              ## aim (negative = stock sits behind the hub so the
                              ## barrel reaches out front, marker straddling the cog).
  GunRightPx* = 10            ## the marker is held at the cog's RIGHT: barrel
                              ## centerline offset this far off the aim ray, toward
                              ## the head's right (screen +y when facing +x/east).
                              ## Enough to clear the head silhouette and read as a
                              ## distinct held object, without floating far off.
  GunGlowRadius* = 0.6        ## px blur (master-frame): tiny, so the rim is CRISP —
                              ## an outline stroke, not a soft glow.
  GunGlowSpread* = 1.0        ## px the silhouette expands before blurring — this is
                              ## the outline WIDTH that sticks out past the gun edge.
  GunGlowAlpha* = 95'u8       ## faint warm outline (0..255), reads as a subtle stroke.
  SprayHeldLengthPx* = 22     ## the held spray can's length on the map, along the
                              ## aim ray. Shorter than the marker (GunLengthPx):
                              ## a can is a fistful, and the silhouette difference
                              ## is what tells a viewer WHICH weapon a cog holds.
  SprayHeldGripPx* = -6       ## can tail offset from the body center along aim.
                              ## Less negative than GunGripPx so the short can
                              ## sits IN the fist rather than straddling the hub.
  CollisionW* = 1
  CollisionH* = 1
  PlayerHalf* = 6             ## half-extent of the solid player footprint, in px.
  ## Draw offset for the soldier: place the canvas so its center lands on
  ## the player position (canvas center = the body pivot).
  SoldierDrawOff* = SoldierCanvas div 2
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan* = 3
  PlayerSolidSpan* = 2 * PlayerHalf  ## centers this close (Chebyshev) means
                                     ## two player footprints overlap.
  PlayerBouncePct* = 40       ## restitution of player-player collisions, in
                              ## percent: 0 = a dead-stop shove, 100 = a
                              ## perfectly elastic billiard bounce.
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## Replay/live playback speed steps (as multiples of real time). Lives in
    ## sim (not replays) so every layer that must agree with the top speed —
    ## the transport keymap, global.nim's cog-drive smoothing window, the JS
    ## clients' wire constants — derives from ONE table.
  SpaceColor* = 0'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8

  # CTF tuning defaults (RULES.md). Second-based values convert at 24 ticks/sec.
  Lives* = 3
  HitPoints* = 3              ## hits to kill: each shot removes one hit point.
  RespawnTicks* = 72          ## ~3s before respawning at home.
  GunRange* = 1050            ## px, the SMALL generated map's field width
                              ## (round(1235 * 0.85)) — the ONE fixed gun
                              ## range every map def ships (GV34): map-wide
                              ## only on the smallest field, so on larger
                              ## maps paint falls short and closing distance
                              ## matters. A league config can still override
                              ## it per game (config gunRange).
  AimJitterCentralZ* = 1.2815516  ## Phi^-1(0.90): 80% of a Gaussian lies
                              ## within +-z*sigma. The released-shot jitter's
                              ## sigma is asin((PlayerHalf + BulletHalfWidth)
                              ## / gunRange) / this, which is exactly "a
                              ## fully visible body at max range is hit 80%
                              ## of the time" — the +-14px acceptance window
                              ## the corridor gives a centered silhouette,
                              ## spanned by 1.28 sigma of angular error at
                              ## gunRange px out (GV34). Derived from the
                              ## LIVE config.gunRange so a range override
                              ## keeps the calibration; at the stock 1050 px,
                              ## sigma is ~0.6 degrees, and a fully visible
                              ## body is hit ~99% at half range, ~100% inside
                              ## a third.
  ExposureSampleStep* = 3     ## px between silhouette line-of-sight samples
                              ## across a target's body (±PlayerHalf): only
                              ## the exposed part of a body can be hit.
  BulletHalfWidth* = 8.0      ## the bullet corridor half-width: a shot travels
                              ## along the facing ray and hits the FIRST player
                              ## whose footprint crosses it.
  FireCooldownTicks* = 12     ## ~0.5s between shots.
  FireWindupTicks* = 5        ## ~0.2s from trigger pull to the shot; aim locks
                              ## at the pull, so a peeking target can duck back.
  ShotFxTicks* = 12           ## ~0.5s a shot tracer stays visible (cosmetic only).
  HitFlashTicks* = 8          ## ~0.33s the struck-target flash rings a victim
                              ## in the spectator view (cosmetic only).
  SplatterFxTicks* = 120      ## ~5s a death splatter stays visible (cosmetic only).
  HitFxTicks* = 34            ## ~1.4s a non-fatal hit's paint splat stays visible.
  StainChancePct* = 100       ## % of paint landing on TERRAIN that dries into a
                              ## permanent stain. 100 = every miss marks the wall
                              ## it hit, so the lanes players actually run get
                              ## visibly repainted over a match; lower it to thin
                              ## the buildup. Cosmetic only, never in gameHash.
  StainSeatDepth* = 6         ## px a wall stain is pushed past the wall's
                              ## leading edge so the masked blot lands on the
                              ## face rather than half-overhanging the floor.
  StainMaxCount* = 1200       ## most dried stains kept for a match. A 5000-tick
                              ## game with 16 cogs firing every FireCooldownTicks
                              ## tops out near 6600 shots, so this caps unbounded
                              ## growth (and the wire) while still reading as
                              ## "this corridor is covered in paint". Oldest wins:
                              ## once full, new paint stops sticking rather than
                              ## evicting the history the viewer already saw.
  DamageFxTicks* = 26         ## ~1.1s a floating "-1" damage pop rises and fades
                              ## after a hit (cosmetic only, never in gameHash).
  KillFxTicks* = 44           ## ~1.8s a floating "KO" kill marker rises and fades
                              ## after a death (cosmetic only, never in gameHash).
  CarrierSpeedPct* = 70       ## carrier moves at 70% speed.
  AimBradsTurn* = 256         ## aim angle units per full turn (binary radians).
  AimTurnRate* = 5            ## brads/tick a held rotate button turns the aim
                              ## (~7 deg/tick; a full turn takes ~2.1s).
  VisionConeDeg* = 60         ## vision cone half-angle around the aim angle.
  VisionBubble* = 90          ## omnidirectional vision radius in px.

  FovCellSize* = 8            ## fog-of-war visibility grid cell size in px.

  StartWaitTicks* = 5 * TargetFps
  GameOverTicks* = 360
  MaxTicks* = 7_200  ## a 5:00 game at 24 ticks/sec; 0 = no limit.
  BarrageStartSec* = 30       ## grenade-barrage default: the barrage latches
                              ## on with this many clock seconds remaining
                              ## (config barrageStartSec; the mode itself
                              ## arms via barrageMaxPerSec > 0). On the
                              ## default 5:00 clock that is 4:30 elapsed.
  BarrageSaturateSec* = 30    ## grenade-barrage default: seconds from the
                              ## latch to full saturation (whole board at
                              ## barrageMaxPerSec). Start 30 + saturate 30
                              ## = fully saturated exactly at 5:00 on the
                              ## default clock.
  BarrageStartPerSec* = 4     ## grenade-barrage default: launch rate at the
                              ## latch, grenades/second along the map edges.
  BarrageAbsMaxPerSec* = 50   ## config ceiling on barrageMaxPerSec: keeps
                              ## the concurrent airborne count (rate x the
                              ## ~10-tick flight) inside the drawn-orb pool.
  BarrageEdgeBandPx* = 40     ## the strip of map inside every edge the
                              ## barrage targets at latch; the band deepens
                              ## linearly to full coverage as the ramp
                              ## completes.
  MaxGames* = 0  ## 0 = no limit.
  MaxPlayers* = 32
  MinPlayers* = 16

  WinReward* = 1              ## each winner scores +1 on capture or wipe.
  LossReward* = -1            ## each loser scores -1 on capture or wipe.
  ClassicScoring* = "classic" ## winner +1 per losing team, each loser -1.
  PotScoring* = "pot"         ## every team antes one point; the winning team
                              ## takes the whole pot and the losing teams
                              ## split the forfeit (see potScoring below).
  CtfMode* = "ctf"
  EmergAntMode* = "emerg-ant"
  DefaultForageGoal* = 5       ## returned enemy food caches needed to win.
  FoodPickupRange* = 16        ## touch radius for a wild food patch. Derived
                               ## from the rendered 20px FoodPatchSize: its
                               ## 10px half-extent plus PlayerHalf means a
                               ## touching ant footprint collects it.
  FoodSpawnMargin* = 28        ## minimum map-edge inset for random food.
  FoodSpawnNestClear* = 96     ## food never appears inside/against a nest.
  FoodSpawnSeparation* = 80    ## distinct loose patches do not overlap.
  FoodSpawnAttempts* = 512     ## bounded random placement before scan fallback.
  ContactAttackRange* = PlayerSolidSpan + 1
                               ## centers at this Chebyshev distance have
                               ## adjacent/touching solid footprints; farther
                               ## ants cannot damage one another.
  ContactAttackDamage* = 1     ## one hp per mandible strike.
  InitialAntsPerColony* = 2    ## one fixed queen + one founding forager.
  BroodFoodCost* = 1           ## every delivered food hatches one reserve ant.
  PheromoneStepTicks* = 24     ## a moving ant deposits at most once per second.
  PheromoneLifetimeTicks* = 24 * 30  ## public trail memory lasts 30 seconds.
  PheromoneEraseRadius* = 18   ## opposing deposits this close neutralize.
  MaxPheromoneMarks* = 512     ## deterministic oldest-first trail cap.
  TimeoutReward* = -1         ## EVERY player scores -1 on a time-limit draw
                              ## (GameVersion 21): stalling out the clock is
                              ## never better than losing, for either side.

  FlagPickupRange* = 34       ## touch radius to steal the enemy flag: STAND ON
                              ## THE PEDESTAL AND THE HEART IS YOURS (GV42).
                              ## The grab radius is deliberately keyed to the
                              ## art a player aims at, not to a bare point.
                              ## The planted heart is drawn 60px across
                              ## (PlantedFlagW) on a 96px pedestal disc
                              ## (PedestalCoverSize), so 30px is the drawn
                              ## heart's own half-extent: anywhere a player
                              ## can see heart pixels under their feet now
                              ## grabs. The old 12px was a quarter of the
                              ## pedestal and a fifth of the heart — it asked
                              ## for the exact pinpoint center of a big
                              ## target, so humans and policies alike stood
                              ## visibly ON the heart and did not pick it up
                              ## (the 2026-08-08 sprite-center fix removed a
                              ## 28px OFFSET; this removes the remaining
                              ## precision demand). The +4 past the heart's
                              ## half-extent covers the body half-extent
                              ## (PlayerHalf = 6) partway, so a footprint
                              ## overlapping the art counts as a touch. The
                              ## radius stays well inside the pedestal's own
                              ## protected spawn pocket on EVERY size class —
                              ## the tightest is "small", whose 0.85 factor
                              ## puts the pocket half-width at 60px (70 on
                              ## standard) — so a grab never reaches through
                              ## a wall, and an attacker still has to enter
                              ## the pocket to steal. Unlike the field, the
                              ## heart and pedestal art never scale, so the
                              ## art-derived radius must not either.
  CaptureZoneWidth* = 40      ## width of each home-edge capture zone.
  PedestalCoverSize* = 96     ## px footprint the flag-home pedestal art covers.

  ClassicHomeDepth* = 700     ## the historical home-anchor depth permille:
                              ## the base 30% of the way in from its edge.
  HomeDepthMin* = 400         ## depth bounds. Below the floor the bases
  HomeDepthMax* = 800         ## crowd the center; above it they clip the
                              ## border.
  EndzoneRadiusMin* = 90      ## compact-endzone radius bounds. The floor
  EndzoneRadiusMax* = 220     ## keeps the pedestal art and its endzone pits
                              ## inside the zone; the ceiling keeps the two
                              ## zones clear of the center ring ON THE
                              ## STANDARD 1235-WIDE FIELD — wider boards get
                              ## a proportionally larger ceiling, see
                              ## maxEndzoneRadius.
  EndzoneWallMargin* = 6      ## px of protected floor past the scoring ring,
                              ## the compact echo of the classic column's
                              ## 210-clear vs 206-threshold gap.

  GrenadeSpawnInset* = 40     ## corner grenade spawn inset from the border.
  GrenadePickupRange* = 12    ## touch radius to pick a grenade up.
  GrenadeRespawnTicks* = 5 * ReplayFps  ## a taken corner refills after 5s.
  GrenadeMinRange* = 30       ## a tap's distance: inside the blast radius,
                              ## so a panicked drop can hurt the thrower.
  GrenadeChargeTicks* = 24    ## hold this long for a full-strength throw.
  GrenadeFlightMultiple* = 2  ## release-to-burst = this many shot windups,
                              ## REGARDLESS of distance: a grenade is a snap
                              ## weapon, not a mortar shell you can stroll
                              ## away from. (Was 6 px/tick of flight — a
                              ## full-range lob hung airborne ~41 ticks.)
  GrenadeBlastRadius* = 52    ## everyone whose SOLID BODY BOX (±PlayerHalf)
                              ## touches this circle takes damage — a body
                              ## test, not a position-point test (GV31), so
                              ## on-axis reach is 52 + PlayerHalf = 58 px.
                              ## (GameVersion 17: 40 -> 52, +30%.)
  GrenadeDamage* = 2          ## hit points removed by one blast, for a
                              ## victim standing outside any trench.
  GrenadeTrenchDamage* = 6    ## a blast that lands in the SAME trench as its
                              ## victim: the pit traps the blast, amplifying it.
  GrenadeTrenchSplashDamage* = 1  ## a victim in a trench, hit by a blast that
                              ## landed elsewhere (open field or another
                              ## trench): the pit mostly shields them.
  BlastFxTicks* = 12          ## cosmetic blast flash duration in ticks.

  MedKitPickupRange* = 12     ## touch radius to pick a med kit up.
  MedKitRespawnTicks* = 30 * ReplayFps  ## a taken kit refills after 30s.
  PlasmaArcSpawnInset* = GrenadeSpawnInset
  PlasmaArcPickupRange* = 12  ## touch radius to pick a plasma arc up.
  PlasmaArcRespawnTicks* = 30 * ReplayFps
  PlasmaArcSquare* = SoldierBodyPx  ## one "square": a cog body length.
  PlasmaArcFxReach* = 4 * PlasmaArcSquare
                              ## how far the DRAWN plume spans, and the span
                              ## its puffs are sized against. This is art
                              ## geometry, not damage: the mist is a chain of
                              ## round puffs drawn oversize so they merge
                              ## (SprayPuffOverlap), so its outermost pixel
                              ## lands well past this. The damage reach below
                              ## is set to cover that overhang — see
                              ## test_plasma_arc's containment check, which is
                              ## what keeps the two in step if either moves.
  PlasmaArcFxMaxWidth* = 2 * PlasmaArcSquare
                              ## the drawn plume's width at PlasmaArcFxReach.
  PlasmaArcReach* = 5 * PlasmaArcSquare  ## forward cone reach: 5 squares
                              ## (GameVersion 30, was 4). The 5th square is
                              ## not extra range for its own sake — it is
                              ## exactly what it takes for the damage cone to
                              ## cover the tip of the plume the game draws, so
                              ## a cog the paint engulfs cannot walk away
                              ## clean.
  PlasmaArcMaxWidth* = 5 * PlasmaArcSquare div 2  ## cone width AT max reach:
                              ## 2.5 squares, which holds the half-angle at
                              ## atan(1/4) ~ 14.0 degrees everywhere along the
                              ## reach as the reach grew. The cone widens
                              ## linearly from the muzzle.
  PlasmaArcBodyRadius* = SoldierBodyPx div 2
                              ## the sprayed cog's own half-width, added to the
                              ## cone on every side (GameVersion 30). Reach and
                              ## width above describe the cone's CENTERLINE
                              ## geometry, and a victim used to be tested as a
                              ## bare point (CollisionW is 1px) — so paint could
                              ## visibly engulf a 34px body that took no damage,
                              ## worst of all point-blank, where the centerline
                              ## cone is narrower than the cog it covers (10px
                              ## to each side at 40px out). Spraying a body now
                              ## hits it: the test is the cog's DISC against the
                              ## cone, not its center point.
  PlasmaArcDamage* = 3        ## hit points removed by one cone touch:
                              ## instantly lethal to a bare cog (3 hp), but a
                              ## shield carrier (6 hp) survives the first one.
  PlasmaArcActiveTicks* = 5   ## a fired cone stays on this many ticks,
                              ## tracking the attacker's position and aim.
  PlasmaArcResetTicks* = 20   ## recharge time after the cone shuts off; the
                              ## refire cadence is ActiveTicks + ResetTicks.
  PlasmaArcFxTicks* = 4       ## each per-tick cone snapshot fades this long
                              ## (cosmetic only).

  ShieldPickupRange* = 12     ## touch radius to pick a shield up.
  ShieldRespawnTicks* = 30 * ReplayFps  ## a taken endzone shield refills after 30s.
  ShieldLayerHp* = 3          ## hp in a full shield layer. Damage depletes
                              ## the layer before base hp; a pickup refills it
                              ## and never heals base damage.
  ShieldFireSlowdown* = 3     ## a shield carrier's fire cooldown is this many
                              ## times longer (3x slower fire rate).
  CarrierFireSlowdown* = 3    ## a HEART carrier's fire cooldown multiplier
                              ## (GV26): carriers can shoot, at a third the
                              ## rate. Shield+heart do not stack (max, not
                              ## product).

  BarrierPickupRange* = 12    ## touch radius to pick a cardboard barrier up.
  BarrierRespawnTicks* = 30 * ReplayFps  ## a taken barrier pickup refills after 30s.
  BarrierHp* = 10             ## paintball hits a placed barrier soaks before
                              ## it is gone. Only the gun chips it; the spray
                              ## cone is merely blocked, and grenades fly
                              ## over it like every other obstacle.
  BarrierRadius* = 24         ## half-hex circumradius in px: the distance
                              ## from the placement center (the placer's own
                              ## center) to each of the four vertices. The
                              ## flat middle side sits at the apothem
                              ## (~0.87R = 21px) straight down the placer's
                              ## aim, so the cardboard wraps their front.
  BarrierHalfThick* = 2       ## half-thickness of the cardboard band: a map
                              ## pixel within this distance of one of the
                              ## three sides is covered (band ~5px wide, so
                              ## a 1px-stepped paint ray can never lace
                              ## through it diagonally).
  MaxBarriersPlaced* = 16     ## most placed barriers standing at once
                              ## (sizes the render pools); placing past the
                              ## cap flattens the OLDEST standing barrier.
  MaxBarrierPickupsPerTeam* = 2  ## cap on the barrierPickups config knob.

  TrenchSize* = 56            ## side length of the walkable trench square
                              ## open flag ring (corner reach ~40px < the
                              ## 70px ring), so it never touches a wall.
  TrenchSpeedDivisor* = 5     ## CLIMBING OUT is 1/5 speed: while the center
                              ## is inside a pit, any axis motion pointing
                              ## AWAY from the pit's center has its cap and
                              ## accel divided by this, and outward momentum
                              ## sheds to the cap. Dropping in, crossing,
                              ## and moving around the pit are full speed.
  TrenchFireSlowdown* = 3     ## an occupant's gun fire cooldown multiplier
                              ## (1/3 fire rate). Max-composed with the
                              ## shield/carrier slowdown, never the product —
                              ## same rule as shield+heart (GV26).
  TrenchMissPct* = 70         ## percent of gun shots that would hit a trench
                              ## occupant that fly straight over instead
                              ## (deterministic sim RNG); the bullet carries
                              ## on down the ray. Shots fired from inside the
                              ## same trench never miss this way.

  PuddleSize* = 64            ## nominal diameter of a paint-puddle splat
                              ## (the core disc; lobes reach a little
                              ## further — see arena.nim's PuddleMaxRadiusPx).
                              ## Like obstacles and trenches, puddles never
                              ## scale with the map's size class.
  PuddleRollTicks* = TargetFps  ## one damage roll per full SECOND of
                              ## continuous puddle occupancy (24 ticks).
  DefaultPuddleDamagePct* = 20  ## default percent chance the per-second
                              ## occupancy roll deals 1 damage.
                              ## (GameVersion 43: 10 -> 20, 2x.)
  MaxPuddles* = 64            ## hard cap on mapPuddles requests, matching
                              ## the trench cap (and sizing the stated-marker
                              ## sprite/object pool).

  BubbleImpactTicks* = 8      ## ~0.33s the bubble's blink/dent impact FX
                              ## lasts (cosmetic only, like HitFlashTicks).

  ShoutMaxChars* = 10         ## a shout is at most this many characters.
  ShoutTicks* = 3 * ReplayFps ## a shout stays observable this long.
  ShoutCooldownTicks* = ReplayFps  ## at most one shout per second.

  TextLineHeight* = 7
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  ScoreboardLayerId* = 1       ## left roster panel (red; +green on 4-team maps).
  ScoreboardLayerType* = 1     ## top-left anchor.
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  FlagSpriteBase* = 700       ## team flag sprites: 700..703 by team.
  SelectedPlayerSpriteBase* = 6000  ## outlined selected-soldier pool:
                              ## 4 teams x 16 rotations per skin — default
                              ## 6000..6063, crown 6064..6127. Moved from
                              ## 800: that pool swallowed the hp pips
                              ## (820..823) and the sound/impact rings
                              ## (830/831) — same collision class as the
                              ## 2026-07-22 unit-tag/fire-icon incident.
  PlayerObjectBase* = 1000
  SelectedTextObjectId* = 4000
  PlayerColors* = [
    3'u8,
    7,
    8,
    14,
    4,
    11,
    13,
    15,
    1,
    2,
    5,
    6,
    9,
    10,
    12,
    0
  ]
  PlayerColorNames* = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]
  ## Team colors: Red team = palette red (3), Blue team = palette blue (13),
  ## Green team = palette green (10), Yellow team = palette yellow (8).
  RedTeamColor* = 3'u8
  BlueTeamColor* = 13'u8
  GreenTeamColor* = 10'u8
  YellowTeamColor* = 8'u8
  ShadowMap* = [
    0'u8,  #  0 black       -> black
    12,    #  1 gray         -> dark navy
    9,     #  2 white        -> dark teal
    5,     #  3 red          -> dark brown
    5,     #  4 pink         -> dark brown
    0,     #  5 dark brown   -> black
    5,     #  6 brown        -> dark brown
    5,     #  7 orange       -> dark brown
    5,     #  8 yellow       -> dark brown
    12,    #  9 dark teal    -> dark navy
    9,     # 10 green        -> dark teal
    9,     # 11 lime         -> dark teal
    0,     # 12 dark navy    -> black
    12,    # 13 blue         -> dark navy
    12,    # 14 light blue   -> dark navy
    9,     # 15 pale blue    -> dark teal
  ]
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

## Runtime map state. The game supports multiple arenas ("arena" is the
## default, "arena-large" the 30%-larger variant); one is selected per
## process by loadCtfMap (driven by config.mapPath) BEFORE any sim, mask,
## or render work happens, and never changes afterward — the render bakes
## in global.nim rely on that per-process invariant. The values below are
## initialized to the default arena so tools that never call loadCtfMap
## keep working unchanged.
var
  MapWidth* = 1235
  MapHeight* = 659
  FovGridW* = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH* = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount* = FovGridW * FovGridH
  GrenadeMaxRange* = MapWidth div 5  ## max throw distance (full charge).
  ShoutRange* = MapWidth div 5  ## audible within 20% of the screen width.

type
  Team* = enum
    ## The first two members are the classic pair; a game's ACTIVE teams are
    ## always a prefix of this enum (`Red .. Team(teamCount - 1)`), so every
    ## 2-team code path sees exactly the members it always did.
    Red
    Blue
    Green
    Yellow

  TeamLayout* = enum
    ## Where the teams live on the map. `layoutSides` is the classic 2-team
    ## left/right arena; the two 4-team layouts put a team in each corner or
    ## at the end of each arm of a plus.
    layoutSides
    layoutCorners
    layoutPlus

  Skin* = enum
    DefaultSkin
    CrownSkin

  Perk* = enum
    ## Named, icon-badged team buffs (docs/plans/2026-08-07-team-perks-design.md).
    ## Assignment and magnitudes are config (`GameConfig.perks` / the perkMods
    ## knobs); a default config carries none and plays byte-identical to an
    ## engine without perks.
    PerkArmor     ## +perkMods.armorHp max hit points per bot.
    PerkScope     ## gun aim-jitter sigma reduced by perkMods.scopeAim.
    PerkGrenade   ## grenade max throw range +perkMods.grenadeRange.
    PerkThruster  ## max speed +perkMods.thrusterSpeed.
    PerkLuck      ## perkMods.luckChance of landed gun shots deal luckDamage.

  PerkSet* = set[Perk]

  PerkGroup* = object
    ## One perk group of a team: the set one policy seat carries, optionally
    ## PINNED to a policy by name. `pol == ""` = unnamed, dealt to the team's
    ## distinct policies in join order; a named group goes to exactly the
    ## policy whose policyName matches. A team's groups are all-named (object
    ## config form) or all-unnamed (array form) — the parser enforces it.
    pol*: string
    perks*: PerkSet

  PerkMods* = object
    ## The perk magnitudes ("mods"), config-tunable as one block. Fractions
    ## are integer permille (the handicaps rule) so every in-sim derivation
    ## is integer or perk-gated; counts are plain hit points. Only read when
    ## a seat actually carries the perk, so the values never touch a
    ## perk-free game. Compared as ONE value against DefaultPerkMods for the
    ## config echo, so adding a knob here cannot be silently dropped from
    ## replay configs.
    armorHp*: int        ## armor: extra max hit points.
    scopeAim*: int       ## scope: fraction of aim-jitter sigma removed, permille.
    grenadeRange*: int   ## grenade: extra max throw range, permille.
    thrusterSpeed*: int  ## thruster: extra max speed, permille.
    luckChance*: int     ## luck: chance a landed gun shot is lucky, permille.
    luckDamage*: int     ## luck: hit points a lucky shot removes.

  CtfError* = object of ValueError

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  Room* = object
    name*: string
    x*, y*, w*, h*: int

  MapRect* = object
    x*, y*, w*, h*: int

  PuddleSpot* = object
    ## One disc of a paint puddle's splat cluster.
    cx*, cy*, r*: int

  Puddle* = object
    ## A paint puddle: the UNION of a handful of overlapping paint discs —
    ## the classic splat silhouette. Discs (not polygons) because disc
    ## membership is pure integer math that transforms BIT-EXACTLY under the
    ## map symmetries (mirror/rot180 move a center, never change a
    ## distance), so a puddle pair — and the stitched center puddle — is
    ## exactly team-fair; the polygon scanline rule would drop whole pixel
    ## rows at pass-through vertices (see pointInPolygon's strict-straddle
    ## doc).
    spots*: seq[PuddleSpot]

  ArenaShapeKind* = enum
    shapeRect
    shapeDisc
    shapeDiamond
    shapeDiagonal
    shapePolygon

  ArenaShape* = object
    ## One arena obstacle. Discs and diamonds are center + radius (L2 and L1
    ## norms); diagonals are a 45-degree wall segment of given perpendicular
    ## thickness between two endpoints. A `window` shape is glass: it blocks
    ## movement, bullets, and spray-cone line-of-sight exactly like stone, but
    ## fog-of-war shadowcasting sees straight through it.
    window*: bool
    case kind*: ArenaShapeKind
    of shapeRect:
      rect*: MapRect
    of shapeDisc, shapeDiamond:
      cx*, cy*, radius*: int
    of shapeDiagonal:
      x0*, y0*, x1*, y1*, thickness*: int
    of shapePolygon:
      ## A closed ring of INTEGER vertices. Curves (Beziers, metaballs,
      ## superellipses) are flattened to one of these by the authoring tools
      ## BEFORE they reach the sim, so the runtime never evaluates a curve —
      ## only integer even-odd point-in-polygon (`inShape`). Integer vertices
      ## keep symmetry transforms bit-exact, so a polygon and its mirror image
      ## rasterize to exactly mirror-symmetric wall masks (team fairness).
      points*: seq[MapPoint]

  MapPoint* = object
    x*, y*: int

  TeamPickupPoints* = object
    ## EXPLICIT per-team pickup points for a full-board (symNone) map, in team
    ## order (Red, Blue, [Green, Yellow]). Empty on symmetric maps (the orbit
    ## supplies them). Each seq, when non-empty, has one point per active team.
    ## Barriers carry `perTeam` points each, flattened team-major (team 0's
    ## points, then team 1's, ...), matching barrierSpawnPoints' orbit order.
    shields*: seq[MapPoint]
    cans*: seq[MapPoint]        ## spray-can (plasma-arc) points
    barriers*: seq[MapPoint]    ## cardboard points, team-major (perTeam each)

  EndzoneShape* = enum
    ## The shape of a team's home capture region on a SIDES map. The classic
    ## column runs the full map height along the home border; the two COMPACT
    ## shapes wrap the base itself, which lets the base sit well off the edge
    ## with playable wilderness all around it — behind included.
    ezColumn
    ezDisc
    ezSquare

  CaptureZone* = object
    ## One team's home capture region. Sides maps use the classic
    ## full-height columns; plus arms are boxes bounded on both axes; corner
    ## teams get a DIAGONAL zone — everything within an L1 radius of their
    ## map corner, whose threshold edge is a 45-degree line cut across the
    ## corner. A COMPACT endzone is the anchor-centered box (a square zone
    ## needs nothing more; `disc` rounds it off). The box fields always hold
    ## the zone's bounding box (the strip and diff-box machinery scan it);
    ## `diag` / `disc` refine membership.
    xLo*, xHi*, yLo*, yHi*: int
    diag*: bool                ## L1 corner zone instead of the full box.
    cornerX*, cornerY*: int    ## the map corner the diagonal zone hugs.
    diagLimit*: int            ## inclusive L1 radius from that corner.
    disc*: bool                ## L2 zone around the anchor instead of the box.
    anchorX*, anchorY*: int    ## the base the compact zone is centered on.
    radius*: int               ## inclusive L2 radius from that anchor.

  MapSymmetry* = enum
    ## How a map's full obstacle set derives from its authored/generated
    ## seed set. Mirror and rot180 complete a LEFT-half set across the
    ## vertical center line (2-team maps); rot90 completes a QUADRANT set by
    ## rotating it 90/180/270 degrees about the center (4-team maps, square
    ## only); quadMirror completes a TOP-LEFT quadrant set by reflecting it
    ## across both center axes (mirrorX, mirrorY, rot180 — 4-team maps, any
    ## rectangle). All are exactly team-fair; rot180 keeps diagonal lanes
    ## diagonal instead of folding them into chevrons.
    ##
    ## Ordinals are wire format (flatty stores them positionally in replay
    ## keyframes): APPEND new members, never insert.
    symMirror
    symRot180
    symRot90
    symQuadMirror
    symNone
      ## FULL-BOARD authoring (coworld-ctf#280): the authored obstacle set IS
      ## the whole board — no fundamental domain, no lift. Used for organic,
      ## irregular, theme-based maps that no group-completion can express (the
      ## corpus's asymmetric tier). There is no symmetry group, so there is no
      ## `teamImagePoint` orbit: a symNone spec MUST carry EXPLICIT per-team
      ## pickup/shield/can points, validated for walkability + connectivity
      ## like spawns. Team-FAIRNESS is NOT guaranteed by construction here —
      ## it is a MEASURED property the caller gates on (mapgen program, law 5);
      ## the engine only validates the spec is well-formed, it does not judge
      ## balance. Appended last: older viewers cannot parse symNone specs, the
      ## same wire caveat GV39's quadmirror (#237) shipped with.

  CtfMap* = object
    name*: string
    path*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    center*: MapPoint
    rooms*: seq[Room]
    ## Arena layout: the open-space clearances, the map's default gun range,
    ## and the LEFT-half obstacle set (mirrored across the vertical center
    ## line on selection).
    flagRing*: int             ## clear radius of the open center ring.
    captureClear*: int         ## x-columns kept traversable for carriers.
    spawnClearW*: int          ## half-width of the open spawn pockets.
    spawnClearH*: int          ## half-height of the open spawn pockets.
    gunRange*: int             ## default gun range on this map (px).
    endzone*: EndzoneShape     ## home capture-region shape (sides maps).
    endzoneRadius*: int        ## COMPACT endzones: the scoring radius (disc)
                               ## or half-extent (square) around the anchor,
                               ## in px. 0 on `ezColumn` maps.
    homeDepth*: int            ## home anchor position as a permille of the
                               ## half-field, measured from the center: 700
                               ## (the classic) puts the base 30% of the way
                               ## in from its edge, and SMALLER values push it
                               ## further from the edge.
    symmetry*: MapSymmetry
    layout*: TeamLayout        ## sides (2 teams) / corners / plus (4 teams).
    genSeed*: int              ## generator seed; 0 for hand-authored maps.
    medKitSpawns*: seq[MapPoint]     ## the two ACTIVE med-kit points.
    medKitCandidates*: seq[MapPoint] ## the drawn candidate set (4 on
                                     ## generated maps; equals the active
                                     ## pair on hand-authored maps).
    leftObstacles*: seq[ArenaShape]
    trenches*: seq[ArenaShape]  ## walkable dug pits (config-gated): standing
                               ## inside slows movement and fire, and most
                               ## incoming gun shots fly straight over. FULL-map
                               ## (both halves, already symmetrized). The
                               ## generator emits `rect` pits; authored maps may
                               ## use any shape, including `polygon` (curved
                               ## pits). Membership is `inShape`, so the mechanic
                               ## is shape-agnostic; only the organic-edge ART is
                               ## rect-specific (other kinds fill flat for now).
    puddles*: seq[Puddle]      ## paint-puddle hazards (config-gated): every
                               ## full second a cog's center spends
                               ## continuously inside one rolls a
                               ## puddleDamagePct chance of 1 damage. Pure
                               ## floor hazard — no movement, fire, or vision
                               ## effect. FULL-map (both halves, already
                               ## symmetrized), pinned into replay specs like
                               ## trenches.
    teamPickups*: TeamPickupPoints
                               ## EXPLICIT per-team pickup points (coworld-ctf
                               ## #280). Symmetric maps leave this empty and
                               ## derive every team's shield/can/barrier point
                               ## from RED's via the symmetry orbit
                               ## (`teamImagePoint`). A symNone (full-board) map
                               ## has NO orbit, so it MUST author each team's
                               ## points here. The loader validates they are
                               ## PRESENT (one per team; barriers a multiple of
                               ## the team count) and NOT WALL — each point must
                               ## be in-bounds and clear of every obstacle
                               ## (wall-overlap test, no silent default). It does
                               ## NOT do a full flood-CONNECTIVITY check at load
                               ## (too heavy); reachability/fairness is the
                               ## caller's measured gate. Ignored on symmetric maps.

  CrewSprite* = ref object
    width*, height*: int
    rgba*: seq[uint8]

  RewardAccount* = object
    address*: string
    slotIndex*: int
    team*: Team
    hasTeam*: bool
    won*: bool
    abandoned*: bool
    reward*: int
    wins*: array[Team, int]    ## lifetime wins while seated on each team.
    games*: array[Team, int]   ## lifetime games seated on each team.
    kills*: int
    deaths*: int
    captures*: int

  PlayerSlotConfig* = object
    name*: string
    token*: string
    team*: Team
    color*: uint8
    skin*: Skin
    hasTeam*: bool
    hasColor*: bool

  MapGenOverrides* = object
    ## Per-parameter locks for the terrain generator. Zero-value ("" / 0,
    ## windows -1) = unlocked, drawn from the map seed. Locking a parameter
    ## replaces its draw without shifting the other draws.
    size*: string          ## "small" | "standard" | "large"
    symmetry*: string      ## "mirror" | "rot180"
    columns*: int          ## obstacle column count per half, 3..8
    windows*: int          ## glass-window count per half, 0..6; -1 = draw
    centerFeature*: string ## "bracket" | "ring" | "walls"
    layout*: string        ## 4-team maps: "corners" | "plus"; "" = draw.
    pits*: int             ## requested TOTAL trench count, 0..64; -1 =
                           ## density draw. Best-effort: when the candidate
                           ## spots can't host the full request, the map
                           ## places as many as fit. Even counts place
                           ## symmetric pairs; an odd count anchors its
                           ## extra pit dead center (self-symmetric under
                           ## mirror AND rot180), so both parities stay
                           ## exactly team-fair.
    pitDensity*: int       ## percent multiplier on the default per-class
                           ## pit chances (100 = default feel, 0 = none,
                           ## 200 = twice as digging-happy); -1 = default.
                           ## Ignored when `pits` locks an exact count.
    puddles*: int          ## requested TOTAL paint-puddle count, 0..64.
                           ## <= 0 = none (the default — puddles have no
                           ## density draw, so the zero object default and
                           ## an explicit 0 mean the same thing).
                           ## Best-effort like pits: places as many as fit.
                           ## Even counts place symmetric pairs; an odd
                           ## count anchors its extra puddle dead center.
    endzone*: string       ## "column" | "disc" | "square"; "" = draw. The
                           ## two COMPACT shapes wrap the base and open the
                           ## home border strip up as wilderness.
    endzoneRadius*: int    ## compact endzone scoring radius in px,
                           ## EndzoneRadiusMin..EndzoneRadiusMax; 0 = draw.
                           ## Ignored on `ezColumn` maps.
    baseDepth*: int        ## home anchor depth permille (see CtfMap.
                           ## homeDepth), HomeDepthMin..HomeDepthMax;
                           ## 0 = draw (700 on column maps).

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    playerBouncePct*: int
    seed*: int
    speed*: int
    lives*: int
    hitPoints*: int
    respawnTicks*: int
    gunRange*: int
    fireCooldownTicks*: int
    fireWindupTicks*: int
    carrierSpeedPct*: int
    aimTurnRate*: int          ## brads/tick a held rotate button turns the aim.
    visionConeDeg*: int
    visionBubble*: int
    minPlayers*: int
    startWaitTicks*: int
    lobbyJoinTimeoutTicks*: int  ## finite matches only: abort the lobby when
                                 ## the roster is still short after this many
                                 ## lobby ticks (0 = wait forever, the
                                 ## pre-existing behavior). The clock runs on
                                 ## lobby ticks, so board bake/setup before
                                 ## the loop starts never eats the budget.
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    showPlayerLabels*: bool
    fastMode*: bool           ## advance frames early when every player has
                              ## sent the Sprite v1 ready packet; pacing only,
                              ## never in gameHash.
    teams*: int               ## active team count: 2 (classic sides) or 4
                              ## (corner / plus free-for-all maps). Every
                              ## team fights for itself; "2v2" is two
                              ## policies splitting one classic team's
                              ## seats, not a game mode.
    scoring*: string          ## end-of-game reward rule: ClassicScoring
                              ## (default, unchanged) or PotScoring.
    mapPath*: string
    mapSeed*: int             ## terrain seed for "gen"/"pool"; -1 = derive
                              ## from the game seed.
    mapPoolIndex*: int        ## explicit pool pick; -1 = mapSeed mod pool.
    mapGen*: MapGenOverrides
    mapSpec*: string          ## expanded map geometry JSON. Filled once at
                              ## config parse for generated maps and written
                              ## into replays, so playback reuses the EXACT
                              ## geometry and never re-runs the generator.
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]
    barrageMaxPerSec*: int    ## grenade-barrage endgame: the launch rate the
                              ## barrage ramps UP to, in grenades/second.
                              ## 0 = the mode is off — the default,
                              ## byte-identical to the pre-barrage game.
                              ## Requires maxTicks > 0 when set; capped at
                              ## BarrageAbsMaxPerSec.
    barrageStartPerSec*: int  ## grenade-barrage endgame: the launch rate at
                              ## the moment the barrage latches (default
                              ## BarrageStartPerSec); ramps linearly to
                              ## barrageMaxPerSec over barrageSaturateSec.
    barrageStartSec*: int     ## grenade-barrage endgame: the barrage latches
                              ## on when the game clock has this many seconds
                              ## remaining (default BarrageStartSec — 4:30
                              ## elapsed on the default 5:00 clock). Once
                              ## latched it only ever escalates.
    barrageSaturateSec*: int  ## grenade-barrage endgame: seconds from the
                              ## latch until the ramp completes — whole
                              ## board targeted at barrageMaxPerSec
                              ## (default BarrageSaturateSec, landing full
                              ## saturation exactly at the scheduled end).
    handicaps*: array[Team, int]  ## per-team handicap in PERMILLE (0..1000),
                                  ## authored as a 0.0..1.0 float. 0 = normal
                                  ## (the default, byte-identical to no
                                  ## handicap); 1000 = fully handicapped: 50%
                                  ## of shots miss, 1 life, 1 hit point, half
                                  ## max speed. Intermediate values interpolate
                                  ## linearly (see hitPointsFor/livesFor/
                                  ## maxSpeedFor/missPermilleFor). Integer
                                  ## permille keeps every in-sim derivation
                                  ## integer-only, so native and wasm agree.
    perks*: array[Team, seq[PerkGroup]]
      ## Per-team perk GROUPS. Empty (the default) = no perks, byte-identical
      ## to an engine without the field. One unnamed group = the whole team
      ## shares it; several unnamed = CTF-Doubles: the Nth distinct POLICY to
      ## seat on the team (join order, policyName collapse) gets group N,
      ## clamped to the last. NAMED groups (object config form) pin a group
      ## to its policy exactly; an unmatched policy gets nothing. See
      ## docs/plans/2026-08-07-team-perks-design.md.
    perkMods*: PerkMods        ## the perk magnitudes; DefaultPerkMods unless
                               ## the config's perkMods block overrides.
    puddleDamagePct*: int         ## percent chance (0..100) that one full
                                  ## second of continuous paint-puddle
                                  ## occupancy deals 1 damage. Default 20
                                  ## (GV43; was 10). Inert on maps without
                                  ## puddles (the roll — and its RNG draw —
                                  ## only happens while a cog stands in one,
                                  ## so the puddle-free path stays
                                  ## byte-identical across builds).
    barrierPickups*: int          ## cardboard barrier pickups PER TEAM
                                  ## (0..MaxBarrierPickupsPerTeam), staged on
                                  ## the line from each team's anchor toward
                                  ## map center. 0 = the mode is off — the
                                  ## default, byte-identical to the
                                  ## pre-barrier game (no spawns, no carries,
                                  ## no placements, no new RNG draws).
    gameMode*: string             ## `ctf` (default) or competitive `emerg-ant`.
    forageGoal*: int              ## emerg-ant food returns needed to win.

  Player* = object
    x*, y*: int
    homeX*, homeY*: int
    velX*, velY*: int
    carryX*, carryY*: int
    flipH*: bool
    aimBrads*: int             ## aim angle in brads, 0..255: 0 = east (+x),
                               ## counter-clockwise on screen (64 = north).
    team*: Team
    alive*: bool
    lives*: int
    hp*: int                   ## remaining hit points this life.
    respawnTimer*: int
    fireCooldown*: int
    fireWindup*: int           ## ticks until a pulled trigger releases its shot.
    windupBrads*: int          ## aim angle locked at the trigger pull, -1 = none.
    carryingFlag*: bool
    hasGrenade*: bool          ## each player carries at most one grenade.
    hasShield*: bool           ## carrying an endzone shield: 3x slower fire.
    shieldHp*: int             ## remaining shield-layer hp (0..ShieldLayerHp);
                               ## damage depletes it before base hp.
    hasPlasmaArc*: bool        ## each player carries at most one plasma arc.
    arcTicksLeft*: int         ## remaining active ticks of a fired spray
                               ## cone (0 = the cone is off).
    arcAimBrads*: int          ## aim direction locked at the spray's fire
                               ## instant, -1 = no active cone. The cone points
                               ## this way for its whole active window: turning
                               ## the cog mid-spray no longer sweeps it. (The
                               ## cone's ORIGIN still rides the owner.)
    arcHitMask*: uint32        ## players already damaged by the current
                               ## activation: one hit per victim per firing.
    throwCharge*: int          ## ticks the throw button has been held.
    puddleTicks*: int          ## consecutive ticks this cog's center has
                               ## stood inside a paint puddle; at
                               ## PuddleRollTicks the damage roll fires and
                               ## the counter restarts. Resets on exit and
                               ## on death. Deterministic gameplay state,
                               ## but NOT mixed into gameHash: hashing a new
                               ## always-zero field would shift every
                               ## pre-puddle replay's hash chain (keyframe
                               ## scrub still restores it exactly via the
                               ## flatty sim snapshot).
    lastShoutTick*: int        ## tick of this player's latest shout, -1 = never.
    paintHitTick*: int         ## tick of the latest PAINT hit taken. Every
                               ## weapon throws paint — gun, grenade, and the
                               ## spray can — so all three stamp it. Cosmetic:
                               ## drives the EYES-PiP visor paint splat; -1 =
                               ## never, never enters gameHash.
    joinOrder*: int
    address*: string
    color*: uint8
    skin*: Skin               ## cosmetic only; excluded from gameHash.
    reward*: int
    kills*: int
    deaths*: int
    captures*: int
    shotsFired*: int           ## shots this player released; analysis-only,
                               ## excluded from gameHash (see gameHash).
    shotsHit*: int             ## released shots that connected with an enemy;
                               ## analysis-only, excluded from gameHash.
    multiKills2*: int          ## grenade blasts / spray bursts that
                               ## killed exactly 2; analysis-only, excluded
                               ## from gameHash.
    multiKills3*: int          ## grenade blasts / spray bursts that
                               ## killed 3 or more; analysis-only, excluded
                               ## from gameHash.
    teamKills*: int            ## teammates this player killed (backstabs);
                               ## analysis-only, excluded from gameHash.
    arcKillsThisFire*: int     ## kills scored by the current spray
                               ## activation; transient multi-kill
                               ## bookkeeping, excluded from gameHash.
    perks*: PerkSet            ## this seat's perks, resolved ONCE at join
                               ## from config.perks + the policy's rank among
                               ## the team's distinct policies (roster.nim).
                               ## Pure function of config + the replayed join
                               ## stream, so excluded from gameHash.
    hasBarrier*: bool          ## carrying one folded cardboard barrier
                               ## (config-gated). Mutually exclusive with
                               ## hasGrenade — both place/throw on button C,
                               ## so a cog holds one or the other, never
                               ## both. Deterministic gameplay state, but NOT
                               ## mixed into gameHash: hashing a new
                               ## always-false field would shift every
                               ## pre-barrier replay's hash chain (keyframe
                               ## scrub still restores it exactly via the
                               ## flatty sim snapshot — the puddleTicks rule).

  PlayerFov* = object
    ## One player's cached fog-of-war visibility grid (FovGridW x FovGridH
    ## cells). The expensive shadowcast pass depends only on the viewer's
    ## CELL, so it is cached separately (cellVisible) from the final
    ## cone-filtered grid (visible): a viewer who only turns — bots rotate
    ## aim nearly every tick — reuses the cached shadowcast and pays just
    ## the cone filter.
    valid*: bool
    originCx*, originCy*: int
    aimBrads*: int
    visible*: seq[bool]
    cellValid*: bool
    cellCx*, cellCy*: int
    cellVisible*: seq[bool]

  DiamondPatch* = object
    ## Diamond-free wall pixels for one live geometry window. Fields exported
    ## for sim.nim's restamp machinery (stage-1 split); not public API.
    x0*, y0*, w*, h*: int
    frame*: int
    dirty*: bool    ## frame advanced this tick, mask not restamped yet.
    baseWall*: seq[bool]
    neighbours*: seq[int]
      ## Every diamond whose own window overlaps this one, INCLUDING itself.
      ## A restamp ORs all of them, so a shared pixel gets the same answer
      ## whichever window wrote it last. Usually just self; dense generated
      ## maps can pack diamonds closer than the arena does.

  ShotFx* = object
    ## A cosmetic shot tracer segment; never enters gameHash (replay-safe).
    x0*, y0*, x1*, y1*: int
    firedTick*: int
    color*: uint8
    hit*: bool                 ## the shot connected with a player: its tracer
                               ## draws full-bright, a miss draws pre-faded.

  HitFlashFx* = object
    ## A cosmetic "target was struck" flash; never enters gameHash
    ## (replay-safe). The spectator view draws a brief bright ring over the
    ## victim (tracked by index, so the flash follows them) the instant a
    ## bullet connects — making hits legible at a glance where the tracer
    ## alone is ambiguous.
    playerIndex*: int          ## the struck player; players are only appended.
    tick*: int                 ## when the bullet connected.

  BubbleImpactFx* = object
    ## A cosmetic shield-bubble impact; never enters gameHash (replay-safe).
    ## When a bullet lands on a carrier whose bubble is still up, the bubble
    ## itself blinks and dents toward the shooter — replacing the struck-target
    ## ring and body paint spark, so the hit reads as absorbed by the shield.
    playerIndex*: int          ## the struck carrier; players are only appended.
    tick*: int                 ## when the bullet connected.
    angleBrads*: int           ## impact site: direction from the carrier's
                               ## center toward the shooter, in aim brads.

  SplatterFx* = object
    ## A cosmetic death splatter mark; never enters gameHash (replay-safe). A
    ## `hit` mark is the smaller, shorter-lived paint spark left by a non-fatal
    ## hit; a death mark (hit == false) is the larger, long-dwelling splatter.
    x*, y*: int
    tick*: int
    color*: uint8
    hit*: bool

  PaintStain* = object
    ## A DRIED paint stain on the terrain: cosmetic, permanent for the rest of
    ## the match, and never in gameHash (replay-safe). Where SplatterFx marks
    ## where a cog was HIT and fades over a few seconds, a stain is the paint
    ## that missed and hit the map — so the lanes players fight over slowly
    ## accumulate their colors. Emitted once per stain and then left on the
    ## client forever (see addPaintStains), so this is nearly free per frame.
    x*, y*: int
    color*: uint8              ## the SHOOTER's paint, so a lane's color says
                               ## which team keeps running it.
    onWall*: bool              ## true when the paint struck WALL geometry. The
                               ## renderer masks the blot to pixels of this same
                               ## surface, so a splat on a wall stays on the wall
                               ## instead of spilling onto the floor beside it.
    seed*: uint32              ## picks the blot shape/rotation variant, derived
                               ## from the impact site so a replay re-derives
                               ## the identical mark.

  DiamondStain* = object
    ## Paint that landed on a ROTATING center diamond. Stored in the diamond's
    ## OWN un-rotated frame (lx, ly) rather than in map pixels, so the mark
    ## turns with the stone it stuck to instead of hanging in the air where the
    ## shot happened to hit. Cosmetic; never enters gameHash.
    diamond*: uint8            ## index into AnimatedDiamonds.
    lx*, ly*: float32          ## offset from the diamond center, un-rotated.
    color*: uint8
    seed*: uint32

  BlastFx* = object
    ## A cosmetic grenade blast flash; never enters gameHash (replay-safe).
    ## Landing is audible: views also derive their landing sound rings here.
    x*, y*: int
    tick*: int
    color*: uint8              ## the thrower's paint color, so the landing
                               ## splat reads as that team's paint-bomb.
    trenchLanding*: bool       ## true when the blast landed inside a trench:
                               ## the flash renders truncated to the pit's
                               ## footprint instead of the open-field size.

  PlasmaArcFx* = object
    ## A cosmetic spray-cone paint flash; never enters gameHash (replay-safe).
    x*, y*: int
    aimBrads*: int
    tick*: int
    color*: uint8
    attacker*: int
      ## Which player fired this snapshot. One burst emits a snapshot per active
      ## tick, each with the owner's LIVE pose; the renderer groups snapshots by
      ## attacker and draws them all along the newest one's pose, so a burst that
      ## swings its aim reads as one plume, not a divergent trail. See
      ## plasmaArcRenderPose.

  DamageFx* = object
    ## A cosmetic floating "-N" damage number that rises and fades above a
    ## player the instant they lose hit points; never enters gameHash
    ## (replay-safe). Makes each of the 3 health bars visibly tick down.
    x*, y*: int                ## where the hit landed (player center at hit).
    tick*: int                 ## when the hit landed.
    amount*: int               ## hit points lost (1 for a shot; a grenade
                               ## varies by trench, see explodeGrenade).
    color*: uint8              ## the victim's team color, so it reads as their loss.
    kill*: bool                ## a fatal hit: drawn as a "KO" kill marker that
                               ## lives KillFxTicks instead of the "-N" number.

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Every kind is
    ## emitted at the exact in-sim site where the fact is known first-hand
    ## (weapon, positions, attacker), so downstream never has to guess by
    ## counter-diffing. Analysis-only: never enters gameHash.
    Shot        ## a gun shot released (source = shooter).
    Hit         ## a released shot connected with an enemy on its ray.
    Damage      ## hit points removed (gun/spray/grenade), amount = hp lost.
    Kill        ## a CREDITED kill (mirrors recordKill; self-kills by own
                ## grenade are a Death without a Kill).
    Death       ## a player died (source = victim, target = killer).
    FlagSteal   ## a flag left its pedestal on an enemy's back.
    FlagReturn  ## a flag went home for any reason other than capture.
    Capture     ## a carrier scored the enemy flag.
    Respawn     ## a dead player came back at home.
    Heal        ## hit points restored (med kit or shield pickup).
    PhaseChange ## the game phase moved (lobby / playing / gameover):
                ## weapon = the new phase name, amount = its ordinal.
    GunTrigger  ## a player pulled the gun trigger and locked their aim.
    ShotImpact  ## a released shot ended at a player, wall, or range limit.
    GrenadeThrow
    GrenadeImpact
    SprayUse    ## one active spray-cone tick and the damage it dealt.
    Pickup      ## a player picked up an item; item names the pickup.
    ShoutEvent  ## a player shouted; content is the sanitized text.

  EventDamage* = object
    ## One victim damaged by a primary impact/use event.
    slot*: int
    amount*: int
    hp*: int
    blocked*: int

  SimEvent* = object
    ## One tier-2 analysis event; never enters gameHash (replay-safe).
    ## Collected only while collectEvents is on, so live servers pay nothing.
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting player's stable join slot, -1 = n/a.
    target*: int               ## affected player's stable join slot, -1 = n/a.
    weapon*: string            ## "gun" / "spray" / "grenade", the new phase
                               ## name for PhaseChange, "" = n/a.
    amount*: int               ## hp delta for Damage/Kill/Heal, the new
                               ## phase ordinal for PhaseChange, else 0.
    hp*: int                   ## the affected player's remaining hit points
                               ## AFTER the event, floored at 0 (a fatal
                               ## overkill still reads 0): the victim on
                               ## Damage, the healed player on Heal.
                               ## -1 on every other kind (n/a).
    blocked*: int              ## on a Damage event, how many of `amount`'s hit
                               ## points the victim's SHIELD absorbed — i.e.
                               ## damage prevented from touching the base cog.
                               ## A shield carrier holds bonus hp above the base
                               ## HitPoints ceiling (only a shield pickup lifts a
                               ## cog there), so any of this hit that lands while
                               ## the victim is above base is shield-soaked. 0
                               ## when the victim held no shield hp, and on every
                               ## non-Damage kind (n/a).
    x*, y*: float              ## map position where the event happened.
    actionId*: int64           ## ties stages of one weapon action together.
    headingBrads*: int         ## native aim heading (0..255), -1 = n/a.
    distance*: float           ## throw/shot distance in map pixels.
    item*: string              ## pickup item name, "" = n/a.
    content*: string           ## sanitized shout content, "" = n/a.
    damages*: seq[EventDamage] ## victims damaged by this impact/use.

  Shout* = object
    ## One short player message, audible within ShoutRange of where it was
    ## made. Bots observe shouts, so they are gameplay state (in gameHash)
    ## and replays re-apply the recorded chat records that produced them.
    address*: string           ## the shouter, by player address.
    team*: Team
    text*: string              ## sanitized, at most ShoutMaxChars.
    tick*: int                 ## when it was shouted.
    x*, y*: int                ## shouter center at shout time.

  PickupSpawn* = object
    ## One fixed pickup point: corner grenades and center med kits.
    x*, y*: int
    present*: bool
    respawnAt*: int            ## tick the pickup refills (when not present).

  PlacedBarrier* = object
    ## One standing cardboard barrier: three sides of a hexagon (a half-hex)
    ## whose flat middle side faces where the placer was aiming. It blocks
    ## every PAINT path (gun corridor and spray cone) but never sight, never
    ## movement, and never grenades. The four vertices are snapped to map
    ## pixels at placement, so every later coverage test is integer-only and
    ## native/wasm agree.
    x*, y*: int                ## placement center (the placer's center).
    facingBrads*: int          ## the placer's aim at placement (render/label).
    verts*: array[4, tuple[x, y: int]]  ## half-hex vertices at aim -90,
                               ## -30, +30, +90 degrees; the three sides are
                               ## the consecutive pairs, the middle one flat
                               ## across the aim.
    minX*, minY*, maxX*, maxY*: int  ## coverage bounding box (band included)
                               ## for cheap point rejection.
    hp*: int                   ## paintball hits left (starts at BarrierHp).
    team*: Team                ## the placer's team (tints the tape stripe).
    placedTick*: int

  AirborneGrenade* = object
    ## One thrown grenade in flight: it flies OVER walls in a straight line
    ## from the throw point to the target and explodes on landing.
    sx*, sy*: int
    tx*, ty*: int
    launchTick*: int
    flightTicks*: int
    thrower*: int              ## live index retained for replay-hash compatibility.
    throwerSlot*: int          ## immutable analysis identity; never hashed.
    throwerAccount*: int       ## stable results account; never hashed.

  PheromoneMark* = object
    ## One public stigmergic trail mark in Emerg-ant mode. Marks are gameplay
    ## observation state (bots can follow either colony's trail), so unlike
    ## cosmetic paint stains they are hashed and replayed.
    x*, y*: int
    team*: Team
    tick*: int
    food*: bool                ## laid by an ant carrying stolen food.

  FlagState* = object
    ## One team's flag: provably sitting on its home pedestal (carrier == -1),
    ## carried by an enemy player (never loose), or retired and out of play
    ## (captured, carrier == -1, frozen where it left play).
    x*, y*: int
    carrier*: int              ## player index carrying this flag, -1 when home.
    captured*: bool            ## the heart is out of play for the rest of the
                               ## game: captured (GV32), or retired because its
                               ## team has been completely killed (GV33). A
                               ## retired heart is never drawn and cannot be
                               ## stolen.

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    crewSprites*: seq[CrewSprite]
    flagSprite*: Sprite
    gameMap*: CtfMap
    rooms*: seq[Room]
    flags*: array[Team, FlagState]  ## per-team flags on the home pedestals.
    mapPixels*: seq[uint8]
    mapRgba*: seq[uint8]
    darkBgPixels*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]
    windowMask*: seq[bool]     ## STATIC glass pixels; wall, but never opaque to vision.
    fovBlocked*: seq[bool]     ## FovGridW x FovGridH; a cell is opaque when mostly wall.
    fovCaches*: seq[PlayerFov]           ## exported for sim.nim (stage-1 split).
    diamondPatches*: seq[DiamondPatch]   ## exported for sim.nim (stage-1 split).
    rng*: Rand
    nextJoinOrder*: int
    tickCount*: int
    recentShots*: seq[ShotFx]  ## cosmetic shot tracers; excluded from gameHash.
    hitFlashes*: seq[HitFlashFx]  ## cosmetic struck-target flashes; excluded from gameHash.
    bubbleImpacts*: seq[BubbleImpactFx]  ## cosmetic shield-bubble impact blinks; excluded from gameHash.
    splatters*: seq[SplatterFx]  ## cosmetic death splatters; excluded from gameHash.
    diamondStains*: seq[DiamondStain]  ## permanent paint riding the spinning
                               ## center diamonds; excluded from gameHash.
    paintStains*: seq[PaintStain]  ## permanent dried terrain paint; excluded from
                               ## gameHash. Append-only within a match and reset
                               ## on startGame/resetToLobby, so a replay rebuilds
                               ## the exact same buildup as it re-simulates and a
                               ## keyframe scrub restores the paint of that tick.
    recentBlasts*: seq[BlastFx]  ## cosmetic grenade blasts; excluded from gameHash.
    damagePops*: seq[DamageFx]  ## cosmetic floating "-N" damage numbers; excluded from gameHash.
    recentShouts*: seq[Shout]  ## live shouts; observable state, in gameHash.
    grenadeSpawns*: array[4, PickupSpawn]
    medKitSpawns*: seq[PickupSpawn]       ## the map's active med kits (2 on
                                          ## sides maps, 4 on 4-team maps).
    shieldSpawns*: seq[PickupSpawn]       ## one shield per team endzone.
    plasmaArcSpawns*: seq[PickupSpawn]    ## one spray can per team endzone.
    airborneGrenades*: seq[AirborneGrenade]
    plasmaArcFlashes*: seq[PlasmaArcFx]
    gameStartTick*: int
    startWaitTimer*: int
    lobbyWaitTimer*: int  ## lobby ticks spent short of minPlayers (live-server
                          ## lobby lifecycle only: not hashed, not in replays).
    phase*: GamePhase
    asciiSprites*: PixelFont
    shoutFont*: PixelFont  ## chunky 9px grid font used only for shout bubbles.
    winner*: Team
    gameOverTimer*: int
    timeLimitReached*: bool
    barrageStartTick*: int     ## tickCount at which the grenade barrage
                               ## latched on; -1 before. Deterministic
                               ## (derived from the clock), so replays
                               ## re-derive it; mixed into gameHash only once
                               ## latched, keeping barrage-off games
                               ## hash-identical.
    barrageAccum*: int         ## fractional-launch accumulator in permille-
                               ## grenade-seconds: each Playing tick adds the
                               ## current rate (permille grenades/second) and
                               ## every TargetFps*1000 drained launches one
                               ## shell. Hashed alongside barrageStartTick.
    isDraw*: bool
    needsReregister*: bool
    gameEventLoggingEnabled*: bool
    collectEvents*: bool       ## tier-2 event sink switch; default off so
                               ## live servers pay nothing (see SimEvent).
    events*: seq[SimEvent]     ## collected tier-2 events; the extractor
                               ## drains this every tick. Never in gameHash.
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int
    barrierSpawns*: seq[PickupSpawn]  ## config-gated cardboard barrier
                               ## pickups (barrierPickups per team); empty on
                               ## default configs. Appended at the END of the
                               ## type: keyframes are flatty-positional, and
                               ## they are derived in-process (never read
                               ## from a replay file), so appending is safe
                               ## without a GameVersion bump.
    placedBarriers*: seq[PlacedBarrier]  ## standing cardboard barriers,
                               ## oldest first (the placement cap flattens
                               ## index 0). Deterministic gameplay state,
                               ## kept OUT of gameHash like puddleTicks so
                               ## barrier-free games hash identically to
                               ## pre-barrier builds.
    pheromones*: seq[PheromoneMark] ## emerg-ant shared environmental memory;
                               ## empty and un-hashed in ordinary CTF.
    colonyFood*: array[Team, int] ## delivered food waiting when brood is full.
    queenSlot*: array[Team, int] ## stable queen join slot; -1 means queenless.


# Team endzone display colors (shared by the map bake and the paint FX).
const
  RedEndzoneColor* = rgba(224, 82, 58, 255)    ## team vermillion (§4).
  BlueEndzoneColor* = rgba(63, 124, 196, 255)  ## team cerulean (§4).
  GreenEndzoneColor* = rgba(69, 168, 94, 255)  ## matches the viewer --green.
  YellowEndzoneColor* = rgba(221, 197, 49, 255)  ## matches the viewer --yellow.
    ## Exported as THE team display colors. The 16-entry `Palette` a sprite's
    ## `color: uint8` indexes is the retro engine palette, and its blue slot
    ## (BlueTeamColor = 13) is a muted lavender (131,118,156) that reads nothing
    ## like the vivid cerulean the soldier art (116,168,255) and the endzone
    ## floor actually show. Any NEW team-colored art should tint from these four
    ## so it matches what a viewer sees on the board.

# Pure aim-angle math (needed on both sides of the art/gameplay split).
proc distSq*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc aimVector*(brads: int): tuple[x, y: float] =
  ## Returns the unit vector for one aim angle in brads (256 per turn):
  ## 0 points east (+x) and the angle increases counter-clockwise on screen,
  ## so 64 is north (-y in map coordinates), 128 west, and 192 south.
  let angle = float(brads) * PI / float(AimBradsTurn div 2)
  (cos(angle), -sin(angle))

proc bradsOfVector*(dx, dy: int): int =
  ## Returns the aim-brads angle of a map-space vector — the inverse of
  ## `aimVector` (screen y points down, so north is -y).
  if dx == 0 and dy == 0:
    return 0
  let brads = int(round(
    arctan2(-float(dy), float(dx)) * float(AimBradsTurn div 2) / PI))
  ((brads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn


# Team helpers (pure functions over the types/consts above).
proc teamCount*(layout: TeamLayout): int =
  ## Returns how many teams a layout seats.
  case layout
  of layoutSides:
    2
  of layoutCorners, layoutPlus:
    4

proc teamCount*(gameMap: CtfMap): int =
  ## Returns how many teams play on one map.
  gameMap.layout.teamCount()

proc activeTeams*(count: int): Slice[Team] =
  ## Returns the active-team slice for one team count. Active teams are
  ## always a prefix of the enum, so 2-team games iterate exactly Red..Blue
  ## — every historical loop, hash, and wire frame is unchanged.
  doAssert count in [2, 4], "team count must be 2 or 4"
  Red .. Team(count - 1)

proc teams*(gameMap: CtfMap): Slice[Team] =
  ## Returns the active teams on one map.
  activeTeams(gameMap.teamCount())

proc teams*(sim: SimServer): Slice[Team] =
  ## Returns the active teams in one game.
  sim.gameMap.teams()


proc teamText*(team: Team): string =
  ## Returns the readable team name.
  case team
  of Red:
    "red"
  of Blue:
    "blue"
  of Green:
    "green"
  of Yellow:
    "yellow"

proc isEmergAnt*(config: GameConfig): bool {.inline.} =
  ## True for the competitive foraging ruleset.
  config.gameMode == EmergAntMode

proc teamColor*(team: Team): uint8 =
  ## Returns the palette color for one team.
  case team
  of Red:
    RedTeamColor
  of Blue:
    BlueTeamColor
  of Green:
    GreenTeamColor
  of Yellow:
    YellowTeamColor

# Per-team handicap accessors. The handicap is stored as a permille (0..1000);
# every derivation below is pure integer math and returns the EXACT base config
# value at permille 0, so an unhandicapped game (the default) is byte-identical
# to one with no handicap field at all — no drift, no extra RNG. See
# docs/plans/2026-08-05-per-team-handicaps-design.md.

proc hitPointsFor*(config: GameConfig, team: Team): int =
  ## Hit points for `team`: interpolates from config.hitPoints down to 1 as the
  ## team's handicap rises from 0 to full.
  let p = config.handicaps[team]
  if p <= 0: config.hitPoints
  else: max(1, config.hitPoints - (config.hitPoints - 1) * p div 1000)

proc livesFor*(config: GameConfig, team: Team): int =
  ## Lives for `team`: interpolates from config.lives down to 1.
  let p = config.handicaps[team]
  if p <= 0: config.lives
  else: max(1, config.lives - (config.lives - 1) * p div 1000)

proc maxSpeedFor*(config: GameConfig, team: Team): int =
  ## Max speed for `team`: interpolates from config.maxSpeed down to half.
  let p = config.handicaps[team]
  if p <= 0: config.maxSpeed
  else: config.maxSpeed * (2000 - p) div 2000

proc missPermilleFor*(config: GameConfig, team: Team): int =
  ## Fraction of a would-be gun hit dropped, in permille (0..500): 0 at no
  ## handicap, 500 (50%) at full. The caller draws RNG only when this is > 0.
  config.handicaps[team] div 2

# Perk accessors. Like the handicap accessors above, every derivation returns
# the EXACT base value when the perk is absent (no arithmetic, no drift, no
# extra RNG), so a perk-free game — the default — is byte-identical to an
# engine without perks. See docs/plans/2026-08-07-team-perks-design.md.

const PerkNames*: array[Perk, string] = [
  "armor", "scope", "grenade", "thruster", "luck"]
  ## The authored/wire name of each perk (config JSON, broadcast roster `pk`,
  ## marker labels, scorebug icon keys).

const DefaultPerkMods* = PerkMods(
  armorHp: 1,         # armor: +1 max hit point.
  scopeAim: 500,      # scope: 50% less aim deviation.
  grenadeRange: 250,  # grenade: +25% throw range.
  thrusterSpeed: 100, # thruster: +10% max speed.
  luckChance: 100,    # luck: 10% of landed shots are lucky.
  luckDamage: 2       # luck: a lucky shot deals 2 hp.
)

proc perkText*(perk: Perk): string =
  ## Returns one perk's authored/wire name.
  PerkNames[perk]

proc parsePerk*(text: string): Perk =
  ## Parses one authored perk name; raises CtfError on an unknown name.
  for perk in Perk:
    if PerkNames[perk] == text:
      return perk
  raise newException(CtfError, "Unknown perk name: " & text)

proc maxHpFor*(config: GameConfig, team: Team, perks: PerkSet): int =
  ## One seat's max hit points: the team's (handicap-interpolated) hit points
  ## plus the armor bonus when the seat carries the perk.
  result = config.hitPointsFor(team)
  if PerkArmor in perks:
    result += config.perkMods.armorHp

proc maxSpeedFor*(config: GameConfig, team: Team, perks: PerkSet): int =
  ## One seat's max speed: the team's (handicap-interpolated) max speed,
  ## boosted by the thruster perk when carried. Integer permille, so native
  ## and wasm agree.
  result = config.maxSpeedFor(team)
  if PerkThruster in perks:
    result = result * (1000 + config.perkMods.thrusterSpeed) div 1000

proc grenadeRangeFor*(config: GameConfig, maxRange: int, perks: PerkSet): int =
  ## One seat's max grenade throw distance, given the map's base
  ## GrenadeMaxRange: boosted by the grenade perk when carried.
  result = maxRange
  if PerkGrenade in perks:
    result = result * (1000 + config.perkMods.grenadeRange) div 1000

proc perkGroupTexts*(config: GameConfig, team: Team): seq[string] =
  ## Each of one team's perk groups as comma-joined perk names in Perk enum
  ## order ("" for an empty group); the empty seq when the team has none.
  ## The shared source for the marker label (labelPerks) and the broadcast
  ## scorebug, so the two streams can never disagree.
  for group in config.perks[team]:
    var names = ""
    for perk in Perk:
      if perk in group.perks:
        if names.len > 0:
          names.add ","
        names.add perkText(perk)
    result.add names

proc policyName*(address: string): string =
  ## The policy identity behind one seat's connection name: the hosted runtime
  ## appends a per-connection " (N)" suffix to the SAME policy's multiple seats
  ## ("softmaxwell (2)", "softmaxwell (7)"…), so stripping it collapses every
  ## seat of one policy to a single shared name. The join path converts spaces
  ## to underscores (server.nim cleanPlayerName), so by the time the name is a
  ## player address the separator reads "_(N)" — accept either. Names without
  ## the suffix (local self-play "Player1"…) pass through unchanged.
  result = address
  if result.len >= 4 and result[^1] == ')':
    var i = result.len - 2
    while i >= 0 and result[i] in {'0' .. '9'}:
      dec i
    if i >= 1 and i < result.len - 2 and result[i] == '(' and
        result[i - 1] in {' ', '_'}:
      result = result[0 ..< i - 1]
      while result.len > 0 and result[^1] in {' ', '_'}:
        result.setLen(result.len - 1)
