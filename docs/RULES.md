# Coworld CTF — Game Rules

> The supplied `config.json` runs the competitive **Emerg-ant** foraging mode.
> Its objective and pheromone rules are in [EMERG_ANT.md](EMERG_ANT.md); all
> unchanged movement, combat, fog, and item rules are defined below.

Coworld CTF is a two-team capture-the-heart shooter for the Coworld platform. Two
teams start on opposite edges of a symmetric arena, each with its own heart on a
home pedestal. Players move, take cover behind obstacles, and shoot. Steal the
enemy heart and carry it home — or eliminate the enemy team — to win. Vision is
fog-of-war: the map is always visible, but enemies only appear inside your
forward vision cone or your small omnidirectional bubble.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift): it keeps
Crewrift's continuous 2D movement, line-of-sight, sprite protocol, server, and
replay infrastructure, and replaces the social-deduction game layer (roles,
tasks, voting) with teams, guns, hearts, and fog-of-war vision.

---

## Overview

- **16 players, 8 vs 8.** Red team spawns along the **left edge**, Blue along the
  **right edge**.
- **Two team hearts**, one on each team's **home pedestal** inside its spawn
  pocket (classic two-object CTF, with hearts for flags).
- **GameVersion 42 makes standing on the pedestal enough to take the heart.**
  The steal radius was 12px around the heart's exact center — a fifth of the
  60px sprite drawn on a 96px pedestal — so the visible target overstated the
  real one fivefold, and players and policies alike stood plainly on the heart
  without picking it up. The radius is now **34px**, derived from the drawn
  heart's own half-extent, so anywhere the art is under your feet is a grab.
  It still stops well inside the pedestal's spawn pocket, so no steal reaches
  through a wall.
- The arena is filled with **staggered cover** (a slalom of offset wall
  stubs, diamonds, discs, and diagonal chevron walls, mirrored symmetrically so
  neither team has a positional advantage): **no straight shot crosses the
  field**, so every approach is a series of corners. GameVersion 16 thinned
  the disc column to every other disc, opening real gaps in the mid-field
  slalom.
- The **eight diamonds flanking the center spin**, and since **GameVersion 28
  the spin is real geometry**: the rotating silhouette you see is the exact
  footprint that stops your feet, your bullets, and your line of sight. A
  quarter turn takes ~2.7s (16 frames, one every 4 ticks), the two halves turn
  in mirrored directions, and the angle derives only from the tick — so every
  viewer and every replay sees the same stone. The blocked lane through the
  center therefore **opens and closes on a clock**: a vertex that covered you a
  second ago may have swung away. A player the sweep engulfs is pushed to the
  nearest free floor rather than trapped inside stone, and never onto another
  body.
- **GameVersion 31 makes sprayed paint hurt.** Two changes close the same
  gap — paint visibly covering a cog that walked away clean. First, the cone
  hits **bodies, not center points**: a sprayed cog is tested as a **17 px
  disc** (half its 34 px body), where it used to be the bare point its 1 px
  collision box describes — largest effect **point-blank**, where the cone
  was narrower than the cog it covered. Second, the **reach grew 4 → 5
  squares**, with the width grown to match so the **14° half-angle did not
  change**; the 5th square is exactly what it takes to cover the tip of the
  plume the game draws. See the Spray can section for the shape.
- **GameVersion 38 makes the spray one directional shot, not a sweep.** A
  fired cone now locks its aim at the moment of firing and keeps it for the
  whole 5-tick window: spinning the cog after you press no longer rakes the
  cone around you. The cone's origin still rides its owner, so a moving
  sprayer drags the stream forward — only the rotation is pinned. See the
  Spray can section.
- **GameVersion 30 puts every team's pickups on the map's own symmetry.** A
  team's shield and spray can are Red's spots carried over by whichever
  symmetry the terrain was built with — mirrored, rotated 180°, or turned a
  quarter at a time on the 4-team boards. Only that image lands in equivalent
  terrain: a mirrored copy on a rotational map sits in the rotation of Red's
  *other* pickup, so one team's shield had cover and sightlines the other's
  did not. See "Shields" and "Spray can".
- **GameVersion 29 extends the live spin to generated terrain**, fairly. Which
  diamonds spin is decided by a band down the center column, and that choice
  is **closed under each map's own symmetry** — on the 90°-rotational 4-team
  boards the band's closure is a cross, so a diamond never turns while its
  quarter-turn twin sits as solid stone. Spin **direction** follows the same
  logic: a mirror map turns its two halves opposite ways (a reflection
  reverses a rotation), while a 180°- or 90°-rotational map turns **every**
  diamond the same way, because a rotation does not. The terrain generator
  also judges a spinning diamond from both ends of its turn — sightlines and
  the cover floor against its **narrowest** footprint, corridors and the
  cover ceiling against its **widest** — so a map cannot pass validation on
  a firing lane that is only blocked at rest. Two seeds in the previous
  curated pool did exactly that, and the pool was re-drawn without them.
- In the outermost stub column of each half, the glass alternates in from
  both ends: the **second stub from the top, the middle stub, and the second
  from the bottom (GameVersion 27) are glass windows**: they block movement,
  bullets, and
  spray cones exactly like stone, but **vision passes straight through them**.
  Glass draws as a pale pane with diagonal sheen — cover you can be seen
  behind is not cover.
- The old midline chevron zigzag is now a **square-bracket wall pair framing
  the flag ring** (`[ … ]`, GameVersion 16), and the middle of each bracket's
  bar — dead on the center row — is a **glass window**: the mid lane stays
  closed to movement and fire, but both teams can watch the center corridor
  through the glass.
- **Trenches** — walkable dug-pit squares — are a **config-gated terrain
  feature**: the default arena has none; generated maps (below) place them
  procedurally, steered by `mapPits` / `mapPitDensity`. See the Trenches
  section for their rules.
- **Paint puddles** — damage-over-time floor hazards — are a **config-gated
  terrain feature**: no map has any unless `mapPuddles` requests them. See
  the Paint puddles section for their rules.
- **Cardboard barriers** — placeable paint-blocking cover — are a
  **config-gated pickup**: no map has any unless `barrierPickups` requests
  them. See the Cardboard barriers section for their rules.
- **Procedurally generated terrain is available as a config option**
  (`mapPath: "pool"` draws from a curated 20-map pool, `"gen"` + `mapSeed`
  generates directly; `mapSize` / `mapSymmetry` / `mapColumns` /
  `mapWindows` / `mapCenterFeature` / `mapEndzone` lock individual draws).
  Generated layouts keep every arena invariant — exact team symmetry
  (vertical mirror or 180° rotation), no straight cross-field shot,
  corridors at least twice the player footprint, a bounded cover budget —
  and draw their size class (`small` / `standard` / `large` / `huge` /
  `giant` — `giant` is the old `large` ceiling doubled, up to 3211x1713 on
  a 2-team board; obstacle sizes never scale, bigger fields draw more
  cover columns instead), obstacle columns, glass placements, center
  feature, endzone archetype, and med-kit pair per map. The exact geometry
  is pinned into the match config/replay as `mapSpec`. The default league
  map remains the hand-tuned arena described above; leagues opt in through
  their own config.
- **Compact endzones** are one of those draws. Half of generated 2-team maps
  keep the classic home column; the rest pull the base **well off its home
  edge** and wrap it in a **disc or square endzone** (`mapEndzone`:
  `"column"` / `"disc"` / `"square"`), which turns the whole home border
  strip into ordinary **wilderness** — cover, glass and pits wrap all the
  way around and behind the base. Scoring follows the shape: a carrier
  scores by crossing the painted ring from ANY side, including from behind.
  Such maps are validated for an OPEN FLANK — four clear cardinal approaches
  into the ring, and a route from behind the base to midfield that never
  enters the endzone — so a deep base cannot be defended as one front line.
- A round ends when at most one team still stands: **capturing a heart
  eliminates its team** (GV32 — every player on the captured team dies with
  no respawn, and the heart leaves play where it was captured), and a team
  with no live players is **wiped out**. In classic 2-team play a capture
  therefore still ends the round on the spot.
- **A dead team's heart leaves play with it** (GV33): the moment a team is
  completely killed — captured or wiped — its heart is retired and no
  longer drawn. If an enemy was carrying that heart when the team fell,
  it drops straight off their back (restoring full speed and fire rate);
  a retired heart cannot be stolen or captured.

## Teams & spawns

- Players are assigned to **Red** or **Blue** by slot (8 each).
- A slot may configure a cosmetic **skin** (`slots[i].skin` in the game
  config; currently `default` or `crown`) that restyles that player's body
  art. Skins are cosmetic only: no gameplay effect, and the player, corpse,
  and selected-player observation labels are unchanged, so policies cannot
  (and need not) distinguish them.
- Each team's players get a fixed **identity**, `alpha` through `theta`, by
  slot order within the team — deterministic across matches and replays. A
  small Greek-letter badge (Α Β Γ Δ Ε Ζ Η Θ) rides each living player's
  sprite, and the badge object is labeled `identity <color> <name>` (e.g.
  `identity red alpha`). Badges are fog-gated with their player: seeing a
  player means seeing who it is. Existing `player <color> <side>` labels are
  unchanged.
- Each team has a **home edge**: Red = left, Blue = right.
- Players start just inside their home edge. When killed they respawn at a
  **random spot inside their own endzone** (GameVersion 25) — the respawn
  point cannot be camped.

## Four-team mode (config-gated)

The default game is the classic 2-team arena above; nothing changes unless a
config opts in. With `"teams": 4` (and `"mapPath": "gen"`), the game seats
FOUR teams — **Red, Blue, Green, Yellow** — in a free-for-all on a generated
square map:

- **Layouts** (`"mapLayout"`, or drawn from the map seed): `"corners"` puts a
  team in each corner (Red top-left, Blue top-right, Green bottom-left,
  Yellow bottom-right) with a DIAGONAL endzone — a 45-degree threshold line
  cut across the corner; `"plus"` puts a team at each edge midpoint (Red
  west, Blue east, Green north, Yellow south) with an arm-mouth endzone —
  the corners are open battlefield. Both are fully open square boards whose
  terrain replicates a generated quadrant by 90-degree rotation, so all
  four quarters are exactly fair: the WALL MASK a team plays against is
  pixel-for-pixel the quarter turn of every other team's, homes included.
  Each team's spawn pocket rotates with its home, so the north and south
  pockets of a plus board lie on their sides relative to the east and west
  ones — a pocket that stayed upright everywhere would be a different
  shape than its own rotational twin.
- **Every team has its own heart** on its own pedestal, and its own capture
  zone behind it. Steal ANY other team's heart and carry it into your own
  zone to **eliminate that team** (GV32): its players all die for good and
  the captured heart is out of play for the rest of the round. A team
  wiped out by kills loses its heart the same way (GV33): it retires on
  the spot — even straight off an enemy carrier's back — and is no longer
  drawn. Allies do not exist: 4-team play is pure
  free-for-all, and a "2v2" is simply two policies splitting one classic
  team's seats.
- **Seats deal round the teams** by slot order (slot mod 4): 4 players per
  team on a 16-seat roster, 8 per team on a 32-seat roster (the Paintbot
  `4ffa8` variant, always on a giant generated map). Identities stay
  per-team (`alpha`..`delta` at 4 per team, `alpha`..`theta` at 8).
- **The last team standing wins**: the round ends when at most one team
  still has live players — so a 4-team winner either captures all three
  rival hearts or outlives the field (captures and wipes mix freely); an
  eliminated or wiped team just sits out until then.
- **Scoring is zero-sum by construction**: the winning team scores **+1 per
  losing team**, each losing team scores **-1**. Classic 2-team play stays
  +1/-1; a 4-team win pays **+3** to the winner and **-1** to each loser.
  Time-limit draws still pay -1 to everyone. (Under `scoring: "pot"` the
  4-team win pays **+4** instead — see "Scoring".)
- **Labels are unchanged in shape**: the same `player <color> <side>`,
  `<color> flag [planted]`, shout, and identity vocabulary — `green` and
  `yellow` simply appear as team color tokens alongside `red` and `blue`.
- Med kits become a rot90-fair diamond of four; each team gets one shield
  and one spray-can pickup near its endzone; the four grenade pickups move
  to the edge midpoints (corners layout) or a rot90 orbit around the
  center (plus layout).

## Movement

- Movement is **continuous** (acceleration, friction, max speed, wall-sliding) —
  the d-pad drives it.
- Movement is **pure locomotion**: it never changes where you aim or look.
- Player bodies are **solid**: you cannot drive over or through another live
  player (friend or foe). Contact is a **slightly elastic collision** — equal
  masses, `playerBouncePct` restitution (default 40%): ramming a standing
  player shoves them forward and keeps a little of your speed; a head-on
  meeting bounces both back at 40% of the closing speed. Glancing contact
  slides around the body the same way wall-sliding works. Corpses never block.

## Aim

- Every player has a **continuous aim angle** reported in **brads** (256 units
  per full turn, integer — deterministic): **0 = east (+x)**, increasing
  **counter-clockwise on screen** in map coordinates (64 = north, 128 = west,
  192 = south).
- The aim is **decoupled from movement**. Hold **B** to rotate the aim
  **counter-clockwise**, hold **Select** to rotate **clockwise**, at
  `aimTurnRate` brads per tick (default 5 ≈ 7°/tick; a full turn takes ~2.1s).
  Holding both rotate buttons cancels out. The d-pad **never** touches the aim.
- The aim drives everything directional: the **gun** fires along it, the
  **vision cone** centers on it, and the sprite flip follows it (you face left
  while aiming left-ish).
- On spawn and respawn your aim points **toward the enemy side** (Red → east,
  Blue → west).
- A player's **facing** is shown by the soldier sprite itself: the held gun
  sweeps to the aim angle (the sprite reports a coarse `right`/`left` side in
  its label), and — for anyone you can see — the direction they can shoot is
  exactly the lane their body faces. There is no longer a separate floating
  aim-dot indicator; the vision cone and the swept gun convey aim.

## Vision (fog of war)

Every player observes the **full map** — the terrain is static knowledge and is
always drawn — but moving entities are fogged:

- Your **vision** is a **forward cone** of half-angle `visionConeDeg` (default
  ±60°) around your **aim angle**, reaching **1.5× the gun range** (1575px
  stock, since GameVersion 34 — sight outranges paint by half again), plus a
  small **omnidirectional bubble** of `visionBubble` (default ~90px) around
  you that the range cap never shrinks.
- **Stone walls block vision** — the same walls that block bullets — with one
  exception: **glass windows** (the second-from-top, middle, and
  second-from-bottom stubs of each half's outer stub column) block bullets
  but NOT vision. A long open
  lane is visible (and lethal) end to end; anything behind stone is not;
  anything behind glass is **seen but safe from direct fire**.
- **Your aim carries your vision.** You look where you aim, not where you walk,
  so watching a lane, sweeping an arc, and turning your back are deliberate
  rotation choices - and moving somewhere no longer reveals it.
- Everything outside your vision is **masked**: enemies, an enemy carrying a
  heart, and death splatters from unseen events are simply not in your
  observation. The unseen area is dimmed by a fog overlay.
- **Bullets are invisible to players.** Shot tracers and muzzle flashes are
  spectator/replay rendering only — no player observation ever contains
  them, whether the shot crossed your vision or not. Players learn of
  gunfire only by sound (below).
- **Always visible regardless of fog:** the static map, **both heart pedestals**,
  your **own heart's state** (its pedestal heart is never hidden — an empty own
  pedestal means your heart is stolen), and **yourself** via a distinct self
  marker. **Teammates are fogged like everyone else** — there is no team
  radio; keeping track of your own side takes eyes too.
- **Only a shot's landing is audible — and sound is all a player gets.**
  Every shot leaves every living player one brief hollow **impact ring**
  (label `shot impact`) near where it landed, for ~0.5s, regardless of line
  of sight. **Firing itself is silent**: the muzzle emits no signal, so
  pulling the trigger never reveals the shooter's neighborhood — only where
  the paint lands. The ring is randomly (but deterministically, per shot)
  offset by up to ~20px, so it tells you something was hit *roughly there*
  — never the exact spot, the shot's line, or which team.
- **Another soldier's drawn gun angle is approximate (since GameVersion 24;
  self exempted since 26).** Every OTHER soldier sprite in a player's view —
  enemies, teammates, and corpses — renders its gun rotated by the true aim
  plus a deterministic pseudo-random offset of up to **±20°**, re-rolled about
  twice a second: watching another bot never reveals its exact aim. Your OWN
  self marker shows your TRUE aim — your gun is your own state, not a leak.
  Every soldier sprite (self included) draws its gun at the nearest of 16
  pre-rendered steps, 22.5° apart — so the self marker is true aim rounded
  to within ±11.25° (±8 brads), with no fuzz on top, while other soldiers
  carry the ±20° fuzz before the same rounding.
  (The spectator broadcast board also shows true aim.)
- There is **no global heart tracking**: once a thief carries your heart into the
  fog, finding it again takes eyes on it.
- Death does not lift the fog: a dead player sees the whole map fogged —
  only the terrain, the pedestal hearts, and their own corpse — until they
  respawn (their inputs are ignored).

## Combat

- **Every player has `hitPoints` (default 3) per life.** Each bullet that hits
  removes one hit point; at zero you die. Hit points reset to full on every
  respawn. Your own remaining HP shows on your HUD next to your lives.
- Press **A** to fire. Firing has a short **cooldown** between shots (it is not a
  continuous beam).
- Pressing fire starts a short **windup** (~0.2s): your aim locks the moment
  you pull the trigger, and the bullet leaves at the end of the windup. A
  target that peeks out and ducks back behind cover before the release
  survives the shot.
- The bullet is **hitscan along your aim ray**: it travels down the locked
  aim direction and hits the **first player whose footprint crosses its
  narrow corridor** — it never passes through a body to hit someone behind,
  and **walls stop it**.
- **Range is a fixed 1050 px on every map** (since GameVersion 34) — the
  small generated map's field width. Only on the smallest board is the gun
  map-wide; on larger fields paint simply falls short, so closing distance
  matters. Paint that runs out of range hits nothing and marks nothing.
- **Aim is fuzzed** (since GameVersion 34): every released shot's direction
  gets a small random angular error (~0.6° sigma), calibrated so a **fully
  visible** body at **max range** is hit **80%** of the time. Accuracy
  sharpens fast as you close: ~99% at half range, effectively perfect
  inside a third. The noise also rides shots at partial cover — a sliver
  target at long range is doubly hard.
- **Cover is partial, not binary.** A target's body is sampled across its
  silhouette: only the part of the body that is both inside the bullet
  corridor AND visible from the shooter can be hit. A corner-hugger showing
  a sliver is exactly as hittable as that sliver — no more (fully hidden
  body parts cannot be tagged through the wall), and no less (the poking
  shoulder is fair game even when the body's center is safely covered).
  More exposure means more aim angles connect.
- **Friendly fire is ON.** A shot hits the first valid target regardless of team,
  so firing into a cluster of teammates can kill your own escort.
- **Same-tick shots resolve simultaneously.** Every trigger pulled on the same
  tick picks its target against the same snapshot before any kill applies: a
  mutual face-off duel kills both shooters, and neither team gains an
  input-processing-order advantage.

### Shot micro (frame data)

The full life of one shot, at 24 ticks/second:

1. **Trigger pull (tick 0).** Fire is edge-triggered: a shot arms on the
   tick the button goes down — holding it does nothing, and a second pull
   during a pending windup is ignored. The pull is refused entirely while
   the cooldown is still running.
2. **Windup (5 ticks, ~0.2s).** Your **aim angle locks at the pull**;
   turning during the windup does not bend the pending shot (it only
   re-aims the next one). Your **position stays live**: movement is
   full-speed and unrestricted during the windup.
3. **Release (tick 5).** The bullet resolves instantly (hitscan) **from
   your position at release, along the angle locked at the pull**. All
   movement for the tick happens first; every shot releasing that tick then
   resolves at once against the post-movement snapshot.
4. **Cooldown (12 ticks, ~0.5s; 3x that for a shield carrier — and, since GameVersion 26, 3x for a HEART carrier too: carrying the heart no longer means free full-rate fire; shield+heart take the max multiplier, not the product).** The
   cooldown starts at release, so the sustained rate is one shot per
   cooldown — the windup does not slow your cadence.

What that means in practice:

- **Strafe-firing works.** The shot line translates with your movement
  (new position, old angle), so lead your own strafe when you pull.
- **Fire-and-duck can waste your own shot.** Line of sight is checked from
  your release position: step behind a wall during your windup and the
  wall eats your bullet.
- **Targets can dodge the windup.** Anyone who breaks line of sight during
  your ~0.2s windup survives; the aim lock is the price of the shot.
- **The corridor is forgiving.** The bullet is a ray with an 8px half-width
  corridor sampled against the target's ~12px-wide silhouette — near-misses
  connect; precision beyond the corridor width buys nothing.
- **Respawners are live immediately.** There is no spawn protection: a
  freshly respawned player can shoot and be shot (and blocks bullets) from
  their first tick.

## Grenades

- **Four grenade pickups spawn in the arena corners** — two on each team's
  side — a fixed inset inside the border walls. Anyone may take either
  side's pickups by **touch**; a taken corner **refills 5 seconds later**.
- **Each player carries at most one grenade.** Dying loses the carried
  grenade (nothing drops).
- **Throwing:** hold the **C button** (input mask bit 128) to charge, release
  to throw along your **current aim**. The charge picks the distance, from a
  short tap (~30 px — inside the blast radius, so a panicked drop can hurt
  you) up to a full-charge **maximum of one fifth of the field width**
  (~247 px) after ~1s of holding. While you charge, a **throw target ring**
  marks the landing spot on your own view (and is readable intel for anyone
  who can see you, like your aim line).
- **Grenades fly over every obstacle** in a straight lob from thrower to
  target and **explode on landing**. The burst comes a **fixed two shot
  windups (~0.4s) after release, near or far** — long throws just travel
  faster. A grenade is a snap weapon: the reaction window is the same as
  eating two aimed shots, not a mortar shell you can stroll away from.
- **The blast hurts everyone whose body touches its radius (~52 px): enemies,
  teammates, and the thrower alike**, removing 2 hit points each — **unless a
  trench is involved, which changes the amount**; see the Trenches section. It
  is your BODY that must reach the circle, not the point you stand on — the
  same rule the gun's bullet corridor uses — so a cog centred up to ~58 px away
  is still caught. The landing splat and the charge-time throw-target ring are
  drawn at the blast diameter, so anything painted was hit, but a cog clipping
  the rim from just outside it is hit too. Kills credit the thrower (except
  suicides).
- **Throwing is silent; landing is loud.** A landing you could not see
  leaves a large jittered sound ring (label `grenade sound`) — landing-only
  audio, exactly like gunshot impact rings. The throw itself leaves nothing.
- Observation labels: pickups `grenade`, airborne `grenade air`, the marker
  above a carrier `grenade carried`, the charge marker `throw target`, the
  landing flash `blast stage N`.

## Spray can

- **Two spray can pickups spawn high in the side back columns** — Red's in
  the TOP half (a quarter of the map height down, between the top corner
  grenade and the side midpoint), nudged to the nearest walkable floor. The
  shields hold the matching bottom-half spots. Both spray cans are present
  when the game starts, and a taken one respawns after **30 seconds**.
- **The other team's can is Red's spot carried over by the map's own
  symmetry** (GameVersion 30), not simply mirrored across the midline. On a
  180°-rotational map that puts Blue's can in the BOTTOM half, because that
  is where the rotation sends Red's — mirror it instead and it lands in the
  rotation of Red's *shield*, so the two teams fight for the same item in
  differently-shaped terrain.
- **Each player carries at most one spray can**, independently of their
  grenade. Dying loses the carried can; nothing drops.
- While carrying a spray can, **A sprays a forward paint cone instead of
  firing the gun**. The cone reaches **5 squares** in front of the player
  (170 px — one square is one 34 px cog body) and widens linearly to
  **2.5 squares (85 px) at max reach**, a constant half-angle of
  atan(1/4) ≈ 14°. The gun is disabled while the can is held; C still
  throws a carried grenade normally.
- **The cone hits bodies, not center points** (GameVersion 31). Those reach
  and width figures describe the cone's **centerline**; a cog is tested as a
  **17 px disc** (half a 34 px body) against it, so paint that visibly
  engulfs a cog takes its hit points. In effect the cone covers **187 px**
  forward and **17 px extra to each side at every distance** — which matters
  most **point-blank**, where the centerline cone is narrower than the cog it
  covers (±10 px at 40 px out, against a ±17 px body). Spraying **backwards**
  still hits nobody: the can points forward, so a cog behind the sprayer is
  out regardless of its body.
- **What the mist draws is not exactly what the cone covers.** The plume is a
  chain of round puffs drawn oversize so they merge into one jet, so it spills
  past the shape that sizes it. The reach is set to swallow that spill
  lengthwise — nothing the paint **engulfs** survives — but the mist still
  runs about **15 px wider** than the cone, so a cog can catch paint on its
  **edge** without taking damage. Closing that too would need a 31° cone.
- **The cone stays on for 5 ticks**, riding the attacker's position but
  **holding the aim it was fired at** (GameVersion 38): one press is one
  directional shot, so turning the cog mid-spray no longer sweeps the cone
  across a fan of targets — only the origin moves with you, not the direction.
  Then the can takes **20 ticks to repressurize** (one burst every 25 ticks).
  The cone shuts off if its owner dies.
- **A touch removes 3 hit points, once per victim per burst** — instantly
  lethal to a bare 3 hp cog, while a 6 hp shield carrier survives the first
  touch with 3 hp left. The cone affects teammates too and requires line
  of sight. Kills credit the attacker.
- A spray touch **paints its victim** (it stamps the same paint-hit tick the
  paintball gun and grenade do), so a sprayed seat's first-person view takes a
  paint splat across the visor.
- Observation labels: pickup `spray can`, carrier marker
  `spray can carried`, and the fading cone `spray paint puff` (a run of
  team-colored paint-mist puffs along the attacker's aim each active tick).
- **A carrier visibly holds the can**: the cog's held paintball marker is
  replaced by the spray can while one is carried (sprite label `cog spray can
  <color>` in place of `cog gun <color>`), so the silhouette shows which weapon
  is live.
- The cone's puffs **jet outward** from the nozzle to full reach as each burst
  ages, then thin out; overlapping per-tick snapshots make a held trigger read
  as one continuous plume. Purely cosmetic: the damage cone is the full
  4-square shape from the first active tick, regardless of how far the
  animation has travelled.

## Shouts

- **Any living player can shout: a short text message, at most 10
  characters** (longer messages are truncated; non-printable characters are
  dropped). Send it as a chat packet (`0x81`, the standard sprite-protocol
  chat message); in the browser client press **Enter**, type, and press
  Enter again.
- **Anyone within one fifth of the field width (~247 px) hears it** —
  through walls and fog, like gunfire. Outside that radius the shout does
  not appear in your frame at all.
- A heard shout appears as a speech bubble labeled
  `<team> shout <name>: <text>` pinned at **deterministically jittered
  coordinates** (~±20 px, like gunshot impact rings): you learn roughly where
  the shouter is, never exactly.
- `<name>` is the shouter's **anonymous slot letter** (`alpha`..`theta`, ranked
  within its own team — the same identity the `identity` badges use), never the
  connecting player's name. Listeners on both teams read these labels, so the
  label deliberately carries no clue about **whose policy** is talking. Split
  the label on the first `": "` and treat the rest as payload; `?` in the name
  position means the shouter left while the bubble was still up.
- **Rate limit: one shout per second per player**, and each player has at
  most one live bubble (a new shout replaces the old). Bubbles fade after
  **3 seconds**. Dead players cannot shout and hear nothing.
- The global/replay view draws every bubble at the shouter's actual
  position, following them while they live.
- **Shouting is free**: it never consumes, delays, or modifies any other
  same-tick action — you move, aim, and fire exactly as if you had said
  nothing; its only limit is its own one-per-second cooldown.

## Trenches

- A **trench is a 56×56 px walkable dug-pit square** that draws as a
  recessed dark pit in the floor. It is **not a wall**: it never blocks
  movement, bullets, or vision. Trenches are **config-gated** and ship
  without a game-version bump, exactly like procedural terrain: **the
  default arena has none**, and a league opts in through its own config
  (generated maps dig them per seed; a `mapPits: 1` lock reproduces the
  classic single center pit).
- **Generated maps dig additional trenches procedurally**, drawn per seed
  in three placement classes: **instead of an obstacle** (a slot that would
  raise cover digs a pit — cover you stand in rather than behind), **in the
  gaps between a column's obstacles** (the corridor stays open; crossing it
  the slow way is a choice), and **in each endzone around the flag** —
  behind the pedestal toward the home edge, and above and/or below it.
  Every dig is mirrored under the map's team symmetry, so neither team gets
  a private pit, and the exact trench set is pinned in the replay's
  `mapSpec` like the rest of the geometry.
- **Two runtime knobs steer the digging** (game config, generated maps
  only): `mapPits` locks the exact TOTAL pit count (0..64) — even counts
  place symmetric pairs; an **odd count anchors its extra pit at the exact
  map center**, the one spot that is its own image under both mirror and
  rot180 symmetry, so odd and even counts are equally team-fair. When the
  candidate spots can't host the full request the map places as many as
  fit. `mapPitDensity` (0..1000, default 100) scales the per-class draw
  chances instead when no exact count is locked — 0 digs nothing, 200 digs
  roughly twice as much. `mapPits` wins over `mapPitDensity`.
- You are "in" the trench exactly while your body center is inside the
  square; every effect below applies instantly on entry and ends instantly
  on exit.
- **Getting in is fast; climbing out is slow.** Dropping into a pit and
  moving around inside it run at full speed — momentum carried in is kept.
  But while your center is inside, any movement **away from the pit's
  center** — climbing a wall to leave — has its speed cap and acceleration
  divided by five, and outward momentum sheds to that cap. A pit is easy
  to take and costly to abandon.
- **Occupants fire their gun at 1/3 rate** (each shot's cooldown is three
  times the normal length). This composes with the shield/heart-carrier
  slowdown by taking the maximum, never the product.
- **70% of gun shots that would hit an occupant fly straight over
  instead**: the occupant is below grade, so the bullet misses, deals no
  damage, counts as a miss for the shooter, and **carries on down the ray**
  — it can land on an exposed body behind the trench, or on the far wall.
  The duck is rolled per crossed occupant on the deterministic sim RNG.
- **Shots fired from inside the same trench are never ducked** — the
  protection is against fire from outside; two players inside the same
  trench duel normally.
- The fly-over protection applies to **gun shots only**. Spray cones deal
  their ordinary damage regardless of trenches on either side.
- **A grenade blast's damage depends on the trench it lands in, not the
  trench radius.** A blast that lands in the SAME trench as a victim traps
  them below grade with nowhere to duck: **6 hit points**, GrenadeTrenchDamage
  — three times the open-field amount, and lethal to a bare cog through a
  6 hp shield in one blast. A victim standing in ANY OTHER trench — the
  blast landed in the open or in a different pit — is mostly shielded by
  their own pit's lip: **1 hit point**, GrenadeTrenchSplashDamage. Anyone
  outside every trench takes the ordinary GrenadeDamage (2) exactly as
  before. The landing splat and blast-flash animation are truncated to the
  trench's own 56×56 footprint when the blast is trapped in one, instead of
  spilling out to the full open-field blast size — what you see burning is
  what's amplified.
- Occupants are still subject to normal fog-of-war visibility — the trench
  itself grants no concealment.

## Paint puddles

- A **paint puddle is an organic splat-shaped floor hazard, nominally ~64 px
  across** — a union of overlapping paint discs (one core plus a few flung
  lobes, reaching at most 45 px from the anchor) drawn as a violet spill on
  the ground. The painted spill IS the gameplay footprint — you take the
  damage roll exactly where you see paint. It never blocks movement,
  bullets, or vision, and never slows anything — its only rule is damage
  over time.
- **Every full second (24 ticks) your body center spends CONTINUOUSLY
  inside a puddle rolls a `puddleDamagePct` (default 20%) chance of 1
  damage.** The roll's damage goes through the shield layer first, like
  every weapon's. Stepping out — even for one tick — restarts the second;
  dying resets it too.
- A lethal puddle roll is an **environmental death**: no player is credited
  with the kill (the log reads "dissolved in a paint puddle"), but it counts
  as a normal combat death for lives and respawn.
- **Puddles are config-gated and ship in NO map by default.** `mapPuddles`
  (0..64, COUNT mode only — there is no density mode) places that many on a
  2-team generated map: even counts place mirror-symmetric pairs, an odd
  count anchors its extra puddle dead center. Each blob's shape is drawn
  from the map seed; a placed pair is the blob plus its exact symmetry image
  (bit-exact integer transforms), and the center blob's ring is stitched
  self-symmetric, so the hazard is always team-fair. Spots land on open
  floor clear of walls, trenches, other puddles, and both teams' base
  pockets; the exact set is pinned in the replay's `mapSpec`, so playback
  never re-rolls it. 4-team maps do not support puddles yet (an explicit
  request errors).
- Each puddle is stated to policies as an init-snapshot marker,
  `puddle <x0>,<y0> <x1>,<y1>` — see the stated-marker section below.

## Med kits

- **Two med kits sit on the center line** — at one third and two thirds of
  the field height, nudged to the nearest walkable floor.
- **Touching one while hurt restores your hit points back to full.** A
  healthy player walks over it untouched — a kit is never wasted.
- **A taken kit respawns 30 seconds later** in the same spot.
- Observation label: `med kit`. Kits are fog-gated like the grenade
  pickups: you see one only where you have vision.
- **Med kits never block anything** — not movement, not bullets, not
  line of sight. They are floor pickups, not cover.

## Shields

- **One shield sits deep in each team's endzone.** Red's is in the same back
  column as the corner grenade pickups but in the BOTTOM half (three
  quarters of the map height down, between the side midpoint and the bottom
  corner grenade), nudged to the nearest walkable floor. The spray cans hold
  the matching top-half spots. On a **compact endzone** (disc/square) there
  is no back column: the shield sits inside the zone below the pedestal and
  the spray can above it.
- **Every other team's shield is Red's spot under the map's own symmetry**
  (GameVersion 30) — mirrored on a mirror map, rotated on a rotational one,
  and a quarter turn round on the 4-team boards. Only that image sits in
  terrain equivalent to Red's; a mirrored copy on a rotational map lands in
  the transpose (4-team) or in the spray can's terrain (2-team), which is a
  fairness difference in cover and sightlines, not a cosmetic one.
- **Touch a shield to pick it up** — either team may take either endzone's
  shield. A shield is a **3 hp armor layer on top of your base hit points**:
  damage depletes the shield layer first, and only then your base hp. The
  layer draws as blue pips appended to the overhead hp bar (base hit points
  stay green) and as the ` shield <s>` tail of the bar's label. A
  pickup refills the layer to 3 but **never heals base damage** (med kits
  do that) — so a worn carrier can take another shield to restore the
  layer, while a carrier whose layer is intact leaves the spawn untouched.
- **A depleted layer breaks the shield outright** (GV23): the moment the
  last shield hp is absorbed, the shield is gone — the carry icon and the
  `shield` label drop, the fire slowdown ends (an in-flight slowed cooldown
  re-clamps to the normal length), and the player may take a fresh shield.
- **While carrying a shield you fire 3x slower.** A fresh player with a
  fresh shield has 6 effective hp (3 base + 3 shield). Each shot you fire
  starts a cooldown three times the normal length until the shield breaks
  or you die. You can still move, carry the heart, and throw grenades.
- **A shield is lost when you die** and is not dropped on the ground; the
  taken endzone shield **respawns 30 seconds later** in the same spot.
- Observation label: `shield`. Shields are fog-gated like the med kits and
  grenade pickups: you see one only where you have vision, and a small
  marker floats over a shield carrier you can see.

## Cardboard barriers

- **Config-gated** (`barrierPickups`, default 0 = none): when on, each team
  gets that many folded-cardboard pickups (1 or 2), staged on the line from
  the team's base anchor toward map center — one at the midpoint, two at the
  thirds — nudged to the nearest walkable floor. Every other team's spots
  are Red's under the map's own symmetry, like the shields and spray cans.
- **Touch a pickup to carry one folded barrier.** Either team may take
  either side's pickups. **A barrier and a grenade cannot be carried
  together** — both are spent with button C — so a grenade carrier walks
  over the pickup untouched and vice versa. A taken pickup **respawns 30
  seconds later**; the carried sheet is **lost when you die** (never
  dropped).
- **Press C to place it where you stand.** The cardboard unfolds instantly
  into a **standing half-hex** — three sides of a hexagon, vertices
  `BarrierRadius` (24px) from your center at aim −90°/−30°/+30°/+90° — with
  the **flat middle side across your aim** (~21px in front), wrapping your
  front. Placement is a press-edge, no charge; the grenade's hold-to-charge
  lives on the same button but the mutually-exclusive carry keeps the press
  unambiguous.
- **Cardboard blocks paint, never sight.** The ~5px band stops gun shots
  and the spray cone (both damage and the drawn mist) exactly like a wall —
  but fog-of-war vision, movement, and grenades (which fly over every
  obstacle) ignore it entirely. Cover you can see through and walk through.
- **It takes 10 paintball hits** (`BarrierHp`): each blocked gun shot splats
  on the cardboard and chips one hit; the tenth shreds it. The spray cone is
  blocked but does no damage to it; grenade blasts ignore it.
- **Any cog that drives into the band flattens it instantly** — including
  the placer walking forward through their own front wall. Standing inside
  the half-hex is safe: the band is ~21px out, well clear of a body.
- At most **16 barriers stand at once** (`MaxBarriersPlaced`); placing past
  the cap folds the oldest standing barrier.
- Observation labels: `barrier` (folded pickup, fog-gated), `barrier
  carried` (marker over a carrier you can see), and the standing half-hex
  itself: `barrier up <x>,<y> f<brads> hp <n>` — placement center, facing,
  and hits left, updated live as it takes paint.

## Lives & respawn

- Each player has a fixed number of **lives**.
- When you die, you **respawn at a random spot in your endzone** after a short
  delay — as long as you have lives remaining (GameVersion 25; the spot is
  drawn fresh each death, anywhere in the home capture column, full map
  height, so campers can't sit on a known respawn point).
- When you run out of lives, you are **out for the rest of the round**.

## The hearts

- Each team's heart sits on its **home pedestal** inside the team's spawn pocket.
- **Stand on the ENEMY pedestal to steal its heart** (GV42). The steal fires the
  moment you are on the heart — there is no grab button and no pinpoint to find.
  The touch radius (`FlagPickupRange` = 34px) covers the **drawn heart**, which is
  60px across on a 96px pedestal disc, so any spot where heart pixels are under
  your feet takes it. Your own heart cannot be interacted with by your own team.
  While carrying you move **slower** but can **still shoot**.
- If the carrier is killed (or disconnects), the heart **returns instantly to its
  own pedestal**. A heart is never left loose on the ground: it is either carried
  or sitting on its pedestal.
- Your own heart's **state** is always observable: its pedestal is never fogged,
  so an empty own pedestal means it is stolen — but the **thief itself is fogged**
  like any other enemy.

## Winning

A round ends immediately when either condition is met:

1. **Capture** — carry the **enemy heart** into **your own home capture zone**.
2. **Wipe** — the entire **enemy team is out of lives**.

If neither happens before the **time limit**, the round is a **lose-lose
draw** — there is no tiebreak, and both sides are penalized.

**The clock only counts down** (GV41): nothing extends it — the GV23
"action floor" (kills and heart steals banking overtime) is gone. `maxTicks`
is the exact scheduled end, and the broadcast clock counts honestly to 0:00.
With the grenade barrage configured, 0:00 does not end the round at all (see
below); without it, the scheduled end is still the scoreless-draw ceiling.

## Grenade barrage (config-gated endgame)

An anti-stalling mode that makes timeout draws effectively impossible. Off by
default; a league turns it on with `barrageMaxPerSec > 0` (requires a time
limit).

- When the game clock reaches **`barrageStartSec` seconds remaining**
  (default 30 — 4:30 elapsed on the default 5:00 clock), environment
  grenades start raining onto the field: **4 per second**
  (`barrageStartPerSec`) landing within a **40px band inside every map
  edge** at first.
- The barrage **escalates linearly over `barrageSaturateSec` seconds**
  (default 30): the target band deepens until it covers the **whole
  board**, and the rate ramps to **`barrageMaxPerSec`** (10-20/s
  recommended, hard cap 50) — with the defaults, the entire arena is under
  maximum bombardment exactly as the clock reads 5:00 / 0:00 remaining.
- Shells are **ordinary paint-bomb blasts** (same radius, damage, trench
  rules, shield soak, and floor stains as a player lob) with nobody to
  credit: no kill/multi-kill stats for the environment, and a victim's death
  logs `shelled by the grenade barrage`. Deaths, lives, heart return, and
  respawns behave like any blast death.
- **The clock is not the end** (GV41): with the barrage on, a round ignores
  the time limit entirely. Past 0:00 the whole board stays under maximum
  bombardment until at most one team has live players — the survivor wins,
  and a **draw requires the last players of two teams to die on the same
  tick**. (Without the barrage, a timed round still ends at the limit as a
  scoreless draw.)
- **Observability**: incoming shells are ordinary `grenade air` orbs and
  `blast stage <n>` landings on both streams, and an invisible marker states
  the escalation outright: `grenade barrage depth <n> rate <n> start <n>`,
  present from the first tick whenever the mode is on (depth and rate 0
  until the barrage latches). Shells only land within `depth` map pixels of
  some edge.

## Scoring

Scoring is **sparse and win-only**:

- **Decisive round** (capture or wipe): every winner scores **+1**, every
  loser scores **-1**. (Four-team free-for-all generalizes this zero-sum:
  the winning team scores +1 per losing team — see "Four-team mode".)
- **`scoring: "pot"`** (config-gated; the default `"classic"` is the rule
  above) replaces the payout with an ante: **every team contributes one
  point and the winning team takes the whole pot**, the losing teams
  splitting the forfeit evenly. Two teams pay **+2 / -2**; four teams pay
  **+4** to the winner and **-1** to each of the three losers. Draws are
  unchanged.
- **Time-limit draw: -1 for both sides** (GameVersion 21). Running out the
  clock is never better than losing, so stalling has no upside for anyone.
- **Mutual-wipe draw** (both teams eliminated on the same tick): 0 for both
  sides — both at least fought to a decision.

Kills, deaths, heart pickups, carry time, and captures are still **recorded** in
the episode results for leaderboards and analysis — they just do not award
points. This keeps the training objective tied purely to winning.

## Controls

| Button | Action |
| --- | --- |
| D-pad | Move (locomotion only — never changes your aim) |
| A | Fire; while carrying a spray can, spray the paint cone |
| B | Rotate aim counter-clockwise (browser client: X or K) |
| Select | Rotate aim clockwise (browser client: Space or L) |
| C | Hold to charge a grenade throw, release to throw (browser client: C) |
| Chat packet | Shout, max 10 chars (browser client: Enter to type) |

---

## Tuning defaults (configurable)

These are starting values, exposed in the game config and tuned in self-play.

| Parameter | Proposed default | Notes |
| --- | --- | --- |
| Players | 16 (8v8) | All standard Coworld slots |
| Lives per player | 3 | Out of lives = out for the round |
| Hit points per life (`hitPoints`) | 3 | Shots to kill; reset to full on respawn |
| Respawn delay | ~3s | Time dead before respawning at a random endzone spot |
| Gun range | 1050px | Fixed on every map (the small map's field width); map-wide only on the smallest board |
| Aim jitter | ~0.6° sigma | Gaussian per released shot; 80% to hit a fully visible body at max range, ~99% at half |
| Fire windup | ~0.2s | Trigger pull to bullet release; aim locks at the pull |
| Fire cooldown | ~0.5s | Minimum time between shots |
| Carrier speed | ~70% | Movement penalty while holding the heart |
| Body bounce (`playerBouncePct`) | 40% | Restitution of player-player collisions; bodies are always solid |
| Aim turn rate (`aimTurnRate`) | 5 brads/tick | Rotation speed while B/Select is held (~7°/tick; full turn ~2.1s) |
| Vision cone (`visionConeDeg`) | ±60° | Fog-of-war forward vision half-angle; reaches 1.5× gun range (1575px stock), walls block |
| Vision bubble (`visionBubble`) | 90px | Omnidirectional close-range vision regardless of aim |
| Spray cone reach (`PlasmaArcReach`) | 170px (5 squares) | Forward cone reach along the centerline; one square = one 34px cog body |
| Spray cone max width (`PlasmaArcMaxWidth`) | 85px (2.5 squares) | Centerline cone width at max reach; widens linearly (half-angle atan(1/4) ≈ 14°) |
| Drawn plume span (`PlasmaArcFxReach` / `PlasmaArcFxMaxWidth`) | 136px / 68px | Art geometry the mist puffs are placed and sized against — deliberately shorter than the cone, because the puffs are drawn oversize and spill past it |
| Spray body radius (`PlasmaArcBodyRadius`) | 17px (half a cog) | The victim is a disc, not a point: added to the cone's reach and to its half-width at every distance |
| Spray damage (`PlasmaArcDamage`) | 3 hp | One touch per victim per burst; lethal to a bare cog, survivable by a shield carrier |
| Spray active window (`PlasmaArcActiveTicks`) | 5 ticks | The sprayed cone stays on, tracking its owner's position and aim |
| Spray can reset (`PlasmaArcResetTicks`) | 20 ticks | Repressurize after the cone shuts off (one burst per 25 ticks) |
| Spray can respawn | 30s | Taken pickups refill after this interval |
| Paint puff lifetime (`PlasmaArcFxTicks`) | 4 ticks | Cosmetic fade of each per-tick cone snapshot |
| Heart auto-return | instant | A heart snaps back to its own pedestal the moment its carrier dies |
| Trench size (`TrenchSize`) | 56px | Side of the walkable center trench pit |
| Trench speed divisor (`TrenchSpeedDivisor`) | 5 | Climbing out (motion away from the pit center while inside) is 1/5 speed; entering and crossing are full speed |
| Trench fire slowdown (`TrenchFireSlowdown`) | 3 | Occupant gun cooldown multiplier; max-composed with shield/carrier |
| Trench miss chance (`TrenchMissPct`) | 70% | Incoming gun shots that fly over an occupant and carry on (same-trench shots exempt) |
| Pit count (`mapPits`) | -1 (unset) | Generated maps: exact total pits (0..64); odd counts anchor one at map center |
| Pit density (`mapPitDensity`) | 100 | Generated maps: percent multiplier on per-class dig chances; used when `mapPits` is unset |
| Puddle size (`PuddleSize`) | 64px | Nominal diameter of a paint-puddle splat (disc union; spill reaches at most 45px from its anchor) |
| Puddle count (`mapPuddles`) | 0 (none) | Generated maps: exact total puddles (0..64); odd counts anchor one at map center |
| Puddle damage chance (`puddleDamagePct`) | 20% | Chance of 1 damage per full second of continuous puddle occupancy (rolled at each completed second; shield soaks first) |
| Barrier pickups (`barrierPickups`) | 0 (none) | Folded cardboard barriers per team (0..2), staged between base and center; carrying one excludes carrying a grenade |
| Barrier strength (`BarrierHp`) | 10 hits | Gun shots a standing half-hex soaks before shredding; any cog driving into it flattens it instantly |
| Barrier radius (`BarrierRadius`) | 24px | Center-to-vertex of the placed half-hex; the flat side stands one apothem (~21px) down the placer's aim |
| Endzone shape (`mapEndzone`) | "" (drawn) | Generated 2-team maps: `column` (classic home strip), `disc` or `square` (compact zone around a base set back from the edge) |
| Endzone radius (`mapEndzoneRadius`) | 0 (drawn 110-140, size-scaled) | Compact endzones only: scoring radius / half-extent in px, 90..220. Needs `mapEndzone` |
| Base depth (`mapBaseDepth`) | 0 (drawn 520-620) | Compact endzones only: home anchor permille of the half-field, 400..800; SMALLER sets the base further from the edge. Needs `mapEndzone` |
| Time limit (`MaxTicks`) | 7200 ticks (5:00) | Scheduled end; the scoreless-draw ceiling without the barrage, ignored with it |
| Barrage max rate (`barrageMaxPerSec`) | 0 (off) | Endgame grenade rain ramps up to this many shells/s (cap 50); see "Grenade barrage". Needs a time limit |
| Barrage start rate (`barrageStartPerSec`) | 4/s | Launch rate at the latch, along the map edges |
| Barrage start (`barrageStartSec`) | 30s | Clock seconds remaining that latch the barrage (4:30 elapsed on the 5:00 clock); it only escalates once latched |
| Barrage saturation (`barrageSaturateSec`) | 30s | Seconds from latch to full saturation — whole board at max rate, landing exactly at 5:00 with the defaults |
| Map size | 1235×659 (default) | Varies by map class; the actual size and team count are stated in the `game teams <count> map <width>x<height>` init marker |

Engine tick rate is **24 ticks/sec** (inherited from Crewrift); all
second-based values above convert at that rate.

**Observation render scale:** the PLAYER observation stream (what bots parse)
is **1x map resolution** -- object coordinates and sprite pixel sizes are map
pixels directly, so an object's center IS its map point:
`map_x = object.x + sprite.width / 2` (same for y), no divisor. Only the
SPECTATOR/replay stream supersamples its zoomable board layers (2x,
`RenderScale`); the sim, the gameHash, and everything above (map size
1235x659, ranges, speeds) stay in map pixels. A 0.6.0-era build shipped the
wire at 3x -- any advice about dividing coordinates by 3 is stale. The
invisible `walkability map` sprite is 1235x659 in every stream.

**The episode parameters are stated outright at t=0.** The init snapshot
carries an invisible 1x1 marker labeled
`game teams <count> map <width>x<height>` — the number of teams sharing the
arena (2 or 4) and the exact map size in map pixels for THIS episode. Match
the prefix `game teams `; the tail splits on spaces into
`["<count>", "map", "<width>x<height>"]`. Generated maps come in several size
classes and team layouts, so a policy should read this marker (or fall back to
the walkability sprite's dimensions and counting `Room <color> Base` markers)
instead of assuming the classic 1235x659 two-team arena.

**So are the endzones.** The same init snapshot carries one invisible 1x1
marker per team labeled `endzone <color> <shape> <x0>,<y0> <x1>,<y1>`: the
team's home capture region stated outright. `<x0>,<y0>` / `<x1>,<y1>` are the
INCLUSIVE top-left and bottom-right corners of the zone's bounding box in map
pixels, and `<shape>` says how the zone fills that box:

| Shape | Where | Zone membership |
|-------|-------|-----------------|
| `column` | 2-team sides maps (classic) | the full box |
| `square` | 2-team compact-endzone maps | the full box |
| `disc` | 2-team compact-endzone maps | the circle inscribed in the box (center = box center, radius = half extent); the box corners are NOT in the zone |
| `corner` | 4-team corners maps | the L1 triangle hugging the map corner the box touches; the threshold edge is the diagonal joining the box's two corners adjacent to that map corner |
| `arm` | 4-team plus maps | the full box |

Match the prefix `endzone `; the tail splits on spaces into
`["<color>", "<shape>", "<x0>,<y0>", "<x1>,<y1>"]`, each corner splitting once
more on the comma. Validate `<shape>` against the five tokens above: the
SPECTATOR stream also emits `endzone <color> power <n>` glow overlays under
the same prefix (the player stream does not). Scoring rules are unchanged —
these markers restate the geometry the sim already plays; before they existed
a policy had to reconstruct it from the room markers and its own copy of the
zone formulas.

**So are the handicaps.** The same init snapshot carries one invisible 1x1
marker per team labeled
`handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>`: the team's
authored handicap fraction in permille (0..1000, 0 = unhandicapped) plus the
ENGINE-resolved gameplay deltas it interpolates to — hit points per life,
lives, max speed as a percent of the base max speed (100 = full), and the
percent of point-blank shots dropped (0..50). Match the prefix `handicap `;
the tail splits on spaces into
`["<color>", "<permille>", "hp", "<n>", "lives", "<n>", "spd", "<n>",
"miss", "<n>"]` — the `hp`/`lives`/`spd`/`miss` tokens are fixed. The marker
is emitted for EVERY team, permille 0 included, so an absent marker means an
engine predating it, never "no handicap". The deltas are stated so a policy
can adapt to a weakened team (its own or an enemy's) without re-deriving the
interpolation formula.

**So are the perks.** The same init snapshot carries one invisible 1x1 marker
per team labeled `perks <color> <group> [<group> …] mods hp <n> aim <n>
nade <n> spd <n> luck <n> dmg <n>`: each `<group>` is the comma-joined perk
names one policy seat on that team carries — the vocabulary is `armor` (extra
hit point), `scope` (tighter gun aim), `grenade` (longer throws), `thruster`
(faster top speed), `luck` (a fraction of landed gun shots deal extra damage,
default double) — or the literal `-` for none. One group means the whole team
shares it; two or more deal to the team's distinct policies in join order
(CTF-Doubles; policy-name-pinned config groups emit in config order, without
names). After the fixed `mods` token come the ENGINE-RESOLVED magnitudes the
sim actually plays, so a policy never assumes the defaults: `hp` armor's
extra hit points, `aim`/`nade`/`spd`/`luck` the scope/grenade/thruster/luck
fractions in permille, `dmg` a lucky shot's hit points. Match the prefix
`perks `; the tail splits on spaces into `["<color>", "<group>", …]` up to
the `mods` literal, each group splitting again on commas. The marker is
emitted for EVERY team — an unperked team reads `perks <color> -` with no
mods tail — so an absent marker means an engine predating it, never
"no perks".

**So are the trenches.** The same init snapshot carries one invisible 1x1
marker per dug pit labeled `trench <x0>,<y0> <x1>,<y1>`: the pit's INCLUSIVE
bounding-box corners in map pixels, one marker per entry in the map's
trench list. Match the prefix `trench `; the tail splits on spaces into
`["<x0>,<y0>", "<x1>,<y1>"]`, each corner splitting once more on the comma.
Trenches are dug pits you can stand in for cover: climbing OUT (moving away
from the pit's center) costs 1/5 max speed, firing from inside triples your
cooldown, and an incoming gun shot has a 70% chance to be ducked while you're
inside — none of that changes line of sight. Before this marker existed,
trenches were invisible to a policy: the `walkability map` sprite is a
BINARY mask, and a trench floor reads identically to open floor on it — a
policy could stand in one, or walk through one under fire, with no signal it
was there at all. Trenches are a 2-team generated-map feature (never on
4-team maps, and the hand-authored default `arena` never digs any); a map
that rolled zero pits emits zero markers, not an empty-box one. The marker
pool holds up to 256 trenches per match — a wide empirical margin (an
explicit `mapPits` count locks 0..64, but the default DENSITY roll has no
fixed cap and can exceed that on a large generated map) — and a map that
somehow rolls past even that loses markers for the overflow trenches rather
than dropping the whole snapshot.

**So are the paint puddles.** The same init snapshot carries one invisible
1x1 marker per puddle labeled `puddle <x0>,<y0> <x1>,<y1>`: the blob's
INCLUSIVE bounding-box corners in map pixels, one marker per entry in the
map's puddle list, with exactly the trench marker's tail contract (split the
tail on spaces, each corner on the comma). Puddles are organic disc-union
splats, so the box is slightly LOOSE (conservative) geometry — treat the
whole box as hazardous rather than trying to trace the spill's exact edge. A puddle is a pure floor hazard:
standing inside rolls a `puddleDamagePct` (default 20%) chance of 1 damage
per full second of continuous occupancy, and it never slows movement or
fire, never blocks shots or vision. Like the trench floor, a puddle reads
identically to open floor on the binary `walkability map` sprite — this
marker is the only signal it is there. Puddles are a config-gated 2-team
generated-map feature (no map has any by default); a map without puddles
emits zero markers, not an empty-box one. The marker pool holds 64 — the
`mapPuddles` cap.

**So is your own aim.** Every player frame carries an invisible 1x1 HUD
marker labeled `own aim <brads>`: your turret angle as of the rendered tick,
in brads (256 per turn, 0 = east, counter-clockwise). Match the prefix `own aim `
and parse the tail as an integer. Before this marker a policy had to dead-reckon its own aim
open-loop from its rotate inputs; the marker caps that drift at one frame
gap (integrate held rotation between frames, resync on each frame — see
docs/PROTOCOL.md).

The full wire
contract, including the CTF input-protocol extensions, is in
[`PROTOCOL.md`](PROTOCOL.md). Labels, sprite/object ids, and layers are
unchanged between streams, with one exception: while you are dead your own
body is the only
player sprite in frame, labeled `corpse <color> <side>` instead of
`player <color> <side>`, so a policy scanning for `player` labels never
mistakes a body for a live enemy.

**The capture object is a HEART in the fiction but `flag` in its LABEL.** Every
rule, banner, and end-card above calls it a heart, and that is the real name of
the thing. Its sprite labels, however, are `<color> flag`, `<color> flag planted`,
`<color> flag carried`, and `<color> flag carrier glow` — scan for **`flag`**, not
`heart`. The history: 0.7.0 renamed the object heart and renamed the labels to
match, then a later renderer restore brought the *labels* back to `flag` while
the fiction stayed heart. This document claimed `red heart` / `blue heart` until
2026-07-28; a policy written from that claim saw no objectives at all. The
generated `tests/label_manifest.txt` is the ground truth if this text and the
engine ever disagree again.

**Walking onto the planted heart grabs it.** The `<color> flag planted` sprite
object's center is the grab point, and the touch radius is **34px**
(`FlagPickupRange`, GV42) — sized to the 60px-wide gem. So a body center
anywhere on the pedestal's heart footprint takes it: navigate to the object
center and you do not need to arrive exactly on it. There is no grab button.
The DRAWN gem sits in the top half of a double-height canvas, standing on the
pedestal with its tip at the grab point — read the object's **center**, never
where the paint is.

This took three fixes, and the failure modes are worth knowing, because they are
the classic way a "visible objective" becomes unpickable:
- Before 2026-08-08 the big planted banner was bottom-anchored, putting its
  visual center ~28px above the grab point — outside the then-12px radius
  entirely. Policies that walked onto the heart they saw could *never* pick it
  up, at any precision.
- That fix sank the gem halfway into the pedestal to hold the contract; the
  stance was restored on 2026-08-08 by padding the canvas instead, which keeps
  the object centered on the grab point while the gem stands erect.
- The 12px radius itself survived both and remained a hidden precision demand:
  a fifth of the gem's width, so the visible target overstated the real one 5x.
  Agents and humans stood plainly on the heart and did not get it. GV42 keys
  the radius to the art, which is what the player aims at.

Grenades add the labels documented in the Grenades section, and the throw
button is input mask bit 128.

Spray cans add the labels documented in the Spray can section; their
pickup and carrier markers are fog-gated like other floor and overhead item
markers.

**The cone weapon is a SPRAY CAN (renamed from "plasma arc").** It is the same
weapon with the same numbers — only the art and the names changed, so this is a
pure vocabulary break for label-scanning policies. Rename in five places:

| Surface | Was | Now |
| --- | --- | --- |
| Pickup sprite label | `plasma arc` | `spray can` |
| Carrier marker label | `plasma arc carried` | `spray can carried` |
| Cone FX label | `plasma arc pulse` | `spray paint puff` |
| Own-HUD + badge weapon token | `weapon arc`, `identity … arc` | `weapon spray`, `identity … spray` |
| Held-weapon art on a carrier | `cog gun <color>` | `cog spray can <color>` |

Analysis events (`tools/extract_events.nim`) likewise carry `weapon: "spray"`
instead of `"plasma"`, and the broadcast item token is `spray`. The internal
`PlasmaArc*` identifiers and `hasPlasmaArc` field keep their names (as the
`flag`→`heart` rename kept `sim.flags`), so `gameHash` and replays are
unaffected — no GameVersion bump.

The analysis stream reports `gun_trigger` when A locks the aim and `shot` when
the paintball actually leaves after the windup. A correlated `shot_impact`
records where that paintball stopped, including misses. `grenade_throw` and
`grenade_impact` share the same correlation contract; active cone ticks emit
`spray_use`. These weapon events carry a deterministic `action_id`, native
`heading_brads` (0 east, 64 north), map-space `x`/`y`, and distance where
applicable. Damage-capable `shot_impact`, `grenade_impact`, and `spray_use`
events always carry `damages`, an array of `{slot, amount, hp, blocked}` rows;
a miss has an empty array. The stream also emits `item_pickup` with the item
name and player, and `shout` with the sanitized content and player. The older
flat `hit` and `damage` rows remain for compatibility.

**Since 0.7.5:** shouts (see the Shouts section) add the label
`<team> shout <name>: <text>`; chat packets, previously ignored, are now
applied as shouts and recorded in replays (GameVersion 3 — older replays are
rejected at load).

**Anonymous shouters:** that label's name field is now the shouter's anonymous
slot letter. It used to be the connecting player's name, which told everyone in
earshot whose policy was talking. The label's SHAPE did not change, so a policy
that reads the payload after `": "` needs no update. Replays are unaffected:
labels are rendered, never recorded, so the GameVersion is unchanged and an old
replay replays identically — under the new label.

**Player-sprite labels are stable across the HD art change:** the rotating
high-definition soldier is a pure visual upgrade — living players are still
`player <color> <side>` (yourself `self <color> <side>`, selected
`selected player <color> <side>`, a body `corpse <color> <side>`), where
`<side>` is the coarse `right`/`left` the aim falls into. The floating
`aim dot <color>` indicator has been **retired**; facing is read from the
sprite's swept gun and the vision cone, so a label-scanning policy sees the
same vocabulary it always has. **Nothing carries a player's aim angle any
more** — there is no absolute readback of where anyone (including a teammate) is
pointing, only what you infer from a body's rendered facing. The reference bot
scanned this retired label for months and got an empty answer every tick.

**The labels are enforced, not just documented.** `tests/label_manifest.txt` is
the generated list of every label the engine actually emits, and
`tests/test_label_contract.nim` fails if that set drifts or if a label the
reference policy scans for stops being emitted. When this prose and the engine
disagree, the manifest is right and this document is stale — that is exactly how
the `heart`/`flag` claim above went wrong. The label vocabulary itself lives in
`src/ctf/labels.nim`, shared by the engine and the reference policy.

**The hp bar is true hit points:** every living player carries an overhead
bar object labeled `hp <hp>/<maxHp>[ shield <s>]` — one green pip per
remaining base hit point out of that seat's OWN maximum (the `hitPoints`
config, handicap-interpolated, plus the armor perk: an armored seat reads
`hp 4/4` and draws a longer bar), with one blue pip per remaining
shield-layer hp appended while a shield holds. The denominator is per-seat
data, not a constant — parse it from the label (the reference policy scans
the `hp ` prefix) rather than restating a max of your own. The shield tail
is spelled apart from base hp on purpose: the layer depletes first and its
blue pips vanish with it, so `hp 3/3 shield 2` and `hp 3/3` are different
survivability, not different spellings of "5".

**Identity badges:** every living player carries a separate badge object
labeled `identity <color> <name>` (`alpha`..`theta` — see Teams & spawns).
Like the `hp <hp>/<maxHp>` bar, the badge is a distinct object centered on its
player's body: attach it by proximity. It is fog-gated with its player and disappears on
death.

---

## Implementation notes

This section is a build plan, not player-facing rules.

**Reused from Crewrift (the engine, ~60–70% of the code):**

- Continuous movement, fixed-point sub-pixel carry, wall-sliding collision
  against a per-pixel `walkMask`.
- Line-of-sight against a per-pixel `wallMask`. The old per-player 128×128
  camera is gone: each player now gets the **full map** with a per-viewer
  **fog-of-war** (recursive shadowcasting on an 8px visibility cell grid,
  intersected with the vision cone and bubble) that culls fogged entities from
  the observation and dims the unseen area with a fog overlay layer.
- The **Sprite v1** protocol (button-mask input + sprite/object observations),
  websocket server (`/player`, `/global`, `/replay`, `/reward`), replay
  recording/playback, JSON config loading, and reward streaming.

**Rewritten (the game layer, replacing social deduction):**

- `sim.nim`: replace `Crewmate`/`Imposter` roles with `Red`/`Blue` teams; replace
  `tryKill` (proximity grab) with **directional hitscan + LOS along the aim**; add
  **lives/respawn**, **heart pickup/carry/return**, **team win-check**, and a
  **Lobby → Playing → GameOver** phase machine (drop RoleReveal/Voting/VoteResult).
- Player struct: keep `x,y,velX,velY,carryX,carryY,alive,color,reward`; drop
  task/vent/vote fields; add `team`, `lives`, `respawnTimer`, `fireCooldown`,
  `aimBrads`, `carryingFlag`.
- `global.nim` observation building: team-colored player sprites, the heart
  sprites, a **carrier indicator**, the per-viewer **fog overlay** and
  fog-culled entity stream (there are deliberately **no heart arrows** — fog of
  war replaced all global tracking intel), a distinct **self marker**, and
  per-player **lives / fire-cooldown UI** on HUD layers.
- New **symmetric arena**: a new `.resources` map (CSS-like rects) plus an Aseprite
  image with walk/wall layers. Red/Blue spawn strips on the left/right edges,
  heart pedestal at center, obstacles mirrored across the vertical axis, home-edge
  capture zones at the leftmost/rightmost columns.
- New team-based `config.json` and `coworld_manifest_paintbot.json` (slots carry `team`
  instead of `role`; results schema reports team/kills/deaths/captures).
- A **baseline bot** (Crewrift's `notsus` equivalent) speaking Sprite v1.
- A **CTF grader** scoring episodes from wins.

**Resolved:** CTF needed team-based seating and win/loss ranking rather than
Crewrift's social-deduction scheme. This is no longer a per-game concern — both
the Ctf and Paintbot leagues run on the platform ladder service
(`commissioner_key=platform`), which owns seating and ranking. This repo ships
the game and baseline player only; it declares no commissioner runnable.
