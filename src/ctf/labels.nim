## Sprite-label vocabulary: the machine-readable CONTRACT between the engine
## (the producer, `global.nim`) and AI policies (the consumers, e.g.
## `players/baseline/`). A policy has no API into the sim — it reads the wire,
## finds sprite objects by their label string, and steers off their positions.
## So a label is not a debug tag: it is the observation schema, and renaming one
## is a breaking change to every policy in the league.
##
## The failure mode this module exists to prevent is SILENT. Labels are computed
## at render time and never serialized (flatty writes `SimServer` positionally,
## so replays carry no label bytes), nothing type-checks a label string, and
## `spriteObjectsWithLabel` returns an empty seq for a name that no longer
## exists. Rename `"med kit"` to `"medkit"` and every bot simply stops routing
## to kits — no crash, no failing assertion, no log line. Hoisting the strings
## to consts makes at least the producer/consumer halves share one definition,
## and `tests/test_label_contract.nim` guards the rest.
##
## **Contract labels live here; spectator CHROME deliberately does not.** The
## renderer emits far more labels than this file names — map bands, the replay
## scrubber and transport, the roster and score pips, interstitial text, hit
## flashes, muzzle blooms, tracer stages, splatters, damage pops, endzone glow,
## the cog rig's limbs. No policy reads any of them; they exist for the
## inspector and for sprite dedup. Hoisting them here would imply a stability
## promise the engine does not owe — the broadcast view is free to re-cut its
## chrome any week. They are still covered by the golden manifest (a chrome
## rename shows up as a diff you can wave through), just not as API.
##
## **Renaming anything in this file is a four-surface change**, all in the same
## commit: this module, `tests/label_manifest.txt` (the golden vocabulary),
## `docs/RULES.md` (the published observation spec policy authors read), and
## `players/baseline/` (the reference consumer). The contract test fails until
## the manifest agrees; the other two surfaces are on you.
##
## **This module must keep ZERO imports** — not even `std/strutils`. The
## baseline bot imports it via `players/baseline/config.nims`, and the bot's
## Docker image ships no `data/` directory. Any import here risks dragging the
## renderer's cone (pixie / mummy / aseprite, all of which load assets at
## import or first use) into a binary that cannot satisfy it. If an addition
## seems to need an import, change the API instead.

const
  # ---------------------------------------------------------------------------
  # Flat labels: exact strings, matched with `==` by consumers.
  # ---------------------------------------------------------------------------

  LabelMedKit* = "med kit"
    ## Center-line health pickup, fog-gated by map position.
  LabelShield* = "shield"
    ## Endzone armor pickup on the floor, fog-gated by map position.
  LabelShieldCarried* = "shield carried"
    ## Marker floating over a shield carrier you can see.
  LabelSprayCan* = "spray can"
    ## Side-column weapon pickup (the 0.7.x rename of the plasma arc).
  LabelSprayCanCarried* = "spray can carried"
    ## Marker floating over a spray-can carrier you can see.
  LabelSprayPaintPuff* = "spray paint puff"
    ## One mist puff of a firing spray cone; a burst emits a run of them.
  LabelGrenade* = "grenade"
    ## Corner paint-bomb pickup on the floor, fog-gated by map position.
  LabelBarrier* = "barrier"
    ## Folded cardboard barrier pickup on the floor (config-gated:
    ## barrierPickups > 0), fog-gated by map position. Carrying one blocks
    ## picking up a grenade and vice versa — both use button C.
  LabelBarrierCarried* = "barrier carried"
    ## Marker floating over a barrier carrier you can see. Press C to unfold
    ## the cardboard where you stand, flat side across your aim.
  LabelGrenadeAir* = "grenade air"
    ## A grenade in flight. It travels OVER walls, so an airborne orb is a
    ## threat even with no line of sight to the thrower.
  LabelGrenadeCarried* = "grenade carried"
    ## Marker floating over a grenade carrier you can see.
  LabelGrenadeSound* = "grenade sound"
    ## Jittered ring for a landing you could NOT see: audio-only intel.
  LabelThrowTarget* = "throw target"
    ## Projected landing ring of a charging lob. PLAYER-VIEW ONLY — the
    ## broadcast suppresses it, so a board-stream sweep never sees this label.
  LabelBlastStagePrefix* = "blast stage "
    ## Grenade landing splat, suffixed with its animation stage.
  LabelShotImpact* = "shot impact"
    ## Jittered ring near where a shot landed. The only trace a shot leaves in
    ## a player observation — firing itself is silent.
  LabelFireIcon* = "fire icon"
    ## Bottom-left HUD trigger-ready light. Its PRESENCE is the ready signal:
    ## on cooldown the HUD object switches to LabelFireIconCooldown, so a
    ## policy gates firing on `spriteObjectsWithLabel(LabelFireIcon).len > 0`.
  LabelFireIconCooldown* = "fire icon cooldown"
    ## The dimmed twin of LabelFireIcon, shown while the gun is recovering.
  LabelWalkabilityMap* = "walkability map"
    ## The invisible full-arena navigation mask: an RGBA sprite whose alpha is
    ## the walkable bit per map pixel. Always unscaled 1x, whatever the render
    ## scale — a policy decodes its pixels, it never reads its position.

  # ---------------------------------------------------------------------------
  # Prefixes: consumers match these with `startsWith`, because the tail
  # interpolates (a color, a side, a name, a count, free text).
  # ---------------------------------------------------------------------------

  LabelPrefixPlayer* = "player "
    ## A LIVING player: `player <color> <side>`. The board stream also puts
    ## this prefix on the cog rig's HEAD segment as bare `player <color>` (the
    ## aim-facing piece a scanner reads as the actor), so match by prefix and
    ## never assume a side token is present.
  LabelPrefixSelf* = "self "
    ## Your own avatar, `self <color> <side>`, drawn only while alive — so its
    ## absence is how a policy learns it is dead.
  LabelPrefixCorpse* = "corpse "
    ## A body, `corpse <color> <side>`. Deliberately NOT the player prefix so a
    ## scanner never counts a corpse as a live threat.
  LabelPrefixSelectedPlayer* = "selected player "
    ## Spectator-highlighted player, `selected player <color> <side>`. Emitted
    ## only on the board stream.
  LabelPrefixHp* = "hp "
  LabelHpShieldSep* = " shield "
    ## Separates the hp bar's `<hp>/<maxHp>` head from the shield tail —
    ## shared so the parser (players/baseline) and labelHp cannot drift.
    ## Overhead health bar, `hp <lit>/<total>`. A distinct object centered on
    ## its player and fog-gated with them: attach it by proximity.
  LabelPrefixLives* = "lives "
    ## Own top-right HUD text, `lives <hp>hp x<lives>`. Reads PAST the base hp
    ## cap — a shield carrier shows 6hp — which is how a policy detects its own
    ## shield without seeing the carry marker.
  LabelPrefixWeapon* = "weapon "
    ## Own weapon readout, `weapon <token>`. Authoritative for your own hands;
    ## inferring your weapon from floating markers gets it wrong under fog.
  LabelPrefixIdentity* = "identity "
    ## Per-player badge, `identity <color> <name>[ shield][ nade] <weapon>`.
    ## See `labelIdentity` for the ordering invariant. Scan by PREFIX only: the
    ## tail changes every time the wearer picks something up.
  LabelPrefixCogGun* = "cog gun "
    ## The held paintball marker, `cog gun <color>` (board stream only).
  LabelPrefixCogSprayCan* = "cog spray can "
    ## The held spray can, `cog spray can <color>`, which REPLACES the gun
    ## sprite while one is carried — so the silhouette shows the live weapon.
  LabelPrefixGameParams* = "game teams "
    ## The episode-parameter marker, `game teams <count> map <width>x<height>`:
    ## an invisible 1x1 object in the init snapshot stating the match setup
    ## outright — how many teams share the arena (2 or 4) and the exact map
    ## size in map pixels. Before it existed a policy had to INFER both: the
    ## team count from counting room markers or pedestals, the map size from
    ## the walkability sprite's dimensions. Those channels still work; this
    ## label is the stated-value contract for them.
  LabelPrefixOwnAim* = "own aim "
    ## The own-aim readback, `own aim <brads>`: an invisible 1x1 HUD marker on
    ## the PLAYER stream whose label states your own turret angle in brads
    ## (256 per turn, 0 = east, counter-clockwise) as of the rendered tick.
    ## Before this marker existed a policy had to dead-reckon its own aim
    ## open-loop from its rotate inputs — the observation carried no readback
    ## at all, and the accumulated drift measurably cost accuracy (see
    ## docs/PROTOCOL.md, "Your own aim"). NOT named `self aim`: consumers
    ## prefix-match `self ` for the avatar, and a marker sharing that prefix
    ## would false-positive every such scan.
  LabelPrefixEndzone* = "endzone "
    ## The per-team endzone marker,
    ## `endzone <color> <shape> <x0>,<y0> <x1>,<y1>`: an invisible 1x1 object
    ## in the init snapshot stating one team's home capture region outright —
    ## its shape archetype (see the LabelEndzoneShape tokens) and the
    ## inclusive corners of its bounding box in map pixels. One marker per
    ## team in the game. CAUTION for consumers: the broadcast/spectator
    ## stream also carries the endzone glow overlays,
    ## `endzone <color> power <n>` — match the third token against the shape
    ## vocabulary (or the `power` literal) before parsing corners.
  LabelPrefixHandicap* = "handicap "
    ## The per-team handicap marker,
    ## `handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>`: an
    ## invisible 1x1 object in the init snapshot stating one team's authored
    ## handicap fraction AND the resolved gameplay deltas it interpolates to,
    ## so a policy adapts to a weakened (own or enemy) team without knowing
    ## the interpolation formula. One marker per team in the game, emitted
    ## even at permille 0 — absence means an old engine, not "no handicap".
    ## See `labelHandicap` for the exact tail arity.
  LabelPrefixPerks* = "perks "
    ## The per-team perk marker,
    ## `perks <color> <group> [<group> …] mods hp <n> aim <n> nade <n>
    ## spd <n> luck <n> dmg <n>`: an invisible 1x1 object in the init
    ## snapshot stating one team's perk groups outright — each group is the
    ## comma-joined perk names one policy seat carries (`armor,scope`), or
    ## `-` for none — plus, after the fixed `mods` token, the ENGINE-RESOLVED
    ## magnitudes (perkMods), so a policy adapts to tuned mods without
    ## assuming the defaults. One group means the whole team shares it; two
    ## or more deal to the team's distinct policies in join order
    ## (CTF-Doubles). One marker per team in the game, emitted even when
    ## unperked (`perks <color> -`, no mods tail) — absence means an old
    ## engine, not "no perks". See `labelPerks` for the exact format.
  LabelPrefixBarrage* = "grenade barrage depth "
    ## The stated grenade-barrage marker,
    ## `grenade barrage depth <n> rate <n> start <n> sat <n>`: an invisible
    ## 1x1 marker on both streams, present whenever the barrage endgame is
    ## configured (barrageMaxPerSec > 0), stating how deep inside every map
    ## edge the shells currently land (`depth` map px, 0 until the barrage
    ## latches; full board once the escalation completes), the CURRENT
    ## launch rate in grenades/second (`rate`), the clock threshold in
    ## seconds that latches it (`start`), and the seconds from latch to
    ## full saturation (`sat`). Absence means the mode is off (or an old
    ## engine). The shells themselves carry the ordinary grenade labels
    ## (`grenade air`, `blast stage <n>`), so an incoming barrage reads
    ## like any other lob — this marker is the escalation schedule.
  LabelPrefixTrench* = "trench "
    ## One trench's bounding-box marker, `trench <x0>,<y0> <x1>,<y1>`: an
    ## invisible 1x1 object in the init snapshot stating one dug pit's
    ## bounding box outright, in inclusive map-pixel corners — one marker per
    ## entry in `gameMap.trenches`. Before this marker existed, trenches were
    ## invisible to every policy: `LabelWalkabilityMap` is a BINARY mask, and
    ## a trench floor reads identically to open floor on it. Trenches are
    ## stored as `ArenaShape` polygons (a 56x56 walkable pit, its edge cut
    ## with rough noise — see TrenchSize / trenchRoughEdge); the marker states
    ## the shape's tight bounding box, so a non-rect trench reads as slightly
    ## LOOSE (conservative) geometry rather than exact membership. Absent
    ## entirely on 4-team maps (trenches are a 2-team-map feature) and on any
    ## map that rolled zero pits — zero markers, not an empty-box marker. See
    ## `labelTrench` for the exact tail arity.
  LabelPrefixBarrierUp* = "barrier up "
    ## One STANDING cardboard barrier,
    ## `barrier up <x>,<y> f<brads> hp <n>`: the visible half-hex sprite's
    ## own label (not an invisible marker), fog-gated by the barrier's center.
    ## `<x>,<y>` is the placement center in map pixels, `f<brads>` the
    ## placer's aim at placement (0..255, the flat middle side faces that
    ## way, BarrierRadius=24px out), and `hp <n>` the paintball hits it can
    ## still take (starts at 10). The band blocks every PAINT path — gun and
    ## spray — but never sight, movement, or grenades; any cog that drives
    ## into the band flattens it instantly. See `labelBarrierUp` for the
    ## exact tail arity.
  LabelPrefixPuddle* = "puddle "
    ## One paint puddle's bounding-box marker, `puddle <x0>,<y0> <x1>,<y1>`:
    ## an invisible 1x1 object in the init snapshot stating one hazard blob's
    ## bounding box outright, in inclusive map-pixel corners — one marker per
    ## entry in `gameMap.puddles`, same contract as the trench marker above.
    ## Puddles are ORGANIC disc-union splats (see puddleSplatAt), so the box
    ## is slightly loose (conservative) geometry, exactly like a non-rect
    ## trench's marker.
    ## Standing inside rolls a puddleDamagePct (default 20%) chance of 1
    ## damage per full second of continuous occupancy; the puddle never slows
    ## movement or fire and never blocks shots or vision. Absent entirely on
    ## 4-team maps and on any map without puddles (the default) — zero
    ## markers, not an empty-box marker. See `labelPuddle` for the tail arity.

  # ---------------------------------------------------------------------------
  # Tokens that fill the interpolated slots above.
  # ---------------------------------------------------------------------------

  LabelSideRight* = "right"
    ## The coarse facing an aim angle falls into; see `labelPlayer`.
  LabelSideLeft* = "left"
  LabelWeaponGun* = "gun"
    ## Default paintball marker; see `labelWeapon` / `labelIdentity`.
  LabelWeaponSpray* = "spray"
    ## Spray can. (0.7.x renamed the plasma arc, whose token was "arc"; the
    ## internal `hasPlasmaArc` field kept its name, the wire token did not.)
  LabelTokenShield* = "shield"
    ## Optional identity-badge suffix: the wearer carries a shield.
  LabelTokenNade* = "nade"
    ## Optional identity-badge suffix: the wearer carries a grenade.
  LabelEndzoneShapeColumn* = "column"
    ## Classic sides zone: the full box between the stated corners.
  LabelEndzoneShapeSquare* = "square"
    ## Compact anchor-centered box: the full box between the stated corners.
  LabelEndzoneShapeDisc* = "disc"
    ## Compact round zone: the circle INSCRIBED in the stated box (center =
    ## box center, radius = half the box extent); the box corners themselves
    ## are outside the zone.
  LabelEndzoneShapeCorner* = "corner"
    ## 4-team corners zone: the L1 triangle hugging the map corner the box
    ## touches — its threshold edge is the diagonal joining the box's two
    ## corners adjacent to that map corner.
  LabelEndzoneShapeArm* = "arm"
    ## 4-team plus-arm mouth: the full box between the stated corners.

const LabelEndzoneShapes* = [
  LabelEndzoneShapeColumn,
  LabelEndzoneShapeSquare,
  LabelEndzoneShapeDisc,
  LabelEndzoneShapeCorner,
  LabelEndzoneShapeArm,
]
  ## The closed shape vocabulary of the `endzone <color> <shape> ...` marker.
  ## Consumers validate the third token against this set; the label-contract
  ## test normalizes exactly these tokens to `<shape>`.

proc labelPlayer*(color, side: string): string =
  ## A living player's sprite label, `player <color> <side>`.
  LabelPrefixPlayer & color & " " & side

proc labelCorpse*(color, side: string): string =
  ## A body's sprite label, `corpse <color> <side>`.
  LabelPrefixCorpse & color & " " & side

proc labelSelf*(color, side: string): string =
  ## Your own avatar's sprite label, `self <color> <side>`.
  LabelPrefixSelf & color & " " & side

proc labelSelectedPlayer*(color, side: string): string =
  ## The spectator-highlighted variant, `selected player <color> <side>`.
  LabelPrefixSelectedPlayer & color & " " & side

proc labelFlag*(color: string): string =
  ## The CARRIED objective banner, `<color> flag`, centered exactly on its
  ## carrier and fogged with them. In-sim prose calls it a heart; the wire
  ## label stayed `flag` so label-scanning policies did not break.
  color & " flag"

proc labelFlagPlanted*(color: string): string =
  ## The PEDESTAL objective banner, `<color> flag planted`. Your own pedestal
  ## is never fogged, so an absent own-planted flag means it has been stolen.
  color & " flag planted"

proc labelHp*(hp, maxHp: int, shieldHp = 0): string =
  ## One seat's overhead health bar, `hp <hp>/<maxHp>[ shield <s>]` — TRUE
  ## hit points, not the old fixed thirds. The numerator is the seat's
  ## remaining base hp and the denominator its OWN maximum (the hitPoints
  ## config plus the armor perk where carried), so an armored seat at full
  ## health reads `hp 4/4` while a bare one reads `hp 3/3`. While a shield
  ## layer holds, ` shield <s>` carries its remaining absorb hp — the shield
  ## is a separate layer (blue pips on the bar), never folded into the base
  ## count.
  ##
  ## The denominator is DATA now, not a contract constant: a consumer reads
  ## a seat's maximum out of the label itself instead of restating a number
  ## the engine also owns (the old `LabelHpBarSegments`/`MaxHp` twin-constant
  ## drift this vocabulary once guarded against by fixing the total at 3).
  ## Scan by LabelPrefixHp and parse, or exact-match a full spelling.
  result = LabelPrefixHp & $hp & "/" & $maxHp
  if shieldHp > 0:
    result.add(LabelHpShieldSep & $shieldHp)

proc labelGameParams*(teams, mapWidth, mapHeight: int): string =
  ## The episode-parameter marker label,
  ## `game teams <count> map <width>x<height>`. A consumer matches
  ## LabelPrefixGameParams and splits the tail on spaces into exactly
  ## `["<count>", "map", "<width>x<height>"]` — the `map` token is fixed, and
  ## the size splits once more on the `x`.
  LabelPrefixGameParams & $teams & " map " & $mapWidth & "x" & $mapHeight

proc labelEndzone*(color, shape: string; x0, y0, x1, y1: int): string =
  ## One team's endzone marker label,
  ## `endzone <color> <shape> <x0>,<y0> <x1>,<y1>`. A consumer matches
  ## LabelPrefixEndzone and splits the tail on spaces into exactly
  ## `["<color>", "<shape>", "<x0>,<y0>", "<x1>,<y1>"]`; each corner splits
  ## once more on the comma. The corners are the INCLUSIVE bounding box of
  ## the zone in map pixels; `shape` (a LabelEndzoneShapes token) says how
  ## the zone fills that box — see each token's doc for the exact membership.
  doAssert shape in LabelEndzoneShapes, "unknown endzone shape token: " & shape
  LabelPrefixEndzone & color & " " & shape & " " &
    $x0 & "," & $y0 & " " & $x1 & "," & $y1

proc labelHandicap*(color: string; permille, hp, lives, spdPct,
    missPct: int): string =
  ## One team's handicap marker label,
  ## `handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>`. A
  ## consumer matches LabelPrefixHandicap and splits the tail on spaces into
  ## exactly `["<color>", "<permille>", "hp", "<n>", "lives", "<n>", "spd",
  ## "<n>", "miss", "<n>"]` — the `hp`/`lives`/`spd`/`miss` tokens are fixed.
  ## `<permille>` is the authored handicap fraction in permille (0..1000,
  ## 0 = unhandicapped); the four deltas are the ENGINE-resolved values the
  ## sim actually plays (see hitPointsFor/livesFor/maxSpeedFor/
  ## missPermilleFor): hit points per life, lives, max speed as a percent of
  ## the base max speed (100 = full), and the percent of point-blank shots
  ## dropped (0..50). Stated so a policy never re-derives the interpolation.
  LabelPrefixHandicap & color & " " & $permille &
    " hp " & $hp & " lives " & $lives & " spd " & $spdPct & " miss " & $missPct

proc labelBarrierUp*(x, y, facingBrads, hp: int): string =
  ## One standing barrier's label, `barrier up <x>,<y> f<brads> hp <n>`. A
  ## consumer matches LabelPrefixBarrierUp and splits the tail on spaces into
  ## exactly `["<x>,<y>", "f<brads>", "hp", "<n>"]`; the corner splits once
  ## more on the comma. The hp tail doubles as the render-cache buster: a hit
  ## changes the label, which re-ships the (newly dented) sprite definition.
  LabelPrefixBarrierUp & $x & "," & $y & " f" & $facingBrads & " hp " & $hp

proc labelPerks*(color: string; groups: seq[string];
    armorHp, scopeAim, grenadeRange, thrusterSpeed, luckChance,
    luckDamage: int): string =
  ## One team's perk marker label,
  ## `perks <color> <group> [<group> …] mods hp <n> aim <n> nade <n> spd <n>
  ## luck <n> dmg <n>`. A consumer matches LabelPrefixPerks and splits the
  ## tail on spaces: the first token is the team color, each further token
  ## one perk GROUP — the comma-joined perk names (PerkNames vocabulary,
  ## e.g. `armor,scope`) that one policy seat on the team carries, or the
  ## literal `-` for none — until the fixed `mods` token. A single group is
  ## team-wide; several deal to the team's distinct policies in join order
  ## (named config groups emit in config order, without names — a consumer
  ## maps groups to policies via the roster, exactly as the sim does). After
  ## `mods` come the ENGINE-RESOLVED magnitudes the sim actually plays, so a
  ## policy never assumes the defaults: `hp` armor's extra hit points,
  ## `aim` the aim-sigma reduction in permille, `nade` the extra throw range
  ## in permille, `spd` the extra max speed in permille, `luck` the lucky-
  ## shot chance in permille, `dmg` a lucky shot's hit points. An unperked
  ## team reads `perks <color> -` with NO mods tail (nothing to resolve).
  ## Plain-int magnitudes, not the PerkMods struct: this module keeps ZERO
  ## imports (see the module header), exactly like labelHandicap's deltas.
  result = LabelPrefixPerks & color
  if groups.len == 0:
    result.add " -"
  else:
    for group in groups:
      result.add " "
      result.add (if group.len > 0: group else: "-")
    result.add " mods hp " & $armorHp & " aim " & $scopeAim &
      " nade " & $grenadeRange & " spd " & $thrusterSpeed &
      " luck " & $luckChance & " dmg " & $luckDamage

proc labelTrench*(x0, y0, x1, y1: int): string =
  ## One trench's bounding-box marker label, `trench <x0>,<y0> <x1>,<y1>`. A
  ## consumer matches LabelPrefixTrench and splits the tail on spaces into
  ## exactly `["<x0>,<y0>", "<x1>,<y1>"]`; each corner splits once more on the
  ## comma. The corners are the INCLUSIVE bounding box of the trench in map
  ## pixels.
  LabelPrefixTrench & $x0 & "," & $y0 & " " & $x1 & "," & $y1

proc labelPuddle*(x0, y0, x1, y1: int): string =
  ## One paint puddle's bounding-box marker label,
  ## `puddle <x0>,<y0> <x1>,<y1>`. Same tail contract as `labelTrench`: the
  ## tail splits on spaces into exactly `["<x0>,<y0>", "<x1>,<y1>"]`, each
  ## corner splitting once more on the comma; the corners are the INCLUSIVE
  ## bounding box of the puddle in map pixels.
  LabelPrefixPuddle & $x0 & "," & $y0 & " " & $x1 & "," & $y1

proc labelBarrage*(depth, perSec, startSec, saturateSec: int): string =
  ## The grenade-barrage marker label,
  ## `grenade barrage depth <n> rate <n> start <n> sat <n>`. A consumer
  ## matches LabelPrefixBarrage and splits the tail on spaces into exactly
  ## `["<depth>", "rate", "<n>", "start", "<n>", "sat", "<n>"]` — the
  ## `rate`/`start`/`sat` tokens are fixed. Shells land only within `depth`
  ## map px of some map edge on the rendered tick, at `rate`
  ## grenades/second; the ramp completes `sat` seconds after the latch.
  LabelPrefixBarrage & $depth &
    " rate " & $perSec & " start " & $startSec & " sat " & $saturateSec

proc labelOwnAim*(brads: int): string =
  ## The own-aim marker label, `own aim <brads>`. A consumer matches
  ## LabelPrefixOwnAim and parses the tail as the integer aim angle.
  LabelPrefixOwnAim & $brads

proc labelWeapon*(token: string): string =
  ## The own-weapon HUD label, `weapon <token>` — LabelWeaponGun or
  ## LabelWeaponSpray.
  LabelPrefixWeapon & token

proc labelCogWeapon*(color: string; spray: bool): string =
  ## The held-weapon sprite label on the board rig: `cog spray can <color>`
  ## when a spray can is carried, `cog gun <color>` otherwise. A cog holds
  ## exactly one thing, so these two are mutually exclusive per player.
  (if spray: LabelPrefixCogSprayCan else: LabelPrefixCogGun) & color

proc labelShoutPrefix*(color: string): string =
  ## The prefix a listener matches to attribute a shout to a team:
  ## `<color> shout `. Own-team and enemy shouts differ only by this prefix.
  color & " shout "

proc labelShout*(color, name, text: string): string =
  ## A speech bubble, `<color> shout <name>: <text>`, where `<name>` is the
  ## shouter's anonymous Greek slot letter (alpha..theta) — the same identity
  ## `labelIdentity` uses, NOT the shouter's connection address. Every player in
  ## earshot reads this label, so the address would broadcast the connecting
  ## policy's own name to its rivals; see `shoutIdentityName`.
  ##
  ## The tail is arbitrary player-authored text, so consumers split on `": "`
  ## and treat everything after it as payload — never exact-match a whole shout
  ## label. A slot letter can never contain `": "`, so the FIRST separator is
  ## always the real one; shipped consumers (`players/baseline/`, and the league
  ## champions built from it) split on the last, which differs only for a payload
  ## that contains a `": "` of its own.
  labelShoutPrefix(color) & name & ": " & text

proc labelIdentity*(
  color, name: string;
  shield, nade: bool;
  weapon: string
): string =
  ## A player's identity badge: `identity <color> <name>[ shield][ nade]
  ## <weapon>`, where `<name>` is the Greek slot letter (alpha..theta).
  ##
  ## ORDERING INVARIANT, stated here so it lives in exactly one place: the
  ## optional loadout flags come first, in a FIXED order (shield before nade),
  ## and the WEAPON TOKEN IS ALWAYS LAST AND ALWAYS PRESENT. Always-present
  ## matters more than the order: if the weapon token were omitted for the
  ## default gun, an observer would have to infer "gun" from ABSENCE — and
  ## absence is also what a truncated, stale, or fog-dropped badge looks like.
  ## An explicit terminal token makes the badge self-describing, which is why
  ## a consumer may read the weapon as the substring after the final space.
  result = LabelPrefixIdentity & color & " " & name
  if shield:
    result.add " " & LabelTokenShield
  if nade:
    result.add " " & LabelTokenNade
  result.add " " & weapon

const PolicyScannedLabels* = [
  ## Every label the reference policy (`players/baseline/baseline.nim`) passes
  ## to `spriteObjectsWithLabel`, i.e. matches EXACTLY. The contract test
  ## asserts each one is actually emitted somewhere in a full-feature frame,
  ## because an exact-match scan for a label the engine no longer emits fails
  ## in the quietest possible way: an empty seq, forever, with nothing else
  ## breaking.
  ##
  ## KNOWN GAP — this list is hand-maintained. Nothing forces a NEW
  ## `spriteObjectsWithLabel` call in the bot to be registered here, so the
  ## guard only covers labels somebody remembered to add. It catches the
  ## engine-side half of a rename (producer drops a label the policy still
  ## wants), not the consumer-side half (policy invents a label the producer
  ## never had). Prefix-scanned families (`hp `, `lives `, `identity `,
  ## `<color> shout `) cannot appear here at all — their tails interpolate —
  ## and are covered instead by the vocabulary diff against the manifest.
  LabelFireIcon,
  LabelWalkabilityMap,
  LabelMedKit,
  LabelShield,
  LabelShieldCarried,
  LabelSprayCan,
  LabelSprayCanCarried,
  LabelGrenade,
  LabelGrenadeAir,
  LabelGrenadeCarried,
  LabelBarrier,
  LabelBarrierCarried,
  LabelThrowTarget,
  labelFlag("red"),
  labelFlag("blue"),
  labelFlagPlanted("red"),
  labelFlagPlanted("blue"),
  labelPlayer("red", LabelSideRight),
  labelPlayer("red", LabelSideLeft),
  labelPlayer("blue", LabelSideRight),
  labelPlayer("blue", LabelSideLeft),
  labelSelf("red", LabelSideRight),
  labelSelf("red", LabelSideLeft),
  labelSelf("blue", LabelSideRight),
  labelSelf("blue", LabelSideLeft),
  labelCorpse("red", LabelSideRight),
  labelCorpse("red", LabelSideLeft),
  labelCorpse("blue", LabelSideRight),
  labelCorpse("blue", LabelSideLeft),
  labelWeapon(LabelWeaponGun),
  labelWeapon(LabelWeaponSpray)
]
