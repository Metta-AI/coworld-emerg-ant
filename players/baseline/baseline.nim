## Baseline capture-the-flag bot for Coworld CTF (8v8, classic two-flag,
## dense-cover arena, FOG-OF-WAR full-map vision).
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The observation is
## the FULL map in map coordinates, but entities are fogged: an enemy (and an
## enemy carrying our flag) is only streamed while it sits inside OUR vision —
## a forward cone (half-angle ~60 degrees around our AIM ANGLE, unlimited
## range, walls block) plus a small omnidirectional bubble (~90px). Always
## visible: the static map, BOTH flag pedestals (teammates are fogged too),
## our own flag's state (an empty own pedestal means it is stolen), and
## ourselves via the distinct "self <color> right|left" marker. AIM IS
## DECOUPLED FROM MOVEMENT: a continuous per-player aim angle (0..255 brads,
## 0 = east, counter-clockwise on screen) turns 5 brads per tick while B
## (CCW) or Select (CW) is held; the d-pad never touches it. The aim drives the
## gun, the vision cone, and the sprite flip, so pointing it is THE core
## tactical decision. The bot keeps a persistent world model on top of that:
##
## - **Nav grid**: the full walkability mask arrives once at init; we erode it
##   by the player footprint into an 8px cell grid and run a cost field
##   (Dijkstra) to any goal, then follow the path with waypoint lookahead.
## - **Cover model**: walkable cells adjacent to an obstacle are "cover
##   cells". Cells a remembered enemy could shoot into (range + coarse LOS)
##   get a soft path cost, so movement naturally advances cover-to-cover and
##   keeps obstacles between us and known threats.
## - **Flag model** (two flags): pedestals are STATIC known positions and
##   pedestal flags are never fogged. Only OUR team can carry the enemy flag,
##   but a carried heart is only as visible as its carrier and mates fog like
##   enemies, so the "<enemy color> heart" sprite describes our attack fully
##   only on its pedestal or on ME; a MATE's carry is visible just while that
##   mate is, and an absent enemy heart means a fogged mate has it. Only the
##   enemy can carry OUR heart: the "<my color> heart" sprite on its pedestal
##   means safe, visible off-pedestal is a live thief fix, and ABSENT means
##   stolen by a fogged carrier somewhere between our pedestal and its home
##   edge.
## - **Memory**: visible players are matched to tracks (position, velocity,
##   last-seen tick) that persist through fog, and the last thief fix guides
##   the hunt after the carrier fogs out.
## - **Roles** (deterministic from the per-team seat, 8 seats): a mid QUAD
##   races lanes to the ENEMY pedestal, two flankers route wide and hit the
##   pocket from behind, one overwatch sniper holds a shielded cover post
##   whose peek cell owns the longest firing line over mid — under fog a lane
##   watcher SEES map-wide down its open lane, so overwatch is also the radar
##   — and one home defender guards the choke before our pedestal. The attack
##   wave is deliberately six strong: with no global flag tracking, a carrier
##   that slips the contest is hard to reacquire, so committed offense turns
##   steals into captures. While our flag is stolen the back line hunts the
##   thief along its predicted route toward ITS home edge; attackers press on
##   — captures are instant wins both ways, so the race stays on.
## - **Turret controller**: the bot reads its own aim from the engine's
##   `own aim <brads>` HUD marker each frame, dead-reckoning only BETWEEN
##   frames (each held rotate button turns 5 brads/tick server-side) and as
##   the sole source on pre-marker engines.
##   Each tick it outputs the rotate button that traverses toward the desired
##   aim by the shortest arc, and fires only when the bullet corridor
##   (~14px half-width) covers the target at its range.
## - **Scanning**: units holding a position (overwatch posts, the defender's
##   choke, cooldown ducks) sweep the aim back and forth across the watch arc
##   with genuine rotate-button sweeps, raking the vision cone over it while
##   standing perfectly still. On the move, the aim leads the movement
##   direction when no target demands it, so attackers watch down-lane.
## - **Peek-and-shoot**: the default combat mode. With the gun up and a
##   remembered enemy blocked by a wall, PRE-LAY the aim on the firing line
##   while stepping sideways to the nearest cell that opens it — the shot is
##   ready the moment the ray clears; during the 12-tick cooldown, duck
##   behind the nearest cover that breaks the threat's line and hold there.
## - **Fire discipline**: the bullet is a corridor hitscan along the aim, so
##   the fire gate is geometric: shoot when the aim error's perpendicular
##   miss at the target's range is inside the corridor. Skip targets with a
##   remembered teammate near the fire axis (friendly fire is on; the server
##   kills the NEAREST player in the corridor).
##
## Coordinate model: the map object sits at (0, 0), so object positions ARE
## map coordinates; we find ourselves via the self marker. Only a fresh A
## press fires, and the aim angle locks at the pull (the bullet leaves after
## a short windup), so we stop rotating on the tick we pull.

import
  std/[algorithm, heapqueue, math, net, os, random, strutils],
  bitworld/profile, bitworld/spriteprotocol,
  ctf/labels,
  whisky,
  baseline/protocols,
  baseline/artlog

when defined(taunt):
  import baseline/taunts

const
  WebSocketPath = "/player"
                              # Object coordinates and sprite sizes arrive
                              # multiplied by this; sprites stay centered on
                              # the same map points, so dividing the object
                              # center recovers exact legacy map coordinates.
  PlayerHalf = 6              # solid footprint half-extent, matches the sim
  NavCell = 8                 # nav grid cell size in px
  RepathTicks = 10            # refresh the cost field at least this often
  LookaheadCells = 6          # how far ahead on the path we aim the waypoint

  tuneCarrierFireRange {.intdefine.} = 110 # while carrying, only shoot enemies this close
  CarrierFireRange = float(tuneCarrierFireRange)
  tuneRushEngageRange {.intdefine.} = 230 # racing for the steal: only fight what blocks it
  RushEngageRange = float(tuneRushEngageRange)
  tuneEscortEngageRange {.intdefine.} = 320 # escorting a run: only fight near threats
  EscortEngageRange = float(tuneEscortEngageRange)
  tunePocketRushRange {.intdefine.} = 210 # this close to the enemy pedestal, just GRAB
  PocketRushRange = float(tunePocketRushRange)
  ThreatRange = 200.0         # react to a visible enemy this close facing us
  DuckRange = 340.0           # duck from remembered threats this close on cooldown
  MateSpacing = 40.0          # soft repulsion radius between teammates
  CorridorHalfWidth = 15.0    # friendly-fire corridor half width along the ray
  LeadTicks = 6.0             # aim this many ticks ahead of a moving enemy:
                              # the 5-tick windup releases the bullet late
  TrackMatchDist = 40.0       # a sighting matches a track within this distance
  TrackTtl = 120              # forget a player not seen for ~5s
  TrackCap = 8                # eight real opponents / teammates per side
  FreshShotTicks = 24         # only fire at tracks seen this recently; the
                              # turret needs traverse time, so chases keep
                              # shooting a bit after the target fogs out
  tuneThiefFixTtl {.intdefine.} = 40 # a thief position fix guides the chase this long
  ThiefFixTtl = tuneThiefFixTtl
  tuneThiefLeadTicks {.intdefine.} = 18 # ticks of thief-intercept prediction
  ThiefCommitTtl = 240        # -d:thiefCommit: how long a dead-reckoned fix
                              # keeps EVERY free role committed to the chase —
                              # a thief who ducks into fog is still running our
                              # flag; abandoning the hunt after ~1.7s is how
                              # campers walk flags home (daveey, R1693 review)

  AimBrads = 256              # aim angle units per full turn
  AimRate = 5                 # brads/tick a held rotate button turns the aim
                              # (matches the server's aimTurnRate default)
  MaxHp = 3                   # hitPoints per life (config default). Our OWN
                              # hp baseline only — enemy bars carry their own
                              # denominator ("hp <n>/<m>", armor-adjusted) and
                              # are parsed, not rebuilt from this.
  HpPipRadius = 22.0          # a player's overhead hp bar sits within this
  HpFocusBonus = 60.0         # px of effective-distance credit per missing
                              # enemy hit point — a tiebreak between
                              # comparably-engageable targets, never a reason
                              # to swing the turret across the map
  tuneThiefFocusBonus {.intdefine.} = 400 # px of credit for the enemy RUNNING OUR FLAG:
  ThiefFocusBonus = float(tuneThiefFocusBonus)
                                # dominates every positional tiebreak — killing
                              # the thief returns the flag instantly
  TraversePxPerBrad = 1.6     # px of effective distance per brad of turret
                              # swing needed to lay on the target: err/AimRate
                              # ticks of traverse at ~8px of enemy closing
                              # motion per tick = 8/5 px per brad
  ButtonC = 1'u8 shl 7        # grenade charge/throw (input mask bit 128)
  NadeMaxRange = 240.0        # full-charge throw distance (~fifth of the field)
  NadeMinRange = 78.0         # never lob inside this — the 58px blast + drift
                              # would clip us (GV17: blast 40 -> 52; GV31: the
                              # blast tests BODIES, so its reach is 52 + 6)
  NadeBlast = 58.0            # effective blast reach against a BODY, not the
                              # 52px circle: GV31 catches a cog whose solid
                              # footprint (PlayerHalf) touches it, so on-axis
                              # reach is GrenadeBlastRadius + PlayerHalf
  NadeFullChargeTicks = 24    # ~1s of holding C reaches max range
  NadePickupDetour = 90.0     # grab a corner pickup within this detour range
  BarrierDetour = 60.0        # worthwhile detour to grab a cardboard barrier
  BarrierPlaceRange = 170.0   # a threat this close is worth walling off
  NadeCampTicks = 360         # -d:campNade: a STATIONARY remembered enemy stays
                              # lob-eligible this long after fogging out — a
                              # camper's position is durable knowledge, and the
                              # lob over his cover is the counter the gun lacks
  NadeCampSpeed = 0.3         # px/tick: tracks slower than this count as camped
  MedKitDetour = 80.0         # heal-detour budget when merely wounded
  MedKitCriticalReach = 180.0 # at 1 hp a heal outranks the current errand
  MedKitRespawn = 30 * 24     # a taken kit refills after 30s (sim constant)
  MedKitSeenClear = 55.0      # inside this range an empty spot is truly
                              # empty (bubble vision), not just fogged
  PlasmaReach = 187.0         # spray cone reach: 5 squares of centerline plus
                              # the sprayed cog's own radius, because the cone
                              # hits BODIES (sim PlasmaArcReach +
                              # PlasmaArcBodyRadius, GameVersion 30)
  PlasmaSlope = 0.25          # centerline cone half-width per px forward: 2
                              # squares wide at max reach, atan(1/4) ~ 14
                              # degrees (sim PlasmaArcMaxWidth / Reach)
  PlasmaBodyRadius = 17.0     # half a cog, added to the cone's half-width at
                              # EVERY distance (sim PlasmaArcBodyRadius). It
                              # dominates up close: at 40px out the centerline
                              # cone forgives 10px of miss and the body another
                              # 17, so a point-blank spray is far harder to
                              # whiff than the 14-degree figure suggests.
  PlasmaDetour = 70.0         # attacker detour budget for a spray can pickup
  ShieldStealDetour = 480.0   # MidGuard's shield trip: the enemy endzone
                              # shield sits low in their back column
                              # (~215px from the pedestal since the game-v7
                              # split), so the round trip costs ~430 path px
  PickupRespawn = 30 * 24     # spray can/shield respawn timer (sim constant)
  MedKitCarrierBudget = 90.0  # extra path px a hurt CARRIER spends to heal:
                              # a full-heal carrier survives pocket exits
                              # that kill a 1 hp one
  CarrySelfRadius = 26.0      # the carried flag banner is centered on its
                              # carrier: anything inside this slack that no
                              # visible mate sits closer to is OUR carry
  CarrierEstSpeed = 1.0       # px/tick a fogged mate-carrier is assumed to
                              # advance homeward (carrier moves at ~70% speed)
  CombatDeadband = 2          # stop the traverse within this error (brads);
                              # AimRate 5 cannot settle tighter than +-2
  CruiseDeadband = 8          # sloppier deadband for non-combat aim
  FireSlackPx = 11.0          # fire when the aim error's perpendicular miss
                              # at the target's range is inside this (the
                              # corridor half-width is ~14px; keep margin)
  ArcReach = 130.0            # spray cone: sim reach 136px, small margin
  ArcConeBrads = 9            # cone half-width ~14deg at max reach
  CenterScanHalf = 280.0      # |x - CenterX| under this counts as the corridor
  TargetCallCooldown = 48     # min ticks between one bot's engage callouts
  ScanArc = 44                # scan sweeps this many brads each side of the
                              # watch heading (cone half-angle is 32 brads)
  CounterPunchTick = 1400     # by here a 0-steal attack is not converting:
                              # fall back and win the attrition instead
  PushOutTicks = 360          # endgame push: no enemy seen for ~15s...
  PushOutMinGame = 1400       # ...this deep into the game breaks the posts
  StalemateTick = 2000        # nobody has MOVED a flag by here: the game is
                              # heading for a lose-lose timeout — go convert.
  StaleClusterTtl = 600       # -d:nadeCluster: campers hold ground — a track
                              # this old is still a target if it CLUSTERED
  ClusterPairPx = 100.0       # two remembered enemies this close = one blast.
                              # Two bodies fit one blast iff they are within
                              # 2*NadeBlast (116) of each other; keep the same
                              # ~86% safety margin the 52px reach used (90).
  SalvoWindow = 70            # ticks after the charge order to force the lob
  SiegeBarrageTicks = 100     # -d:siege: bombardment window per cycle
  SiegeAdvanceTicks = 90     # -d:siege: advance-and-settle window per cycle
  SiegeStep = 170.0           # -d:siege: ground taken per advance order
  QuietForBreak = 240         # ...but only when the field is actually DEAD:
                              # no enemy contact this long. A duel-heavy rival
                              # (h006) keeps flags parked while trading kills —
                              # that game resolves by wipe, not timeout, and
                              # breaking the castle early just donates our
                              # respawn-logistics ground to its midfield gun.
  tuneLatePushTick {.intdefine.} = 3400 # all-in on the clock: past this tick a draw is
  LatePushTick = tuneLatePushTick
                              # A LOSS FOR BOTH (GV21 lose-lose timeouts) and
                              # games cap at 5000 ticks — the all-in must land
                              # with time to convert. Scaled from 6800/10000.
                              # the default outcome, so commit to the capture
  HoldFrontCap = 220.0        # -d:holdFront: ceiling on the phalanx creep — a
                              # castle line near our wall: fights there recur on
                              # ground where our respawn walk is ~100px and the
                              # attacker re-crosses ~400px of watched open ground

  CoverShieldDist = 42.0      # an obstacle this close blocks a threat direction
  PeekLineDist = 150.0        # floor for an overwatch peek firing line; post
                              # scoring strongly prefers the longest line
  DuckSearchCells = 3         # duck-cell search radius in nav cells
  PeekSearchCells = 3         # peek-cell search radius in nav cells
  ExposureRange = 380.0       # enemy threat radius used for exposure costing
  ExposureThreats = 3         # cost only the freshest few remembered threats
  ExposureTrackTtl = 60       # only cost threats remembered this recently
  UnderFireTrackTtl = 16      # tracks this fresh can pin us on open ground
  SerpentineNear = 100.0      # serpentine band: closer threats are jink/duck
  SerpentineFar = 400.0       # ... and farther tracks cannot really aim at us
  StepCost = 5'i32            # orthogonal move cost in the nav field
  DiagCost = 7'i32            # ~sqrt(2) * StepCost
  ExposedCost = 14'i32        # extra cost to enter a threat-exposed cell:
                              # under fog the exposure model (enemy sniper
                              # posts + fresh tracks) is the only warning of
                              # watched lanes, so routes respect it hard
  tuneFlankDepth {.intdefine.} = 260 # wide flankers cross this far past mid
  FlankDepth = float(tuneFlankDepth)
  tuneWeaveBand {.intdefine.} = 280 # rushers serpentine within this x-band of mid
  WeaveBand = float(tuneWeaveBand)
  tuneWeaveGain {.intdefine.} = 60 # percent side-steer gain while weaving
  tuneCarrierLaneBiasDiv {.intdefine.} = 500 # nearest-lane stickiness divisor
  tuneCarrierLaneThreatY {.intdefine.} = 120 # lane-threat y-window
  tuneExtraDefenders {.intdefine.} = 0 # promote flank/mid seats to defense

  LaneTop = 40.0              # open corridor above the mirrored obstacles

## Map dimensions, adopted at nav-grid build from the walkability sprite
## (which spans the whole arena). The game supports multiple maps —
## "arena" (1235x659, the default) and "arena-large" (1606x858) — and this
## bot plays either; everything position-shaped below derives from these.
## Initialized to the default arena.
var
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  LaneMid = float(CenterY)
  LaneBottom = float(MapH) - LaneTop  # open corridor below the obstacles
  FireRange = float(MapW) + 15.0
    # engage distance: every map's gun range is comfortably over its own
    # width (1300 on the 1235px arena, 1690 on the 1606px arena-large), so
    # a hair past a map-width is always inside it. 1250.0 on the default
    # arena — the value this bot always used.
  GameTeams = 2
    # how many teams share the arena, from the `game teams <n> map <w>x<h>`
    # init marker. On 2-team boards the classic mirrored-arena constants
    # below run untouched; a bigger count re-deals this bot's color (seats
    # go round the teams, slot mod GameTeams) and swaps the geometry procs
    # onto the endzone-anchored multi-team frame (see deriveMultiFrame).
  EndzoneMarks: seq[tuple[color, shape: string, x0, y0, x1, y1: int]]
    # every team's stated home capture region, from the per-team
    # `endzone <color> <shape> <x0>,<y0> <x1>,<y1>` init markers: the shape
    # archetype and the inclusive bounding-box corners in map pixels. On
    # 2-team boards the bot still derives its tuned column geometry itself
    # (homeSign and the capture-column constants predate the marker); on
    # multi-team boards these zones ARE the geometry (deriveMultiFrame).
  HandicapMarks: seq[tuple[color: string, permille, hp, lives, spdPct,
      missPct: int]]
    # every team's stated handicap, keyed by wire color token, from the
    # per-team `handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>`
    # init markers (see LabelPrefixHandicap): the authored fraction in
    # permille plus the ENGINE-resolved deltas (hit points, lives, speed as a
    # percent of base, percent of point-blank shots dropped). Parsed and
    # stored so strategy can weigh a weakened team (its own or an enemy's);
    # nothing steers off it yet.

const TeamColorNames = ["red", "blue", "green", "yellow"]
  ## Wire color tokens in engine seat-deal order: a game's active teams are
  ## always a prefix of this list, and seats go round them (slot mod teams).

type
  Team = enum
    Red, Blue

  Role = enum
    MidTop, MidBottom, MidGuard, FlankTop, FlankBottom,
    Overwatch, HomeDefender

  Vec = object                # a map-space point or direction
    x, y: float

  Actor = object              # a player visible this frame
    pos: Vec
    facingRight: bool
    hp: int                   # from the overhead pip bar; 0 = not read

  Track = object              # a remembered player
    pos, vel: Vec
    lastSeen: int
    synthetic: bool           # injected from an E-shout, not own eyes
    facingRight: bool
    hp: int                   # last observed hit points; 0 = never read

  Bot = ref object
    slot: int
    team: Team
    myColor: string           # our ACTUAL wire color ("red".."yellow"): the
                              # slot-dealt guess until the self marker,
                              # the one sprite only we ever see, confirms it
    colorLocked: bool         # self marker seen this game: myColor is truth
    targetColor: string       # multi-team raid target's color; "" = classic
    targetFlagSeen: int       # last tick the target's flag was accounted for
    role: Role
    tick: int                 # sim ticks, advanced by frames received
    navBuilt: bool
    cellWalkable: seq[bool]   # eroded walkability, GridW x GridH
    coverCell: seq[bool]      # walkable cells hugging an obstacle
    exposure: seq[bool]       # cells a remembered enemy could shoot into
    navDist: seq[int32]       # cost field toward navGoal
    navGoal: int              # goal cell of the current field, -1 = stale
    navStamp: int             # tick the field was computed
    postHold, postPeek: Vec   # overwatch cover post and its peek cell
    postReady: bool
    enemyPosts: seq[Vec]      # the mirrored ENEMY sniper peek cells
    chokeHold: Vec            # defender hold point snapped to cover
    behindLines: bool         # flanker has crossed deep into the enemy half
    enemies: seq[Track]
    mates: seq[Track]
    carrierPos, carrierVel: Vec   # last fix on the thief carrying OUR flag
    carrierSeen: int
    lastEnemySeen: int        # last tick ANY enemy was inside our vision
    gameStart: int            # tick of the last lobby-to-playing transition
    firedLast: bool           # A was set on the previous sent mask
    estAim: int               # dead-reckoned own aim angle in brads
    rotSign: int              # rotation of the last sent mask: +1 B, -1 Select
    wasDead: bool             # respawn resets the aim to the spawn heading
    scanHigh: bool            # scan sweep currently heading to the high end
    lastPos: Vec
    stuckTicks: int
    jinkUntil: int
    jinkBits: uint8
    nadeCharge: int           # ticks the C button has been held; 0 = idle
    mateFixPos: Vec           # last SEEN position of a mate-carried enemy heart
    mateFixTick: int          # tick of that sighting; 0 = never seen this game
    nadeNeed: int             # charge ticks required for the planned throw
    shoutWant: string         # chat packet to send after this frame's input
    lastShoutTick: int        # rate limit: server allows one shout per second
    tauntBank: seq[string]    # Bedrock-prefetched taunts, popped front-first
    comebackWant: string      # pending reply to a heard enemy shout
    corpseCount: int          # visible enemy corpses last frame (kill signal)
    killMoodUntil: int        # taunt window opened by a fresh kill
    nextPeaceTick: int        # slot-staggered cadence for the audible persona
    lastTeamShoutSeen: int    # any teammate bubble; peace lines keep clear of it
    nadeSpotPos: seq[Vec]     # -d:nadeRelay: learned grenade spawn spots
    nadeSpotEta: seq[int]     # 0 = believed stocked; else respawn-ready tick
    wasNade: bool             # last tick's carried-grenade state (edge detect)
    nadeShoutWant: string     # pending "G<cx> <cy>" pickup announcement
    lastTargetCall: int       # -d:targetCall: engage-callout rate limit
    siegeLane: int            # -d:siege: vertical under assault (1/2/3), 0 none
    siegePhase: int           # -d:siege: 0 idle, 1 bombard, 2 advance
    siegePhaseUntil: int      # tick the current siege phase expires
    siegeFront: float         # captured ground line during a siege
    wasPushOut: bool          # -d:nadeCluster: charge-start edge detector
    campPos: seq[Vec]         # long-memory enemy sighting spots (campers)
    campSeen: seq[int]        # last tick each camp spot was refreshed
    salvoUntil: int           # force-lob window after the charge order
    sweepFlip: bool           # -d:centerScan: which vertical arc is swept
    lastEnemyShout: string    # last enemy shout label already responded to
    lastComebackReq: int      # rate limit on comeback generation requests
    wasMateCarry: bool        # edge detector: a fresh steal opens a taunt window
    tripping: bool            # mid-errand to a gear spot: sprint, no fights
    hp: int                   # own hit points, read from the HUD lives label
    kitPos: seq[Vec]          # discovered med kit spots (two, center line)
    kitAbsentAt: seq[int]     # tick a spot was last seen empty; -1 = present
    plasmaPos: seq[Vec]       # discovered spray can spots (side midpoints)
    plasmaAbsentAt: seq[int]
    shieldPos: seq[Vec]       # discovered shield spots (endzone back columns)
    shieldAbsentAt: seq[int]
    everStoleTheirs: bool     # any own/mate carry of the enemy flag this game
    everLostOurs: bool        # our flag has been stolen at least once
    phalanxHold: float        # frozen advance front while our lane has contact
    helpLane: int             # 1=top 2=mid 3=bottom, from an H-shout
    helpUntil: int            # tick the help retasking expires
    lastEShout: int           # scout sighting-broadcast rate limit
    lastHShout: int           # help-call rate limit

var
  SelfStrategyTeam = Red
    # this process's bot.team mirrored into a module global (one bot per
    # process) so the team-parameterized geometry procs below can tell "our"
    # team from "the enemy" without threading the Bot through 30 call sites.
  MultiHome: Vec              # our pedestal (zone center until one is seen)
  MultiCapture: Vec           # our endzone center: where a carry scores
  MultiTarget: Vec            # the raid target's pedestal
  MultiHomeSign = -1.0        # sign of our home->target axis (east/west)
  MultiReady = false
    # the anchors above are derived (deriveMultiFrame). Gated on GameTeams
    # so classic 2-team boards NEVER leave the tuned mirrored-arena math.

proc multiFrameOn(): bool {.inline.} =
  ## Whether the geometry procs run on the multi-team endzone frame.
  GameTeams > 2 and MultiReady

proc roleForSeat(seat: int, team: Team): Role =
  ## Deterministic role spread over the 8 per-team seats. Seats 2 and 3 both
  ## spawn at flag height, but the sim's un-mirrored +-6px spawn offset makes
  ## seat 3 the closest spawn to the flag for Red and seat 2 for Blue — the
  ## rusher takes whichever is closest so we win the opening pickup race.
  ## Under fog the attack wave is six strong (a mid quad plus two flankers):
  ## with no global flag tracking a carrier that slips the contest is hard to
  ## reacquire, so committed offense converts steals into captures, and the
  ## back line is one lane sniper plus the home defender.
  when defined(rushAll):
    # Shuffled-seat leagues deal this policy 1-2 agents onto random mixed
    # teams: coordinated-wave roles waste the seat, and a single capture wins
    # the episode outright, so every seat plays the flag-racing rusher.
    MidTop
  else:
    case seat
    of 0:
      when tuneExtraDefenders >= 2: HomeDefender
      else: FlankBottom          # wide bottom lane, get behind the contest
    of 1:
      when tuneExtraDefenders >= 3: HomeDefender
      else: MidGuard               # third mid, trails offset high and cleans up
    of 2: (if team == Blue: MidTop else: MidBottom)
    of 3: (if team == Red: MidTop else: MidBottom)
    of 4: MidBottom        # fourth mid: the second trailing attacker
    of 5: Overwatch        # cover post flanking the ring: the lane sniper
    of 6:
      when tuneExtraDefenders >= 1: HomeDefender
      else: FlankTop             # wide top lane, get behind the contest
    else: HomeDefender     # choke guard before our capture column

when defined(zonePhalanx):
  type PhalanxDuty = enum
    pdScout, pdTopA, pdTopB, pdMidA, pdMidB, pdBotA, pdBotB, pdFloat

  proc phalanxDuty(bot: Bot): PhalanxDuty =
    ## Zone-control assignment: a shield scout spots forward, three staggered
    ## pairs hold the lanes, the eighth seat floats on help calls.
    case clamp(bot.slot div 2, 0, 7)
    of 1: pdScout            # MidGuard seat becomes the forward observer
    of 6: pdTopA
    of 2, 3: (if bot.role == MidTop: pdTopB else: pdBotB)
    of 0: pdBotA
    of 5: pdMidA
    of 4: pdMidB
    else: pdFloat            # HomeDefender seat: choke + reinforcement

  proc phalanxLaneY(d: PhalanxDuty): float =
    case d
    of pdTopA, pdTopB: LaneTop + 26.0
    of pdMidA, pdMidB: LaneMid
    else: LaneBottom - 26.0

  proc phalanxLaneNo(d: PhalanxDuty): int =
    case d
    of pdTopA, pdTopB: 1
    of pdMidA, pdMidB: 2
    else: 3

proc vec(x, y: float): Vec =
  Vec(x: x, y: y)

proc `+`(a, b: Vec): Vec = vec(a.x + b.x, a.y + b.y)
proc `-`(a, b: Vec): Vec = vec(a.x - b.x, a.y - b.y)
proc `*`(a: Vec, s: float): Vec = vec(a.x * s, a.y * s)

proc len(a: Vec): float =
  hypot(a.x, a.y)

proc dist(a, b: Vec): float =
  len(a - b)

proc norm(a: Vec): Vec =
  let l = a.len()
  if l < 1e-6: vec(0, 0) else: a * (1.0 / l)

proc dot(a, b: Vec): float =
  a.x * b.x + a.y * b.y

proc cross(a, b: Vec): float =
  a.x * b.y - a.y * b.x

proc octantBits(d: Vec): uint8 =
  ## D-pad bits for the 8-way direction nearest to `d`. The worst-case aim
  ## error is 22.5 degrees, safely inside the 25-degree firing cone.
  if d.len() < 1e-6:
    return 0
  let octant = (int(round(arctan2(d.y, d.x) / (PI / 4))) + 8) mod 8
  case octant
  of 0: ButtonRight
  of 1: ButtonRight or ButtonDown
  of 2: ButtonDown
  of 3: ButtonDown or ButtonLeft
  of 4: ButtonLeft
  of 5: ButtonLeft or ButtonUp
  of 6: ButtonUp
  else: ButtonUp or ButtonRight

proc bradsOf(d: Vec): int =
  ## The aim angle in brads pointing along `d`: 0 = east (+x), increasing
  ## counter-clockwise on screen (64 = north; map y grows downward).
  if d.len() < 1e-6:
    return 0
  (int(round(arctan2(-d.y, d.x) * float(AimBrads div 2) / PI)) +
    AimBrads) mod AimBrads

proc bradsDir(brads: int): Vec =
  ## The unit vector of one aim angle in brads (the true fire axis).
  let angle = float(brads) * PI / float(AimBrads div 2)
  vec(cos(angle), -sin(angle))

proc bradsErr(desired, current: int): int =
  ## The signed shortest arc from `current` to `desired` in -128..127:
  ## positive means rotate counter-clockwise (hold B).
  (desired - current + AimBrads + AimBrads div 2) mod AimBrads -
    AimBrads div 2

proc spawnAim(team: Team): int =
  ## The spawn/respawn aim angle: toward the enemy side (on a multi-team
  ## board, along our home->target raid axis; the stated `own aim` HUD
  ## marker resyncs the estimate on the next frame either way).
  if multiFrameOn():
    return bradsOf(MultiTarget - MultiHome)
  if team == Red: 0 else: AimBrads div 2

proc slotFromUrl(url: string): int =
  ## Reads the `slot` query parameter from the websocket URL.
  let key = "slot="
  let at = url.find(key)
  if at < 0:
    return 0
  var i = at + key.len
  var digits = ""
  while i < url.len and url[i] in {'0' .. '9'}:
    digits.add(url[i])
    inc i
  if digits.len == 0: 0 else: digits.parseInt()

proc mapPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## Map-space center of a sprite object (the map object sits at the origin,
  ## so the camera offset is zero; keep it for exactness). Since the 0.7.8
  ## renderer restore the wire is back to 1x map pixels (the 0.6-0.7.7 HD
  ## era carried 3x-scaled coordinates), with sprites centered on their map
  ## points.
  vec(
    float(o.x + o.width div 2 + client.mapCameraX),
    float(o.y + o.height div 2 + client.mapCameraY)
  )

proc ownAimBrads(client: ProtocolClient): int =
  ## The engine-stated own-aim angle from the `own aim <brads>` HUD marker,
  ## or -1 when the marker is absent (pre-marker engines) or unparsable.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixOwnAim):
      let tail = o.label[LabelPrefixOwnAim.len .. ^1]
      try:
        return parseInt(tail)
      except ValueError:
        return -1
  -1

proc findSelf(
    client: ProtocolClient, color: string): tuple[alive: bool, pos: Vec] =
  ## Our avatar via the distinct self marker, only drawn while we are alive.
  for facingRight in [true, false]:
    let label = labelSelf(
      color, if facingRight: LabelSideRight else: LabelSideLeft)
    for o in client.spriteObjectsWithLabel(label):
      return (alive: true, pos: client.mapPos(o))

proc actorsFor(client: ProtocolClient, color: string): seq[Actor] {.measure.} =
  ## Visible players of one color in map coordinates plus horizontal facing
  ## and hit points. The overhead "hp <n>/<max>" pip bar is fog-culled with
  ## its player, so whenever the player is visible its hp is too: attach the
  ## nearest pip bar within HpPipRadius.
  for facingRight in [true, false]:
    let label = labelPlayer(
      color, if facingRight: LabelSideRight else: LabelSideLeft)
    for o in client.spriteObjectsWithLabel(label):
      result.add(Actor(pos: client.mapPos(o), facingRight: facingRight))
  for (o, label) in client.spriteObjectsWithLabelPrefix(LabelPrefixHp):
    # `hp <hp>/<max>[ shield <s>]` — TRUE hit points since the bar redesign:
    # the numerator is the seat's remaining base hp against its OWN max (the
    # armor perk raises it past our MaxHp), and a held shield layer appends
    # its remaining absorb hp. Threat math cares about what is left to chew
    # through, so attach base + shield, like the old bar's effective-hp fold.
    let tail = label[LabelPrefixHp.len .. ^1]
    let slash = tail.find('/')
    if slash <= 0:
      continue
    var hp = parseInt(tail[0 ..< slash])
    let shieldCut = tail.find(LabelHpShieldSep)
    if shieldCut >= 0:
      hp += parseInt(tail[shieldCut + LabelHpShieldSep.len .. ^1])
    let p = client.mapPos(o)
    var best = -1
    var bestD = HpPipRadius
    for i in 0 ..< result.len:
      let d = dist(result[i].pos, p)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      result[best].hp = hp

proc walkableAt(client: ProtocolClient, x, y: int): bool =
  if x < 0 or y < 0 or x >= client.walkabilityWidth or
      y >= client.walkabilityHeight:
    return false
  client.walkabilityMask[y * client.walkabilityWidth + x]

proc footprintFits(client: ProtocolClient, x, y: int): bool =
  ## True when the player's solid box centered at (x, y) is all walkable,
  ## mirroring canOccupy in the sim.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not client.walkableAt(x + dx, y + dy):
        return false
  true

proc cellOf(p: Vec): int =
  let
    cx = clamp(int(p.x) div NavCell, 0, GridW - 1)
    cy = clamp(int(p.y) div NavCell, 0, GridH - 1)
  cy * GridW + cx

proc cellCenter(cell: int): Vec =
  vec(
    float((cell mod GridW) * NavCell + NavCell div 2),
    float((cell div GridW) * NavCell + NavCell div 2)
  )

proc pixelRayClear(client: ProtocolClient, a, b: Vec): bool =
  ## True when no wall pixel blocks the segment; mirrors lineOfSightClear in
  ## the sim (walls are exactly the non-walkable pixels).
  let
    ax = int(a.x)
    ay = int(a.y)
    bx = int(b.x)
    by = int(b.y)
    steps = max(abs(bx - ax), abs(by - ay))
  if steps == 0:
    return true
  for s in 1 .. steps:
    if not client.walkableAt(ax + (bx - ax) * s div steps,
                             ay + (by - ay) * s div steps):
      return false
  true

proc rayClearCoarse(client: ProtocolClient, a, b: Vec, step: float): bool =
  ## Coarsely-sampled walkability raycast for cover scoring and exposure
  ## costing, where an occasional missed thin corner is an acceptable trade.
  let
    d = b - a
    l = d.len()
  if l < 1e-6:
    return true
  let n = max(1, int(l / step))
  for s in 1 .. n:
    let p = a + d * (float(s) / float(n))
    if not client.walkableAt(int(p.x), int(p.y)):
      return false
  true

proc openLineLen(client: ProtocolClient, a, dir: Vec, maxLen, step: float): float =
  ## Length of the wall-free ray from `a` along unit `dir`, capped at maxLen.
  ## Sizes sniper firing lines and arrow-snipe rays under the map-wide gun.
  var l = step
  while l <= maxLen:
    let p = a + dir * l
    if not client.walkableAt(int(p.x), int(p.y)):
      return l - step
    l += step
  maxLen

proc homeSign(team: Team): float =
  ## -1 toward Red's home edge (left), +1 toward Blue's (right). On a
  ## multi-team board the frame is bot-relative instead: the sign of our own
  ## home->target axis (the target is picked for maximum horizontal offset,
  ## so the east-west advance math never degenerates).
  if multiFrameOn():
    return (if team == SelfStrategyTeam: MultiHomeSign else: -MultiHomeSign)
  if team == Red: -1.0 else: 1.0

proc homeDeepX(team: Team): float =
  ## A point well inside our capture zone, mirrored across the map's
  ## vertical center line (150 on the default 1235px arena, scaled with
  ## the map). On a multi-team board: our stated endzone's center x.
  if multiFrameOn():
    return MultiCapture.x
  let deep = float(MapW * 150 div 1235)
  if team == Red: deep else: float(MapW - 1) - deep

proc enemy(team: Team): Team =
  ## The opposing team.
  if team == Red: Blue else: Red

proc flagHome(team: Team): Vec =
  ## The STATIC pedestal position of one team's flag: the center of the
  ## team's protected spawn pocket (matches flagHome in src/ctf/sim.nim,
  ## computed from the map size instead of the old hardcoded 186/1049).
  ## On a multi-team board: our own or the raid target's pedestal anchor
  ## (every call site passes bot.team or enemy(bot.team)).
  if multiFrameOn():
    return (if team == SelfStrategyTeam: MultiHome else: MultiTarget)
  if team == Red:
    vec(float(CenterX - CenterX * 7 div 10), float(CenterY))
  else:
    vec(float(CenterX + (MapW - CenterX) * 7 div 10), float(CenterY))

proc chokeSpot(team: Team): Vec =
  ## Defender hold point between the flag and our home edge, mirrored
  ## exactly across the map's vertical center line. (390, 340) on the
  ## default 1235x659 arena — the gap between the diamond and disc
  ## columns — scaled proportionally so it lands in the same tactical
  ## pocket on every map. On a multi-team board the tuned pocket
  ## coordinates mean nothing on a rotated corner/arm home: hold part-way
  ## out from our pedestal toward the open board instead.
  if multiFrameOn():
    return MultiHome +
      (vec(float(CenterX), float(CenterY)) - MultiHome) * 0.3
  let
    x = float(MapW * 390 div 1235)
    y = float(MapH * 340 div 659)
  if team == Red: vec(x, y) else: vec(float(MapW - 1) - x, y)

proc nearestOpenCell(bot: Bot, cell: int): int =
  ## The nearest walkable nav cell, searched in expanding rings.
  if bot.cellWalkable[cell]:
    return cell
  let
    cx = cell mod GridW
    cy = cell div GridW
  for r in 1 .. 16:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
          continue
        if bot.cellWalkable[ny * GridW + nx]:
          return ny * GridW + nx
  cell

proc snapToCover(bot: Bot, p: Vec): Vec =
  ## The nearest cover cell within a few cells of a point, else the point.
  let
    c0 = bot.nearestOpenCell(cellOf(p))
    cx = c0 mod GridW
    cy = c0 div GridW
  var bestD = 1e18
  result = p
  for dy in -6 .. 6:
    for dx in -6 .. 6:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.coverCell[nc]:
        continue
      let d = dist(cellCenter(nc), p)
      if d < bestD:
        bestD = d
        result = cellCenter(nc)

proc scanPost(
    bot: Bot, client: ProtocolClient, eSign, wantY: float
): tuple[hold, peek: Vec, ready: bool] =
  ## Finds one overwatch sniper post for the side whose guns point along
  ## `eSign`: a cover cell hugging the center ring, shielded from the front,
  ## with a sideways peek cell that owns the LONGEST clear firing line — the
  ## map-wide gun makes the lane length the post's value.
  var bestScore = 1e18
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.coverCell[c]:
        continue
      let
        p = cellCenter(c)
        fwd = eSign * (p.x - float(CenterX))
      if fwd > -40.0 or fwd < -160.0:
        continue                         # this side of the ring, hugging it
      if rayClearCoarse(client, p, p + vec(eSign * CoverShieldDist, 0.0), 4.0):
        continue                         # nothing shields us from the front
      var
        peek: Vec
        peekLine = 0.0
      for dyc in [-2, 2, -1, 1]:
        let ny = cy + dyc
        if ny < 0 or ny >= GridH or not bot.cellWalkable[ny * GridW + cx]:
          continue
        let q = cellCenter(ny * GridW + cx)
        let line = openLineLen(client, q, vec(eSign, 0.0), FireRange, 6.0)
        if line > peekLine:
          peekLine = line
          peek = q
      if peekLine < PeekLineDist:
        continue
      # The firing-line length dominates; the position terms break near-ties
      # toward the wanted flank height and hugging the flag ring.
      let score = abs(p.y - wantY) + abs(fwd + 90.0) * 0.7 - peekLine * 0.7
      if score < bestScore:
        bestScore = score
        result.hold = p
        result.peek = peek
        result.ready = true

proc pickPost(bot: Bot, client: ProtocolClient) =
  ## Chooses our own overwatch post (the overwatch seat only): fire from the
  ## peek, duck back to the hold during cooldown.
  bot.postReady = false
  if bot.role != Overwatch:
    return
  let
    eSign = -homeSign(bot.team)
    wantY = float(CenterY) + 60.0
  let post = bot.scanPost(client, eSign, wantY)
  if post.ready:
    bot.postHold = post.hold
    bot.postPeek = post.peek
    bot.postReady = true

proc findEnemyPosts(bot: Bot, client: ProtocolClient) =
  ## Precomputes the standing virtual threats every carrier run has to
  ## respect, fed into exposure costing and lane choice: the mirrored ENEMY
  ## overwatch post (a stationary, hidden killer) and the ENEMY spawn
  ## pocket — every kill respawns an armed enemy at the
  ## pedestal aiming our way, so the pocket mouth (and its mid lane) is
  ## permanently watched ground even when no track remembers anyone there.
  bot.enemyPosts.setLen(0)
  let post = bot.scanPost(client, homeSign(bot.team), float(CenterY) + 60.0)
  if post.ready:
    bot.enemyPosts.add(post.peek)
  bot.enemyPosts.add(flagHome(enemy(bot.team)))

proc adoptMapSize(client: ProtocolClient) =
  ## The walkability sprite spans the whole arena: adopt its dimensions as
  ## THE map size and rederive everything position-shaped. The game selects
  ## its map per episode (config mapPath: "arena" or "arena-large"), so the
  ## bot must read the size off the wire instead of assuming it.
  MapW = client.walkabilityWidth
  MapH = client.walkabilityHeight
  CenterX = MapW div 2
  CenterY = MapH div 2
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  LaneMid = float(CenterY)
  LaneBottom = float(MapH) - LaneTop
  FireRange = float(MapW) + 15.0

proc adoptGameParams(client: ProtocolClient) =
  ## Reads the stated episode parameters off the init marker
  ## `game teams <count> map <width>x<height>` (see LabelPrefixGameParams).
  ## The team count is the marker's unique intel; the map size restates the
  ## walkability sprite's dimensions, which adoptMapSize already adopted, so
  ## it is not re-read here.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixGameParams):
      let parts = o.label[LabelPrefixGameParams.len .. ^1].split(' ')
      if parts.len == 3:
        try:
          GameTeams = clamp(parseInt(parts[0]), 2, 4)
        except ValueError:
          discard
      break

proc adoptEndzones(client: ProtocolClient) =
  ## Reads every team's stated home capture region off the per-team init
  ## markers `endzone <color> <shape> <x0>,<y0> <x1>,<y1>` (see
  ## LabelPrefixEndzone). The shape token is validated against the closed
  ## LabelEndzoneShapes vocabulary — which also skips the spectator-only
  ## `endzone <color> power <n>` glow labels, were they ever to appear here.
  EndzoneMarks.setLen(0)
  for o in client.spriteObjects():
    if not o.label.startsWith(LabelPrefixEndzone):
      continue
    let parts = o.label[LabelPrefixEndzone.len .. ^1].split(' ')
    if parts.len != 4 or parts[1] notin LabelEndzoneShapes:
      continue
    let
      lo = parts[2].split(',')
      hi = parts[3].split(',')
    if lo.len != 2 or hi.len != 2:
      continue
    try:
      EndzoneMarks.add (
        color: parts[0], shape: parts[1],
        x0: parseInt(lo[0]), y0: parseInt(lo[1]),
        x1: parseInt(hi[0]), y1: parseInt(hi[1])
      )
    except ValueError:
      discard

proc adoptHandicaps(client: ProtocolClient) =
  ## Reads every team's stated handicap off the per-team init markers
  ## `handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>` (see
  ## LabelPrefixHandicap): the authored fraction in permille plus the
  ## ENGINE-resolved deltas — hit points, lives, max speed as a percent of
  ## base, and the percent of point-blank shots dropped. Stored per color so
  ## strategy can weigh a weakened team (ours or an enemy's); nothing steers
  ## off it yet. Emitted for every team, permille 0 included, so an ABSENT
  ## color means an engine without the marker, not "no handicap".
  HandicapMarks.setLen(0)
  for o in client.spriteObjects():
    if not o.label.startsWith(LabelPrefixHandicap):
      continue
    let parts = o.label[LabelPrefixHandicap.len .. ^1].split(' ')
    if parts.len != 10 or parts[2] != "hp" or parts[4] != "lives" or
        parts[6] != "spd" or parts[8] != "miss":
      continue
    try:
      HandicapMarks.add (
        color: parts[0],
        permille: parseInt(parts[1]), hp: parseInt(parts[3]),
        lives: parseInt(parts[5]), spdPct: parseInt(parts[7]),
        missPct: parseInt(parts[9])
      )
    except ValueError:
      discard

proc deriveMultiFrame(bot: Bot) =
  ## Anchors the 2-team strategy frame onto this bot's REAL multi-team home.
  ## Our own endzone mark is home and capture zone; the raid target is the
  ## enemy zone with the LARGEST horizontal offset (the diagonal twin on a
  ## corners board, a side arm on a plus board) so the engine's east-west
  ## advance math never degenerates on a north/south home. Pedestal
  ## sightings refine the anchors later — pedestals are never fogged. No-op
  ## on 2-team boards: those keep the tuned mirrored-arena constants.
  MultiReady = false
  if GameTeams <= 2:
    return
  var
    home: Vec
    haveHome = false
  for z in EndzoneMarks:
    if z.color == bot.myColor:
      home = vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5)
      haveHome = true
      break
  if not haveHome:
    return                     # marker missing: stay on the classic frame
  var
    target: Vec
    targetColor = ""
    bestDx = -1.0
  for z in EndzoneMarks:
    if z.color == bot.myColor:
      continue
    let
      c = vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5)
      dx = abs(c.x - home.x)
    if dx > bestDx:
      bestDx = dx
      target = c
      targetColor = z.color
  if targetColor.len == 0:
    return
  MultiHome = home
  MultiCapture = home
  MultiTarget = target
  MultiHomeSign = (if home.x >= target.x: 1.0 else: -1.0)
  bot.targetColor = targetColor
  bot.targetFlagSeen = bot.tick
  MultiReady = true

proc buildNavGrid(bot: Bot, client: ProtocolClient) {.measure.} =
  ## Erodes the pixel walkability mask into a footprint-safe nav grid, then
  ## derives the cover model (cover cells, overwatch post, defender choke).
  adoptMapSize(client)
  adoptGameParams(client)
  adoptEndzones(client)
  adoptHandicaps(client)
  # Multi-team boards deal the seats round GameTeams colors (slot mod
  # teams) — the startup red/blue parity guess is wrong for half the seats
  # there, and a wrong color makes every label scan blind (the "statues on
  # green and yellow" bug). Re-deal the color and the per-team seat role now
  # that the team count is stated; the self marker confirms (or corrects)
  # the color on the first alive frame.
  if GameTeams > 2:
    if not bot.colorLocked:
      bot.myColor = TeamColorNames[bot.slot mod GameTeams]
    bot.role = roleForSeat(clamp(bot.slot div GameTeams, 0, 7), bot.team)
  bot.deriveMultiFrame()
  artEvent(bot.tick, "game_params",
    %*{"teams": GameTeams, "mapW": MapW, "mapH": MapH,
       "color": bot.myColor})
  block endzoneTelemetry:
    var zones = newJArray()
    for z in EndzoneMarks:
      zones.add %*{"color": z.color, "shape": z.shape,
        "x0": z.x0, "y0": z.y0, "x1": z.x1, "y1": z.y1}
    # artEvent merges `fields` with pairs(), which ASSERTS JObject — a bare
    # JArray is an AssertionDefect that escapes `guarded` (Defects are not
    # CatchableError) and killed every bot at nav-grid build.
    artEvent(bot.tick, "endzones", %*{"zones": zones})
  bot.cellWalkable = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      bot.cellWalkable[cy * GridW + cx] = client.footprintFits(
        cx * NavCell + NavCell div 2, cy * NavCell + NavCell div 2)
  bot.coverCell = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.cellWalkable[c]:
        continue
      block adjacency:
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            if dx == 0 and dy == 0:
              continue
            let
              nx = cx + dx
              ny = cy + dy
            if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
              continue
            if not bot.cellWalkable[ny * GridW + nx]:
              bot.coverCell[c] = true
              break adjacency
  bot.exposure = newSeq[bool](GridW * GridH)
  bot.navDist = newSeq[int32](GridW * GridH)
  bot.navGoal = -1
  bot.pickPost(client)
  bot.findEnemyPosts(client)
  bot.chokeHold = bot.snapToCover(chokeSpot(bot.team))
  bot.navBuilt = true

const NavNeighbors = [
  (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)
]

proc rebuildExposure(bot: Bot, client: ProtocolClient) =
  ## Marks nav cells the freshest remembered enemies — plus the mirrored
  ## enemy sniper posts, which are stationary hidden threats all game —
  ## could shoot into (inside gun range with a coarsely-clear line). Used as
  ## a soft path cost.
  for i in 0 ..< bot.exposure.len:
    bot.exposure[i] = false
  var
    threatSpots: seq[Vec] = bot.enemyPosts
    threats = 0
  for t in bot.enemies:                  # already sorted freshest-first
    if threats >= ExposureThreats or bot.tick - t.lastSeen > ExposureTrackTtl:
      break
    inc threats
    threatSpots.add(t.pos)
  for spot in threatSpots:
    let
      x0 = max(0, int(spot.x - ExposureRange) div NavCell)
      x1 = min(GridW - 1, int(spot.x + ExposureRange) div NavCell)
      y0 = max(0, int(spot.y - ExposureRange) div NavCell)
      y1 = min(GridH - 1, int(spot.y + ExposureRange) div NavCell)
    for cy in y0 .. y1:
      for cx in x0 .. x1:
        let c = cy * GridW + cx
        if bot.exposure[c] or not bot.cellWalkable[c]:
          continue
        let p = cellCenter(c)
        if dist(p, spot) <= ExposureRange and
            rayClearCoarse(client, spot, p, 8.0):
          bot.exposure[c] = true

proc computeField(bot: Bot, client: ProtocolClient, goal: int) =
  ## Cost field (Dijkstra) over the nav grid toward one goal cell. Steps cost
  ## StepCost/DiagCost and entering a threat-exposed cell adds ExposedCost, so
  ## paths prefer segments that keep obstacles between us and known enemies.
  ## Diagonal steps require both orthogonal neighbors open (no corner cuts).
  bot.rebuildExposure(client)
  for i in 0 ..< bot.navDist.len:
    bot.navDist[i] = -1
  var heap = initHeapQueue[(int32, int32)]()
  bot.navDist[goal] = 0
  heap.push((0'i32, int32(goal)))
  while heap.len > 0:
    let
      (dcur, cur32) = heap.pop()
      cur = int(cur32)
    if dcur > bot.navDist[cur]:
      continue
    let
      cx = cur mod GridW
      cy = cur div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      var step = (if dx != 0 and dy != 0: DiagCost else: StepCost)
      if bot.exposure[nc]:
        step += ExposedCost
      let nd = bot.navDist[cur] + step
      if bot.navDist[nc] < 0 or nd < bot.navDist[nc]:
        bot.navDist[nc] = nd
        heap.push((nd, int32(nc)))

proc gridRayClear(bot: Bot, a, b: Vec): bool =
  ## True when the eroded nav grid is open along the whole segment.
  let
    d = b - a
    steps = int(d.len() / 4.0) + 1
  for s in 0 .. steps:
    let p = a + d * (float(s) / float(steps))
    if not bot.cellWalkable[cellOf(p)]:
      return false
  true

proc navSteer(bot: Bot, client: ProtocolClient, me, target: Vec): Vec =
  ## Direction along the cost-field path toward `target`, with waypoint
  ## lookahead. Falls back to a beeline before the grid exists or when
  ## unreachable.
  if not bot.navBuilt:
    return target - me
  let goal = bot.nearestOpenCell(cellOf(target))
  if goal != bot.navGoal or bot.tick - bot.navStamp >= RepathTicks:
    bot.computeField(client, goal)
    bot.navGoal = goal
    bot.navStamp = bot.tick
  let start = bot.nearestOpenCell(cellOf(me))
  if bot.navDist[start] < 0:
    return target - me
  if bot.navDist[start] == 0:
    return target - me
  var
    node = start
    waypoint = cellCenter(start)
    haveClear = false
  for _ in 0 ..< LookaheadCells:
    var next = -1
    var bestD = bot.navDist[node]
    let
      cx = node mod GridW
      cy = node div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if bot.navDist[nc] < 0 or bot.navDist[nc] >= bestD:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      bestD = bot.navDist[nc]
      next = nc
    if next < 0:
      break
    node = next
    if bot.gridRayClear(me, cellCenter(node)):
      waypoint = cellCenter(node)
      haveClear = true
    else:
      break
  if not haveClear:
    waypoint = cellCenter(node)
  waypoint - me

proc findDuckCell(bot: Bot, client: ProtocolClient, me, threat: Vec): int =
  ## The nearest directly-reachable cell around us whose center the threat
  ## cannot see; -1 when no nearby cover breaks the line.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -DuckSearchCells .. DuckSearchCells:
    for dx in -DuckSearchCells .. DuckSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not bot.gridRayClear(me, p):
        continue
      if client.pixelRayClear(p, threat):
        continue                          # the threat can still see this cell
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc findPeekCell(bot: Bot, client: ProtocolClient, me, aim: Vec): int =
  ## The nearest directly-reachable cell that opens a firing line to `aim`
  ## within gun range; -1 when no sidestep grants the shot.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -PeekSearchCells .. PeekSearchCells:
    for dx in -PeekSearchCells .. PeekSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if dist(p, aim) > FireRange or not bot.gridRayClear(me, p):
        continue
      if not client.pixelRayClear(p, aim):
        continue
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc updateTracks(bot: Bot, tracks: var seq[Track], seen: seq[Actor]) =
  ## Matches this frame's sightings to remembered tracks and prunes stale
  ## ones. Velocity is a blended px/tick estimate used to lead shots.
  var claimed = newSeq[bool](tracks.len)
  for a in seen:
    var
      best = -1
      bestD = TrackMatchDist
    for i in 0 ..< tracks.len:
      if claimed[i]:
        continue
      let d = dist(tracks[i].pos, a.pos)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      let
        dt = float(max(1, bot.tick - tracks[best].lastSeen))
        v = (a.pos - tracks[best].pos) * (1.0 / dt)
      tracks[best].vel = vec(
        clamp((tracks[best].vel.x + v.x) * 0.5, -3.0, 3.0),
        clamp((tracks[best].vel.y + v.y) * 0.5, -3.0, 3.0)
      )
      tracks[best].pos = a.pos
      tracks[best].facingRight = a.facingRight
      tracks[best].lastSeen = bot.tick
      tracks[best].synthetic = false
      if a.hp > 0:
        tracks[best].hp = a.hp
      claimed[best] = true
    else:
      tracks.add(Track(
        pos: a.pos, lastSeen: bot.tick, facingRight: a.facingRight, hp: a.hp))
      claimed.add(true)
  var kept: seq[Track]
  for t in tracks:
    # -d:campNade: a stationary track is a CAMPER and his position outlives
    # the normal memory window — keep it around long enough to lob at. Every
    # combat consumer (gun, exposure, serpentine) filters by its own age
    # window, so the longer retention only feeds the grenade planner.
    let ttl =
      when defined(campNade):
        (if len(t.vel) < NadeCampSpeed: NadeCampTicks else: TrackTtl)
      else:
        TrackTtl
    if bot.tick - t.lastSeen <= ttl:
      kept.add(t)
  kept.sort(proc(a, b: Track): int = cmp(b.lastSeen, a.lastSeen))
  if kept.len > TrackCap:                # there are only eight real players
    kept.setLen(TrackCap)
  tracks = kept

proc trackPickups(
  positions: var seq[Vec],
  absentAt: var seq[int],
  seen: seq[Vec],
  me: Vec,
  tick: int,
) =
  ## Shared fog-honest pickup memory: learn spots on sight, mark a spot
  ## taken only when we pass close enough that the bubble would show it,
  ## and believe it restocked once its respawn timer has elapsed.
  for p in seen:
    var known = false
    for i in 0 ..< positions.len:
      if dist(positions[i], p) < 24.0:
        known = true
        absentAt[i] = -1
    if not known:
      positions.add(p)
      absentAt.add(-1)
  for i in 0 ..< positions.len:
    if dist(positions[i], me) <= MedKitSeenClear and absentAt[i] < 0:
      var present = false
      for p in seen:
        if dist(positions[i], p) < 24.0:
          present = true
      if not present:
        absentAt[i] = tick

proc pickupAvailable(absentAt: seq[int], i, tick: int): bool =
  absentAt[i] < 0 or tick - absentAt[i] > PickupRespawn + 48

proc kitAvailable(bot: Bot, i: int): bool =
  ## Whether a discovered med kit spot is believed stocked right now: never
  ## seen empty, or its 30s respawn has elapsed since we saw it taken.
  bot.kitAbsentAt[i] < 0 or bot.tick - bot.kitAbsentAt[i] > MedKitRespawn + 48

proc bestKitDetour(bot: Bot, me, dest: Vec, budget: float): int =
  ## The stocked kit spot whose me->kit->dest detour costs the fewest extra
  ## path px over going straight to dest; -1 when none fits the budget.
  result = -1
  var best = budget
  for i in 0 ..< bot.kitPos.len:
    if not bot.kitAvailable(i):
      continue
    let cost = dist(me, bot.kitPos[i]) + dist(bot.kitPos[i], dest) - dist(me, dest)
    if cost < best:
      best = cost
      result = i

proc resetTransient(bot: Bot) =
  ## Drops per-game memory between rounds (lobby / game-over interstitials).
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.nadeCharge = 0
  bot.mateFixTick = 0
  bot.hp = MaxHp
  for i in 0 ..< bot.kitAbsentAt.len:
    bot.kitAbsentAt[i] = -1              # both kits restock at game start
  for i in 0 ..< bot.plasmaAbsentAt.len:
    bot.plasmaAbsentAt[i] = -1
  for i in 0 ..< bot.shieldAbsentAt.len:
    bot.shieldAbsentAt[i] = -1
  bot.shoutWant = ""
  bot.lastShoutTick = 0
  bot.colorLocked = false      # re-earn the color lock from the next game's
                               # self marker (the slot-dealt guess persists)
  bot.comebackWant = ""
  bot.corpseCount = 0
  bot.killMoodUntil = 0
  bot.lastEnemyShout = ""
  bot.lastComebackReq = 0
  bot.wasMateCarry = false
  bot.tripping = false
  bot.carrierSeen = -100_000
  bot.lastEnemySeen = bot.tick
  bot.gameStart = bot.tick
  bot.firedLast = false
  bot.estAim = spawnAim(bot.team)
  bot.rotSign = 0
  bot.wasDead = false
  bot.scanHigh = false
  bot.stuckTicks = 0
  bot.jinkUntil = 0
  bot.behindLines = false
  bot.navGoal = -1

proc scanAim(bot: Bot, watch: Vec): int =
  ## The scan-sweep aim while holding a position: rake the vision cone back
  ## and forth across the arc around the `watch` heading with real rotation.
  ## Flip the sweep direction whenever the current end is nearly reached.
  let center = bradsOf(watch)
  var goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
    AimBrads) mod AimBrads
  if abs(bradsErr(goal, bot.estAim)) <= CombatDeadband:
    bot.scanHigh = not bot.scanHigh
    goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
      AimBrads) mod AimBrads
  goal

proc safestLaneY(bot: Bot, me: Vec): float =
  ## The carrier's lane home: fewest remembered enemies AND the best cover
  ## continuity — under map-wide guns a lane whose run has no cover nearby is
  ## a shooting gallery even when it looks empty.
  var
    bestLane = LaneMid
    bestScore = 1e18
  for lane in [LaneTop, LaneMid, LaneBottom]:
    var score = abs(me.y - lane) / float(tuneCarrierLaneBiasDiv)
                                           # mild bias toward nearest lane
    for t in bot.enemies:
      let towardHome =
        if homeSign(bot.team) < 0: t.pos.x < me.x + 200
        else: t.pos.x > me.x - 200
      if towardHome and abs(t.pos.y - lane) < float(tuneCarrierLaneThreatY):
        score += 1.0
    for post in bot.enemyPosts:
      # The mirrored enemy sniper posts are standing threats on the run home
      # even when nobody has been seen there.
      if abs(post.y - lane) < float(tuneCarrierLaneThreatY):
        score += 1.0
    if bot.navBuilt:
      # Cover continuity: sample the run home along the lane and charge each
      # sample with no cover cell in its 3x3 nav neighborhood.
      let
        goalX = homeDeepX(bot.team)
        stepX = (if goalX > me.x: 32.0 else: -32.0)
      var
        x = me.x
        samples = 0
        bare = 0
      while (stepX > 0.0 and x < goalX) or (stepX < 0.0 and x > goalX):
        inc samples
        let
          c = cellOf(vec(x, lane))
          cx = c mod GridW
          cy = c div GridW
        block covered:
          for dy in -1 .. 1:
            for dx in -1 .. 1:
              let
                nx = cx + dx
                ny = cy + dy
              if nx >= 0 and ny >= 0 and nx < GridW and ny < GridH and
                  bot.coverCell[ny * GridW + nx]:
                break covered
          inc bare
        x += stepX
      if samples > 0:
        score += float(bare) / float(samples) * 2.0
    if score < bestScore:
      bestScore = score
      bestLane = lane
  bestLane

proc friendlyBlocked(bot: Bot, me, aim: Vec, enemyDist: float): bool =
  ## True when a remembered teammate could eat the shot: the bullet is a
  ## corridor hitscan (~14px half width) along the aim ray and the server
  ## kills the NEAREST player inside it, friend or foe — 8v8 puts many
  ## teammates downrange. The fire axis is the exact angle the turret would
  ## fire at right now.
  let dir = bradsDir(bradsOf(aim - me))
  for t in bot.mates:
    let age = float(bot.tick - t.lastSeen)
    if age > 36:
      continue
    let
      rel = t.pos - me
      d = rel.len()
      along = dot(rel, dir)
    if along <= 0 or d < 1e-6:
      continue
    if along >= enemyDist + 14.0:
      continue                          # beyond the target: the target dies first
    if abs(cross(rel, dir)) < CorridorHalfWidth + age * 0.35:
      return true
  false

proc decide(bot: Bot, client: ProtocolClient): uint8 {.measure.} =
  ## Core CTF policy for one frame.
  when defined(statue):
    return 0'u8                          # test dummy: stand still all game
  # Our wire color: the slot-dealt guess until the self marker — the one
  # sprite only WE ever see — confirms it. Explicit slot configs can deal
  # colors in any order, and a wrong color makes every scan below blind.
  if not bot.colorLocked:
    for i in 0 ..< max(2, GameTeams):
      let c = TeamColorNames[i]
      if client.findSelf(c).alive:
        bot.colorLocked = true
        if c != bot.myColor:
          bot.myColor = c
          bot.deriveMultiFrame()
        break
  let
    myColor = bot.myColor
    (alive, me) = client.findSelf(myColor)
  var enemyColor = "red"
    # The single color the flag-raid bookkeeping below targets: the classic
    # opponent on 2-team boards, the picked raid target on multi-team ones.
  if GameTeams > 2 and bot.targetColor.len > 0:
    enemyColor = bot.targetColor
  else:
    for i in 0 ..< max(2, GameTeams):
      if TeamColorNames[i] != myColor:
        enemyColor = TeamColorNames[i]
        break
  if not alive:
    # Dead: the view is fully fogged (only our corpse renders) and inputs
    # are ignored, so skip perception entirely.
    bot.firedLast = false
    bot.rotSign = 0
    bot.wasDead = true
    artFrame(FrameSnap(tick: bot.tick, alive: false,
      x: int(bot.lastPos.x), y: int(bot.lastPos.y), hp: 0,
      objective: "dead", action: "dead", engageDist: -1))
    return 0
  if bot.wasDead:
    # Respawned: the server points the aim back at the enemy side.
    bot.wasDead = false
    bot.estAim = spawnAim(bot.team)
  # Own aim: the engine now states it outright per frame (the `own aim
  # <brads>` HUD marker), so resync estAim to the authoritative value —
  # this caps the dead-reckoning drift at one frame gap. The per-tick
  # integration in the run loop still predicts BETWEEN frames (held rotate
  # inputs keep turning the turret server-side for every elapsed tick), and
  # remains the sole source on pre-marker engines where the scan misses.
  let statedAim = client.ownAimBrads()
  if statedAim >= 0:
    bot.estAim = statedAim
  # Plasma arcs and shields share the endzone back columns (inset 50)
  # but are vertically SEPARATED: spray cans in the top half (quarter height),
  # shields in the bottom half (three-quarter height). Seed the spots up
  # front (they are deterministic; the fog would otherwise hide them until
  # we are already on top of them), then let sightings refine the nudged
  # positions.
  if bot.plasmaPos.len == 0:
    for spot in [vec(50.0, float(MapH div 4)),
                 vec(float(MapW) - 50.0, float(MapH div 4))]:
      bot.plasmaPos.add(spot)
      bot.plasmaAbsentAt.add(-1)
    for spot in [vec(50.0, float(3 * MapH div 4)),
                 vec(float(MapW) - 50.0, float(3 * MapH div 4))]:
      bot.shieldPos.add(spot)
      bot.shieldAbsentAt.add(-1)
  var plasmaSeen, shieldSeen: seq[Vec]
  for o in client.spriteObjectsWithLabel(LabelSprayCan):
    plasmaSeen.add(client.mapPos(o))
  for o in client.spriteObjectsWithLabel(LabelShield):
    shieldSeen.add(client.mapPos(o))
  trackPickups(bot.plasmaPos, bot.plasmaAbsentAt, plasmaSeen, me, bot.tick)
  trackPickups(bot.shieldPos, bot.shieldAbsentAt, shieldSeen, me, bot.tick)
  # Own carry state: the carried markers float over their carrier, and a
  # shield carrier's HUD reads 6 hp (the marker is the fallback).
  var hasPlasma = false
  for o in client.spriteObjectsWithLabel(LabelSprayCanCarried):
    if dist(client.mapPos(o), me) <= 30.0:
      hasPlasma = true
      break
  var hasShield = bot.hp > MaxHp
  if not hasShield:
    for o in client.spriteObjectsWithLabel(LabelShieldCarried):
      if dist(client.mapPos(o), me) <= 30.0:
        hasShield = true
        break
  let
    shotReady = client.spriteObjectsWithLabel(LabelFireIcon).len > 0 and
      not hasPlasma                      # the spray can replaces the gun; a shield
                                         # only slows it (3x cooldown)
    seenMates = client.actorsFor(myColor)
  var seenEnemies: seq[Actor]
  # EVERY other color is a combat threat on a free-for-all board, not just
  # the flag-raid target — track them all.
  for i in 0 ..< max(2, GameTeams):
    let c = TeamColorNames[i]
    if c != myColor:
      seenEnemies.add(client.actorsFor(c))
  bot.updateTracks(bot.enemies, seenEnemies)
  bot.updateTracks(bot.mates, seenMates)
  if seenEnemies.len > 0:
    bot.lastEnemySeen = bot.tick

  # Flag bookkeeping (two flags; a carried flag rides its carrier's exact
  # position, and is only as visible as that carrier). The enemy flag can only
  # be carried by OUR team, but mates fog like enemies, so its sprite fully
  # describes our attack only on its pedestal or on ME — a mate's carry shows
  # just while that mate is in our cone, and an absent enemy flag means a
  # fogged mate is running it home. Our own flag can only be carried by the
  # enemy: on its pedestal it is safe, visible off-pedestal is a live thief
  # fix, and ABSENT means a fogged thief is running it toward its home edge.
  var
    iCarry = false
    mateCarry = false
    mateCarryPos: Vec
  let
    # Since the 0.7.8 renderer restore the objective is labeled a FLAG again,
    # split into distinct pedestal/carried sprites: "<color> flag planted" is
    # the always-visible pedestal banner, "<color> flag" the carried banner
    # centered exactly on its carrier (fogged with the carrier).
    enemyPlanted = client.spriteObjectsWithLabel(labelFlagPlanted(enemyColor))
    enemyFlags = client.spriteObjectsWithLabel(labelFlag(enemyColor))
    ownPlanted = client.spriteObjectsWithLabel(labelFlagPlanted(myColor))
    ownFlags = client.spriteObjectsWithLabel(labelFlag(myColor))
  if multiFrameOn():
    # Pedestals are never fogged: adopt their exact positions over the
    # endzone-box approximations.
    if ownPlanted.len > 0:
      MultiHome = client.mapPos(ownPlanted[0])
    if enemyPlanted.len > 0:
      MultiTarget = client.mapPos(enemyPlanted[0])
    if enemyPlanted.len > 0 or enemyFlags.len > 0:
      bot.targetFlagSeen = bot.tick
    elif bot.tick - bot.targetFlagSeen > 600:
      # The target's flag has been off the board a long while. A captured
      # heart retires for good (GV32/GV33), and a pedestal is never fogged —
      # so either the target team is gone or its heart is riding fogged
      # carriers endlessly. Re-anchor the raid on a pedestal that still
      # stands (largest horizontal offset first, same rule as the deal).
      var bestDx = -1.0
      for i in 0 ..< GameTeams:
        let c = TeamColorNames[i]
        if c == myColor or c == bot.targetColor:
          continue
        let planted = client.spriteObjectsWithLabel(labelFlagPlanted(c))
        if planted.len == 0:
          continue
        let p = client.mapPos(planted[0])
        if abs(p.x - MultiHome.x) > bestDx:
          bestDx = abs(p.x - MultiHome.x)
          bot.targetColor = c
          MultiTarget = p
      if bestDx >= 0.0:
        MultiHomeSign = (if MultiHome.x >= MultiTarget.x: 1.0 else: -1.0)
        bot.targetFlagSeen = bot.tick
  let
    stealTarget = flagHome(enemy(bot.team))  # the enemy pedestal is static
    ownHome = flagHome(bot.team)
  # Own hit points from the HUD "lives <hp>hp x<lives>" text sprite.
  for o in client.spriteObjects():
    if o.label.startsWith(LabelPrefixLives):
      let text = o.label[LabelPrefixLives.len .. ^1]
      let cut = text.find("hp")
      if cut > 0:
        try:
          # Unclamped past MaxHp: a shield carrier reads 6 hp on the HUD.
          bot.hp = clamp(parseInt(text[0 ..< cut]), 1, 9)
        except ValueError:
          discard
      break

  # Med kits: learn the two center-line spots on sight; presence is
  # fog-gated, so an empty spot only counts as TAKEN when we pass close
  # enough that the bubble would show it.
  var kitSeen: seq[Vec]
  for o in client.spriteObjectsWithLabel(LabelMedKit):
    kitSeen.add(client.mapPos(o))
  for p in kitSeen:
    var known = false
    for i in 0 ..< bot.kitPos.len:
      if dist(bot.kitPos[i], p) < 24.0:
        known = true
        bot.kitAbsentAt[i] = -1
    if not known:
      bot.kitPos.add(p)
      bot.kitAbsentAt.add(-1)
  for i in 0 ..< bot.kitPos.len:
    if dist(bot.kitPos[i], me) <= MedKitSeenClear and bot.kitAbsentAt[i] < 0:
      var present = false
      for p in kitSeen:
        if dist(bot.kitPos[i], p) < 24.0:
          present = true
      if not present:
        bot.kitAbsentAt[i] = bot.tick

  when defined(taunt):
    # Taunt pipeline, all non-blocking: drain whatever the Bedrock worker
    # produced, notice new ENEMY shouts (queue a comeback), and open a short
    # taunt window when a corpse appears right after we fired. The worker
    # thread owns every HTTP call — this block only moves strings around.
    pollTaunts(bot.tauntBank, bot.comebackWant)
    for o in client.spriteObjects():
      if o.label.startsWith(labelShoutPrefix(enemyColor)):
        if o.label != bot.lastEnemyShout:
          bot.lastEnemyShout = o.label
          if bot.tick - bot.lastComebackReq >= 240:
            bot.lastComebackReq = bot.tick
            let sep = o.label.rfind(": ")
            if sep > 0:
              requestComeback(o.label[sep + 2 .. ^1])
        break
    var corpses = 0
    for facing in [LabelSideRight, LabelSideLeft]:
      corpses += client.spriteObjectsWithLabel(
        labelCorpse(enemyColor, facing)).len
    if corpses > bot.corpseCount and bot.firedLast:
      bot.killMoodUntil = bot.tick + 72
    bot.corpseCount = corpses

  when defined(shoutCoord):
    # Shout intel (0.7.5): teammates broadcast quantized fixes as 10-char
    # shouts — "C<cx> <cy>" is our carrier's own position, "T<cx> <cy>" a
    # fresh fix on the enemy thief running OUR heart. The payload carries the
    # exact quantized position; the bubble's jittered coordinates are ignored.
    for o in client.spriteObjects():
      if not o.label.startsWith(labelShoutPrefix(myColor)):
        continue
      bot.lastTeamShoutSeen = bot.tick      # spacing signal for peace lines
      let sep = o.label.rfind(": ")
      if sep < 0:
        continue
      let text = o.label[sep + 2 .. ^1]
      when defined(zonePhalanx):
        # "H<1|2|3>": a lane pair is outnumbered; floater and scout retask.
        if text.len >= 2 and text[0] == 'H' and text[1] in {'1', '2', '3'}:
          bot.helpLane = ord(text[1]) - ord('0')
          bot.helpUntil = bot.tick + 320
          continue
      when defined(siege):
        # Captain's siege orders: "B<lane>" = bombard the vertical (grenadiers
        # blast the hidden pockets behind cover), "A<lane>" = advance and take
        # it. Everyone syncs off the same shout — including the captain, whose
        # own bubble drives its phase machine.
        if text.len >= 2 and text[0] in {'B', 'A'} and text[1] in {'1', '2', '3'}:
          bot.siegeLane = ord(text[1]) - ord('0')
          if text[0] == 'B':
            bot.siegePhase = 1
            bot.siegePhaseUntil = bot.tick + SiegeBarrageTicks
            if bot.siegeFront <= 0.0:
              bot.siegeFront = HoldFrontCap
          else:
            bot.siegePhase = 2
            bot.siegePhaseUntil = bot.tick + SiegeAdvanceTicks
            bot.siegeFront = min(max(bot.siegeFront, HoldFrontCap) + SiegeStep,
              float(MapW) - 300.0)
          continue
      if text.len < 4 or text[0] notin {'C', 'T', 'E', 'G'}:
        continue
      let parts = text[1 .. ^1].split(' ')
      if parts.len != 2:
        continue
      var cx, cy: int
      try:
        cx = parseInt(parts[0])
        cy = parseInt(parts[1])
      except ValueError:
        continue
      let p = vec(float(cx * 8 + 4), float(cy * 8 + 4))
      when defined(nadeRelay):
        if text[0] == 'G':
          # A mate took the grenade at spot p: the sim refills a taken corner
          # after 5s (GrenadeRespawnTicks), so start the shared respawn clock.
          # Also teaches spots this bot has never had eyes on (fog).
          var known = false
          for i in 0 ..< bot.nadeSpotPos.len:
            if dist(bot.nadeSpotPos[i], p) < 24.0:
              bot.nadeSpotEta[i] = bot.tick + 126
              known = true
              break
          if not known:
            bot.nadeSpotPos.add p
            bot.nadeSpotEta.add bot.tick + 126
          continue
      if text[0] == 'E':
        when defined(zonePhalanx):
          # Scout sighting: feed shared vision into the track table so the
          # pair guns pre-aim before the runner enters their cones. Slightly
          # aged so a bot's own eyes always outrank the relay. Own shouts
          # (origin on top of us) are skipped, and an E never refreshes a
          # synthetic track — otherwise the relay echoes itself into a
          # permanently-fresh phantom (probe scar: "E37 10" forever).
          let shoutOrigin = vec(
            float(o.x + o.width div 2 + client.mapCameraX),
            float(o.y + o.height div 2 + client.mapCameraY))
          if dist(shoutOrigin, me) > 24.0:
            var dup = false
            for t in bot.enemies.mitems:
              if dist(t.pos, p) < 70.0:
                dup = true
                if not t.synthetic and bot.tick - t.lastSeen > 10:
                  discard  # fresh real track outranks the relay
                elif not t.synthetic:
                  discard
                break
            if not dup:
              bot.enemies.add(Track(pos: p, lastSeen: bot.tick - 6,
                synthetic: true, facingRight: p.x < float(CenterX), hp: MaxHp))
        continue
      if text[0] == 'C':
        # Fresher than any dead-reckoned estimate: pin the escort fix here.
        bot.mateFixPos = p
        bot.mateFixTick = bot.tick
      else:
        when defined(shoutThief):
          # Thief fix: adopt unless we have our own fresher eyes on it.
          # (Isolated behind its own define: broadcast convergence pulls
          # defenders across watched ground — measured attrition risk.)
          if bot.tick - bot.carrierSeen > 8:
            bot.carrierPos = p
            bot.carrierVel = vec(0, 0)
            bot.carrierSeen = bot.tick
  if enemyPlanted.len > 0:
    discard                              # enemy flag sits home: nobody carries
  elif enemyFlags.len > 0:
    # Carried banner in sight, centered exactly on its carrier. "Am I the
    # carrier" is "is the flag on ME and on nobody else" — a visible mate
    # closer to it than us means the mate is the carrier.
    let fp = client.mapPos(enemyFlags[0])
    var mateCloser = false
    let dSelf = dist(fp, me)
    for t in bot.mates:
      if bot.tick - t.lastSeen <= 2 and dist(t.pos, fp) < dSelf:
        mateCloser = true
        break
    if dSelf <= CarrySelfRadius and not mateCloser:
      iCarry = true
    else:
      mateCarry = true                   # only a teammate can be carrying it
      mateCarryPos = fp
      bot.mateFixPos = fp
      bot.mateFixTick = bot.tick
  else:
    # No planted banner and no carried banner in the frame: the flag is off
    # its pedestal on a FOGGED carrier — and only OUR team can carry it, so a
    # teammate is running it home right now even though we cannot see it.
    # Without this inference the whole wave keeps pressing an empty pedestal
    # instead of covering the run. Escort a dead-reckoned fix: the last
    # sighting (or the pedestal it was lifted from) advanced homeward at
    # carrier speed.
    mateCarry = true
    var est =
      if bot.mateFixTick > 0: bot.mateFixPos
      else: stealTarget
    let elapsed = float(bot.tick - max(bot.mateFixTick, bot.gameStart))
    est.x += homeSign(bot.team) * min(
      abs(ownHome.x - est.x),
      elapsed * CarrierEstSpeed
    )
    mateCarryPos = est
  when defined(carryDebug):
    if bot.tick mod 50 == 0 and (iCarry or mateCarry):
      var fpS = "none"
      if enemyFlags.len > 0:
        let fp = client.mapPos(enemyFlags[0])
        fpS = $int(fp.x) & "," & $int(fp.y) & " d=" & $int(dist(fp, me))
      echo "CARRY t=", bot.tick, " slot=", bot.slot, " role=", bot.role,
        " iCarry=", iCarry, " mateCarry=", mateCarry,
        " me=", int(me.x), ",", int(me.y), " fp=", fpS,
        " mateCarryPos=", int(mateCarryPos.x), ",", int(mateCarryPos.y)
      flushFile(stdout)
  var ownStolen = ownPlanted.len == 0
  # -d:thiefCommit (daveey, R1693 review): a thief in fog is STILL running our
  # flag — the 40-tick fix window meant one duck behind cover dissolved the
  # whole chase and everyone strolled back to posts while the flag walked
  # home. Commit to the dead-reckoned route for ThiefCommitTtl instead; the
  # only bots excused are the ones escorting OUR live carry (the race is the
  # v16/v17 scar: never trade our own conversion for defense).
  let thiefChaseTtl =
    when defined(thiefCommit): ThiefCommitTtl else: ThiefFixTtl
  let raceExempt =
    when defined(thiefCommit):
      mateCarry and dist(me, mateCarryPos) < 250.0
    else:
      false
  # Counter-punch: loss telemetry says lost games are 0-steal games — the
  # wave never converts while the enemy penetrates 3-4 times and wins on
  # capture or the lives tiebreak. Deep into a game with that exact shape
  # (they have stolen, we never have), attacking is feeding: fall back to
  # home-side stations, keep full gun range, punish every thief run, and
  # take the timeout tiebreak on lives instead. The late all-in push still
  # fires past LatePushTick, so a tied endgame still plays for the capture.
  if iCarry or mateCarry:
    bot.everStoleTheirs = true
  if ownStolen:
    bot.everLostOurs = true
  when defined(counterPunch):
    let counterPunch = bot.tick - bot.gameStart > CounterPunchTick and
      bot.everLostOurs and not bot.everStoleTheirs
  else:
    let counterPunch = false
  when defined(zonePhalanx):
    let phalanxOn = true
  else:
    let phalanxOn = false
  var sawThief = false
  if ownPlanted.len > 0:
    bot.carrierSeen = -100_000           # our flag is safely home
  elif ownFlags.len > 0:
    # The thief holding our flag is inside our vision: take a fresh fix.
    let fp = client.mapPos(ownFlags[0])
    sawThief = true
    bot.carrierPos = fp
    bot.carrierVel = vec(0, 0)
    for t in bot.enemies:
      if dist(t.pos, fp) <= 8:
        bot.carrierVel = t.vel
        break
    bot.carrierSeen = bot.tick
  when defined(stolenOverwatchGuards):
    let stolenGuard = bot.role == HomeDefender or bot.role == Overwatch
  else:
    let stolenGuard = bot.role == HomeDefender

  when defined(shoutCoord):
    # Broadcast intel worth its position leak (shouts are heard by enemies
    # within ~247px too, but a carrier is already hunted and a defender's
    # post is no secret). Carrier heartbeat beats thief fix; own eyes only —
    # re-broadcasting a heard fix would echo it around the map forever.
    if bot.tick - bot.lastShoutTick >= 26:
      if iCarry:
        bot.shoutWant = "C" & $(int(me.x) div 8) & " " & $(int(me.y) div 8)
        bot.lastShoutTick = bot.tick
      elif sawThief and defined(shoutThief):
        bot.shoutWant = "T" & $(int(bot.carrierPos.x) div 8) & " " &
          $(int(bot.carrierPos.y) div 8)
        bot.lastShoutTick = bot.tick
      else:
        when defined(nadeRelay):
          if bot.nadeShoutWant.len > 0:
            bot.shoutWant = bot.nadeShoutWant
            bot.nadeShoutWant = ""
            bot.lastShoutTick = bot.tick
        when defined(siege):
          # The captain (scout seat — the comms hub) runs the siege cycle
          # against a turtled field: a quiet stalemate STARTS a siege;
          # thereafter bombard/advance alternate on their own clock even
          # through assault contact. Any flag movement ends the siege.
          if bot.everStoleTheirs or bot.everLostOurs:
            bot.siegePhase = 0
            bot.siegeFront = 0.0
          elif bot.shoutWant.len == 0 and clamp(bot.slot div 2, 0, 7) == 1 and
              not iCarry and bot.tick - bot.lastShoutTick >= 26 and
              bot.tick - bot.gameStart > StalemateTick and
              bot.tick >= bot.siegePhaseUntil:
            if bot.siegePhase == 1:
              bot.shoutWant = "A" & $bot.siegeLane
            else:
              var lane = 3           # their runners favor the bottom ground
              var freshest = -100_000
              for t in bot.enemies:
                if not t.synthetic and t.lastSeen > freshest:
                  freshest = t.lastSeen
                  lane = (if t.pos.y < float(CenterY) - 100.0: 1
                          elif t.pos.y > float(CenterY) + 100.0: 3
                          else: 2)
              bot.shoutWant = "B" & $lane
            bot.lastShoutTick = bot.tick
        when defined(targetCall):
          # Engage callout: any bot with a live close target broadcasts the
          # fix so nearby mates converge or lob a grenade at it. Rides the
          # existing E wire format — every receiver already ingests E fixes
          # into its track table. Position leak is moot mid-fight: our own
          # gunfire already rings map-wide.
          if bot.shoutWant.len == 0 and
              bot.tick - bot.lastTargetCall > TargetCallCooldown:
            for t in bot.enemies:
              if not t.synthetic and bot.tick - t.lastSeen <= 15 and
                  dist(t.pos, me) < 500.0:
                bot.shoutWant = "E" & $(int(t.pos.x) div 8) & " " &
                  $(int(t.pos.y) div 8)
                bot.lastTargetCall = bot.tick
                bot.lastShoutTick = bot.tick
                break

  when defined(zonePhalanx):
    # Phalanx comms ride the leftover budget under C/T: help calls first
    # (a lane about to break matters more than one more sighting), then the
    # scout's sighting relay.
    if bot.shoutWant.len == 0 and not iCarry:
      let pd = bot.phalanxDuty
      if pd in {pdTopA, pdTopB, pdMidA, pdMidB, pdBotA, pdBotB} and
          bot.tick - bot.lastHShout > 400:
        var near = 0
        for t in bot.enemies:
          if not t.synthetic and bot.tick - t.lastSeen <= 50 and
              dist(t.pos, me) < 420.0:
            inc near
        if near >= 3:
          bot.shoutWant = "H" & $phalanxLaneNo(pd)
          bot.lastHShout = bot.tick
      if bot.shoutWant.len == 0 and pd == pdScout and
          bot.tick - bot.lastEShout > 30:
        for t in bot.enemies:
          if not t.synthetic and bot.tick - t.lastSeen <= 20:
            bot.shoutWant = "E" & $(int(t.pos.x) div 8) & " " &
              $(int(t.pos.y) div 8)
            bot.lastEShout = bot.tick
            break
  when defined(taunt):
    # Taunts spend only LEFTOVER shout budget: never while carrying and never
    # over a gameplay shout (the carrier heartbeat always wins the 1/s slot).
    # Position leak is a non-issue at the trigger moments — a kill means we
    # just FIRED, and gunfire is already heard map-wide as a sound ring, so
    # the ~247px shout bubble tells enemies nothing new. One taunt per
    # kill/steal window; comebacks answer a heard enemy shout.
    if mateCarry and not bot.wasMateCarry:
      bot.killMoodUntil = bot.tick + 72    # a mate just lifted their heart
    bot.wasMateCarry = mateCarry
    if bot.shoutWant.len == 0 and not iCarry and
        bot.tick - bot.lastShoutTick >= 26 and
        (bot.comebackWant.len > 0 or bot.tick < bot.killMoodUntil):
      if bot.comebackWant.len > 0:
        bot.shoutWant = bot.comebackWant
        bot.comebackWant = ""
      else:
        if bot.tauntBank.len > 0:
          bot.shoutWant = bot.tauntBank[0]
          bot.tauntBank.delete(0)
        else:
          bot.shoutWant = sample(CannedTaunts)
        bot.killMoodUntil = 0              # one taunt per window
      bot.lastShoutTick = bot.tick
    # Opening greeting: the persona speaks in the first ~12s, one staggered
    # line per bot. Enemies are 800+px away then — far outside the ~247px
    # shout-audible radius — so the greeting leaks nothing (spawns are public
    # knowledge), while spectators and replays get the full peace wave. A
    # mid-game periodic pulse was REFUTED (v39: -0.35 vs h006 on paired
    # seeds — fights happen inside earshot, and each pulse is a through-fog
    # position ping plus a 26-tick delay on the next gameplay shout).
    # Spread-out persona (user spec): lines are staggered across the WHOLE
    # game — first lines land one bot at a time (~19s apart), each bot then
    # speaks at most every ~2.5min, never while a teammate bubble is up, and
    # only from QUIET ground (no live enemy track near — v39 showed mid-duel
    # speech is a through-fog position ping the RL rival converts, -0.35 on
    # paired seeds). Net effect: one peace line somewhere every ~20-30s.
    if bot.nextPeaceTick == 0:
      bot.nextPeaceTick = 200 + bot.slot * 450
    if bot.shoutWant.len == 0 and not iCarry and
        bot.tick - bot.lastShoutTick >= 26 and bot.tick >= bot.nextPeaceTick and
        bot.tick - bot.lastTeamShoutSeen > 120:
      var quiet = true
      for t in bot.enemies:
        if not t.synthetic and bot.tick - t.lastSeen <= 120 and
            dist(t.pos, me) < 400.0:
          quiet = false
          break
      if quiet:
        if bot.tauntBank.len > 0:
          bot.shoutWant = bot.tauntBank[0]
          bot.tauntBank.delete(0)
        else:
          bot.shoutWant = sample(CannedTaunts)
        bot.nextPeaceTick = bot.tick + 3600 + (bot.slot mod 4) * 210
        bot.lastShoutTick = bot.tick

  # Flank progress: sticky so lane-runners do not oscillate at the boundary.
  if bot.role in {FlankTop, FlankBottom}:
    let fwd = -homeSign(bot.team) * (me.x - float(CenterX))
    if fwd >= FlankDepth - 50.0:
      bot.behindLines = true
    elif fwd < 20.0:
      bot.behindLines = false

  # Endgame push: our flag is safe and nobody on OUR side has seen an enemy
  # for a long while deep into the game. The survivors by then are usually
  # the defensive seats, and holding their posts forever is a guaranteed
  # tiebreak stalemate — break the posts and go win by capture (the enemy
  # team pushes symmetrically, so somebody makes something happen).
  let pushOut = not ownStolen and (
    (bot.tick - bot.gameStart > PushOutMinGame and
     bot.tick - bot.lastEnemySeen > PushOutTicks) or
    # Late all-in: a timeout is a scoreless draw, so deep into a game with no
    # capture the posts are worth nothing — break them and go win. Standoffs
    # keep enemies in sight, so the quiet-field trigger above never fires
    # against a peek-duck opponent; this one is on the clock.
    bot.tick - bot.gameStart > LatePushTick or
    # Stalemate breaker (GV21): a timeout scores -1 to BOTH sides, so a game
    # where neither flag has ever moved is a mutual loss in the making. The
    # castle's whole value was winning the wait — there is nothing to win
    # anymore; break the posts early and go create a flag race.
    (when defined(siege): false else:
      (bot.tick - bot.gameStart > StalemateTick and
       (when defined(stickyBreak):
          # Sticky (R1693 decode): the one-shot breaker disarmed forever after
          # the FIRST steal attempt, so a dead carrier sent everyone back to
          # posts until LatePushTick while the timeout clock ran — the -1/-1
          # draw tax. Past StalemateTick with no flag in flight the game is
          # still heading for the mutual loss, so the posts stay broken.
          not (iCarry or mateCarry)
        else:
          # v50 quiet-field gate (ca1c580, LIVE in champion v56): the breaker
          # only arms when the field is genuinely DEAD — no enemy contact for
          # QuietForBreak ticks. Duel-heavy rivals resolve by wipe, not
          # timeout; breaking the castle early just donates ground.
          not bot.everStoleTheirs and not bot.everLostOurs and
          bot.tick - bot.lastEnemySeen > QuietForBreak)))
  )
  when defined(v57Debug):
    if pushOut and (bot.everStoleTheirs or bot.everLostOurs) and
        bot.tick - bot.gameStart in StalemateTick .. LatePushTick and
        bot.tick mod 48 == 0:
      echo "V57 stickyBreak slot=", bot.slot, " tick=", bot.tick,
        " posts stay broken (stole=", bot.everStoleTheirs,
        " lost=", bot.everLostOurs, ")"

  when defined(nadeCluster):
    if pushOut and not bot.wasPushOut:
      bot.salvoUntil = bot.tick + SalvoWindow
    bot.wasPushOut = pushOut
    # Camp memory: the combat track table forgets in ~5s (TrackTtl), which
    # is exactly wrong for cover-campers. Keep a separate long-lived store
    # of real sighting spots, deduped to ~50px, so a lob can target ground
    # an enemy held half a minute ago.
    for t in bot.enemies:
      if t.synthetic or t.lastSeen != bot.tick:
        continue
      var found = false
      for i in 0 ..< bot.campPos.len:
        if dist(bot.campPos[i], t.pos) < 50.0:
          bot.campPos[i] = t.pos
          bot.campSeen[i] = bot.tick
          found = true
          break
      if not found:
        if bot.campPos.len >= 16:
          var oldest = 0
          for i in 1 ..< bot.campPos.len:
            if bot.campSeen[i] < bot.campSeen[oldest]: oldest = i
          bot.campPos.delete(oldest)
          bot.campSeen.delete(oldest)
        bot.campPos.add t.pos
        bot.campSeen.add bot.tick

  # Movement target from role and flag situation. `objMode` names the branch
  # for the artifact telemetry (see baseline/artlog.nim).
  var target: Vec
  var objMode = "attack"
  if iCarry:
    objMode = "carry"
    # Run the stolen enemy flag home along the emptiest lane; the exposure
    # cost in the path field keeps the route hugging cover past remembered
    # enemies.
    let
      pocket = flagHome(enemy(bot.team))
      laneY = bot.safestLaneY(me)
    if abs(me.x - pocket.x) < 60.0 and abs(me.y - laneY) > 70.0:
      # Bug out of the pocket VERTICALLY first: every kill respawns an
      # armed enemy at this pedestal whose spawn aim points
      # along the east-west axis — pure-vertical movement exits that cone
      # fastest, then the border lane runs home outside it.
      target = vec(pocket.x, laneY)
    else:
      # Classic boards run the border lane home and cut in at the capture
      # column; on a multi-team board the zone can sit at ANY y (corner or
      # arm), so the run targets the stated zone itself.
      target =
        if multiFrameOn(): MultiCapture
        else: vec(homeDeepX(bot.team), laneY)
    # A hurt carrier detours through a stocked med kit on the way home: the
    # run crosses the center line anyway, kits are hurt-only pickups (a
    # healthy escort cannot waste one), and a full-heal carrier survives
    # pocket exits and mid crossings that kill a 1 hp one.
    if bot.hp < MaxHp:
      let kit = bot.bestKitDetour(me, target, MedKitCarrierBudget)
      if kit >= 0:
        target = bot.kitPos[kit]
  elif ownStolen and not raceExempt and (stolenGuard or
      bot.tick - bot.carrierSeen <= thiefChaseTtl):
    # An enemy is RUNNING OUR FLAG: with a fresh fix (own eyes or a mate's
    # "T" shout), EVERY role drops what it is doing and converges on the
    # thief's predicted route — an enemy capture ends the episode against
    # us, so nothing we were otherwise doing outranks the intercept. Without
    # a fix, only the back line guards the crossing lanes: the thief is
    # fogged but MUST cross mid toward its home edge, so the defender holds
    # the lane nearest the last fix and sweeps its vision — reacquisition
    # takes eyes, not magic.
    when defined(v57Debug):
      if bot.tick - bot.carrierSeen in (ThiefFixTtl + 1) .. thiefChaseTtl and
          bot.tick mod 24 == 0:
        echo "V57 thiefCommit slot=", bot.slot, " tick=", bot.tick,
          " chasing on stale fix age=", bot.tick - bot.carrierSeen
    if bot.tick - bot.carrierSeen <= thiefChaseTtl:
      # Converge on the thief's predicted path toward the enemy capture edge.
      objMode = "thief_hunt"
      var predicted = bot.carrierPos +
        bot.carrierVel * float(tuneThiefLeadTicks + bot.tick - bot.carrierSeen)
      predicted.x += -homeSign(bot.team) * 40.0
      target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                   clamp(predicted.y, 20.0, float(MapH - 20)))
    else:
      objMode = "thief_guard"
      var laneY = LaneMid
      if bot.carrierSeen > -100_000:
        var bestD = 1e18
        for lane in [LaneTop, LaneMid, LaneBottom]:
          if abs(bot.carrierPos.y - lane) < bestD:
            bestD = abs(bot.carrierPos.y - lane)
            laneY = lane
      target = vec(float(CenterX) - homeSign(bot.team) * 60.0, laneY)
  elif mateCarry:
    objMode = "escort"
    case bot.role
    of MidTop, FlankTop:
      target = mateCarryPos + vec(homeSign(bot.team) * 46.0, -30.0)
    of MidBottom, FlankBottom:
      # Rear guard: sit between the carrier and the enemy pocket it just
      # robbed — respawners chase from there, and the gun kills the NEAREST
      # player in the cone, so a body on the ray shields the carrier.
      target = mateCarryPos + vec(
        -homeSign(bot.team) * 42.0,
        (if bot.role == MidBottom: 22.0 else: -22.0)
      )
    of MidGuard:
      # Screen the carrier from the nearest remembered threat.
      var threat = -1
      var threatD = 1e18
      for i in 0 ..< bot.enemies.len:
        let d = dist(bot.enemies[i].pos, mateCarryPos)
        if d < threatD:
          threatD = d
          threat = i
      if threat >= 0:
        target = mateCarryPos + norm(bot.enemies[threat].pos - mateCarryPos) * 30.0
      else:
        target = mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of Overwatch:
      when defined(swarm):
        # Only 2-3 of our agents exist: a completed capture ends the episode,
        # so even the back line escorts the run home.
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, 24.0)
      else:
        # The posts already overwatch the carrier's retreat across mid.
        target =
          if bot.postReady: bot.postHold
          else: mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of HomeDefender:
      when defined(swarm):
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, -24.0)
      else:
        target = bot.chokeHold
  elif phalanxOn and not pushOut:
   when defined(zonePhalanx):
     # Zone phalanx: shield scout spots forward and relays sightings, three
     # staggered pairs hold the lanes at a slowly advancing front (freeze on
     # contact — never trade cover for ground while a runner is tracked),
     # the floater answers H-shouts. Steal conversion comes from the late
     # push, which overrides this whole branch via pushOut.
     let
       gameTick = bot.tick - bot.gameStart
       ownEdgeX = (if bot.team == Red: 0.0 else: float(MapW))
       dirX = (if bot.team == Red: 1.0 else: -1.0)
       pd = bot.phalanxDuty
     var front = min(180.0 + 0.11 * float(gameTick), float(MapW) - 300.0)
     when defined(holdFront):
       # Against midline-holding attrition bots the creep walks the pairs into
       # a standing midfield duel fought at the enemy's chosen range; cap the
       # front at a prepared line inside our half and make them cross open
       # ground to reach it. Conversion still comes from the late push.
       front = min(front, HoldFrontCap)
     case pd
     of pdScout:
       let scHasShield = bot.hp > MaxHp
       var shieldSpot = vec(-1.0, -1.0)
       if not scHasShield:
         for sp in bot.shieldPos:
           if dirX * (sp.x - float(CenterX)) < 0.0:  # our own back column
             shieldSpot = sp
             break
       if not scHasShield and shieldSpot.x >= 0.0 and gameTick < 2200:
         target = shieldSpot
       else:
         # Forward patrol beyond the front: bottom-biased weave (their
         # runners are 63% bottom lane), or the lane that called for help.
         var py: float
         if bot.helpUntil > bot.tick:
           py = (case bot.helpLane
             of 1: LaneTop + 40.0
             of 2: LaneMid
             else: LaneBottom - 40.0)
         else:
           let ph = float((gameTick div 3) mod 400)
           py = (if ph < 200.0:
               LaneBottom - 40.0 - (LaneBottom - 40.0 - LaneMid) * (ph / 200.0)
             else:
               LaneMid + (LaneBottom - 40.0 - LaneMid) * ((ph - 200.0) / 200.0))
         target = vec(ownEdgeX + dirX * (front + 130.0), py)
     of pdFloat:
       if bot.helpUntil > bot.tick:
         target = bot.snapToCover(vec(ownEdgeX + dirX * (front - 60.0),
           (case bot.helpLane
             of 1: LaneTop + 26.0
             of 2: LaneMid
             else: LaneBottom - 26.0)))
       else:
         target = bot.chokeHold
     else:
       let laneY = phalanxLaneY(pd)
       # Contact freeze: while a fresh track sits near our lane station,
       # hold the front we had — advance only through quiet ground.
       var contact = false
       let probe = vec(ownEdgeX + dirX * front, laneY)
       for t in bot.enemies:
         if bot.tick - t.lastSeen <= 90 and dist(t.pos, probe) < 420.0:
           contact = true
           break
       if contact:
         if bot.phalanxHold <= 0.0:
           bot.phalanxHold = front
         front = min(front, bot.phalanxHold)
       else:
         bot.phalanxHold = 0.0
       var laneY2 = laneY
       when defined(siege):
         if bot.siegePhase != 0 and phalanxLaneNo(pd) == bot.siegeLane:
           # The siege owns this vertical: the captured line is a FLOOR on
           # the front, and an advance order pushes THROUGH contact (the
           # barrage already softened it) — the freeze must not stall it.
           front = max(front, bot.siegeFront)
           bot.phalanxHold = 0.0
         if bot.siegePhase == 1 and pd in {pdTopA, pdBotA}:
           # Grenadiers converge on the assault vertical for the barrage,
           # standing just behind the captured line inside lob range of the
           # pockets beyond it.
           laneY2 = (case bot.siegeLane
             of 1: LaneTop + 60.0
             of 3: LaneBottom - 60.0
             else: LaneMid)
           front = max(bot.siegeFront, HoldFrontCap) - 20.0
       let lead = pd in {pdTopA, pdMidA, pdBotA}
       target = bot.snapToCover(vec(
         ownEdgeX + dirX * (if lead: front else: front - 44.0),
         laneY2 + (if lead: -32.0 else: 32.0)))
  elif bot.role == HomeDefender and not pushOut:
    # Hold the choke on our pedestal approach; break off to chase the nearest
    # intruder on our half (every steal has to come through here).
    objMode = "defend"
    var intruder = -1
    var intruderD = 1e18
    for i in 0 ..< bot.enemies.len:
      let onOurHalf =
        if bot.team == Red: bot.enemies[i].pos.x < float(CenterX) + 60
        else: bot.enemies[i].pos.x > float(CenterX) - 60
      if not onOurHalf:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d < intruderD:
        intruderD = d
        intruder = i
    if intruder >= 0:
      target = bot.enemies[intruder].pos + bot.enemies[intruder].vel * 6.0
    else:
      target = bot.chokeHold
  elif bot.role == Overwatch and not pushOut:
    objMode = "overwatch"
    if bot.postReady:
      # Peek-and-shoot cycle: hold behind the post; with the gun up and a
      # remembered enemy in reach, sidestep to the peek cell to open the
      # line (the combat block below takes the shot and ducks us back).
      target = bot.postHold
      if shotReady:
        for t in bot.enemies:
          if bot.tick - t.lastSeen <= 24 and
              dist(t.pos, bot.postHold) < FireRange + 30.0:
            target = bot.postPeek
            break
    else:
      target = vec(float(CenterX) + homeSign(bot.team) * 70.0, float(CenterY))
  elif counterPunch and not pushOut:
    # Home-side stations: one gun per lane on our half, second choke on the
    # pedestal approach. Combat below runs at full FireRange (not rushing).
    let sx = float(CenterX) + homeSign(bot.team) * 200.0
    case bot.role
    of FlankTop: target = bot.snapToCover(vec(sx, LaneTop))
    of FlankBottom: target = bot.snapToCover(vec(sx, LaneBottom))
    of MidTop: target = bot.snapToCover(vec(sx, LaneMid - 90.0))
    of MidBottom: target = bot.snapToCover(vec(sx, LaneMid + 90.0))
    else: target = bot.snapToCover(bot.chokeHold + vec(0.0, -64.0))
  else:
    # Attackers: route to the ENEMY pedestal — a fixed, known position by
    # team side. The lead rusher races it dead straight (its seat spawns at
    # pedestal height), the second mid trails behind and offset so one enemy
    # cone cannot kill the pair; flankers run the extreme lanes deep past
    # mid, then hit the pedestal pocket from behind.
    target = stealTarget
    case bot.role
    of MidBottom:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 34.0, 26.0)
    of MidGuard:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 60.0, -26.0)
    of FlankTop, FlankBottom:
      # Run the wide lane deep, then turn straight in for the grab so the
      # flankers hit the pocket together with the mid trio instead of
      # trickling in.
      let laneY = (if bot.role == FlankTop: LaneTop else: LaneBottom)
      if not bot.behindLines and dist(me, stealTarget) > 170.0:
        target = vec(float(CenterX) - homeSign(bot.team) * FlankDepth, laneY)
    else:
      discard

  # The mid trio plays for the flag, not for position: pickup races and
  # carrier chases are lost to peek/duck detours, so mids keep moving and
  # shoot on the move whenever a mate is not already carrying.
  let rushing = not iCarry and not mateCarry and not counterPunch and
    not phalanxOn and bot.role in {MidTop, MidBottom, MidGuard}
  # The pocket endgame: duelling at the pocket edge is an infinite respawn
  # grinder (respawners reappear armed AT the pedestal), so the
  # attacker CLOSEST to the pedestal commits to the touch, unarmed and
  # undistracted, while the rest of the wave keeps its guns up to cover the
  # grab — even a suicide grab forces the enemy back onto defense, and a
  # lucky one starts the capture run.
  var nearestMateToSteal = 1e18
  for t in bot.mates:
    if bot.tick - t.lastSeen > 48:
      continue
    nearestMateToSteal = min(nearestMateToSteal, dist(t.pos, stealTarget))
  let pocketRush = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
    dist(me, stealTarget) < PocketRushRange and
    dist(me, stealTarget) < nearestMateToSteal + 8.0
  if pocketRush:
    objMode = "pocket_rush"

  # Combat: the nearest fresh track with a clear pixel ray AND a mate-free
  # fire cone is the engage target; the nearest fresh-but-wall-blocked track
  # is the peek candidate. The map-wide gun engages fresh tracks far beyond
  # the view, so chases keep killing after the target leaves the window —
  # but objective play caps the range: the carrier only fights point-blank,
  # rushers racing for the steal and escorts guarding a run only fight what
  # is actually in the way, instead of frag-chasing across the map.
  let maxEngage =
    if bot.tripping: 0.0                 # sprinting an errand: no fights
    elif hasShield and not hasPlasma:    # slow gun (3x cooldown): only fight
      CarrierFireRange                   # what is point-blank in the way
    elif hasPlasma: PlasmaReach + 6.0    # cone weapon: only close range matters
    elif pocketRush: 0.0
    elif iCarry: CarrierFireRange
    elif ownStolen and bot.tick - bot.carrierSeen <= thiefChaseTtl: FireRange
      # A live fix on the enemy running our flag lifts every role's range
      # cap: the map-wide gun is the fastest flag return there is.
    elif rushing: RushEngageRange
    elif mateCarry: EscortEngageRange
    else: FireRange
  # No focus-fire intel: piling our shot onto the target a mate is already
  # lined up on needs that mate's AIM ANGLE, and the observation no longer
  # carries one (the "aim dot <color>" readback was retired engine-side; a
  # mate's sprite side label is a left/right flip, far too coarse to ray).

  var
    engage = -1
    engageD = maxEngage
    engagePrio = maxEngage
    aim: Vec
    blockedAim: Vec
    haveBlocked = false
    blockedD = maxEngage
  for i in 0 ..< bot.enemies.len:
    let t = bot.enemies[i]
    if bot.tick - t.lastSeen > FreshShotTicks:
      continue
    let predicted = t.pos + t.vel * (float(bot.tick - t.lastSeen) + LeadTicks)
    let d = dist(predicted, me)
    if d >= maxEngage:
      continue
    # Target priority: distance plus the turret swing needed to lay on the
    # target (the traverse is slow, so a target near the current aim line
    # dies sooner than a nearer one behind us), discounted for wounded
    # targets (a 1-hp enemy dies to one shot — finish it before it resets on
    # respawn). The discounts are tiebreaks between comparably-engageable
    # targets, deliberately smaller than a real positional difference.
    var prio = d +
      float(abs(bradsErr(bradsOf(predicted - me), bot.estAim))) * TraversePxPerBrad
    if t.hp in 1 ..< MaxHp:
      prio -= float(MaxHp - t.hp) * HpFocusBonus
    block thiefPrio:
      let fixAge = bot.tick - bot.carrierSeen
      if ownStolen and fixAge <= thiefChaseTtl:
        # Under -d:thiefCommit the fix may be stale: test proximity against
        # the DEAD-RECKONED carrier position, not the aging last fix.
        let carrierRef =
          when defined(thiefCommit):
            bot.carrierPos + bot.carrierVel * float(fixAge)
          else:
            bot.carrierPos
        let slack = when defined(thiefCommit): 90.0 else: 48.0
        if dist(t.pos, carrierRef) <= slack:
          # This track IS (or shadows) the enemy running our flag: shoot it
          # before anything else — a dead carrier returns the flag instantly.
          prio -= ThiefFocusBonus
    if client.pixelRayClear(me, predicted):
      if bot.friendlyBlocked(me, predicted, d):
        continue                        # prefer a target with an empty corridor
      if engage < 0 or prio < engagePrio:
        engagePrio = prio
        engageD = d
        engage = i
        aim = predicted
    elif d < blockedD:
      blockedD = d
      blockedAim = predicted
      haveBlocked = true

  # The nearest remembered enemy that could be threatening us right now,
  # used to pick which line to break when ducking through cooldown.
  var
    nearThreat = -1
    nearThreatD = DuckRange
  for i in 0 ..< bot.enemies.len:
    if bot.tick - bot.enemies[i].lastSeen > 30:
      continue
    let d = dist(bot.enemies[i].pos, me)
    if d < nearThreatD:
      nearThreatD = d
      nearThreat = i

  # Grenades (0.7.0): a lobbed 2-hp blast that flies over every wall — the
  # counter to cover-campers the hitscan gun can never reach. Carry one when a
  # corner pickup is a short detour away; spend it on a wall-blocked fresh
  # track (value the gun cannot collect) or on a tight enemy pair in range.
  var carryingNade = false
  for o in client.spriteObjectsWithLabel(LabelGrenadeCarried):
    # The marker floats above-right of its carrier (+8 x, ~-20 y from center).
    if dist(client.mapPos(o), me) <= 30.0:
      carryingNade = true
      break
  # Cardboard barrier (config-gated): carrying one blocks grenade pickups
  # (both spend button C), so the carry state gates the nade detours below.
  var carryingBarrier = false
  for o in client.spriteObjectsWithLabel(LabelBarrierCarried):
    if dist(client.mapPos(o), me) <= 30.0:
      carryingBarrier = true
      break
  when defined(nadeRelay):
    if carryingNade and not bot.wasNade:
      # Fresh pickup: announce WHICH spot so the team shares the 5s respawn
      # clock. Nearest known spot wins; a grab at a never-seen spot teaches
      # a new one at our own position.
      var si = -1
      var bestD = 60.0
      for i in 0 ..< bot.nadeSpotPos.len:
        let d = dist(bot.nadeSpotPos[i], me)
        if d < bestD:
          bestD = d
          si = i
      if si < 0:
        bot.nadeSpotPos.add me
        bot.nadeSpotEta.add 0
        si = bot.nadeSpotPos.len - 1
      bot.nadeSpotEta[si] = bot.tick + 126
      bot.nadeShoutWant = "G" & $(int(bot.nadeSpotPos[si].x) div 8) & " " &
        $(int(bot.nadeSpotPos[si].y) div 8)
    bot.wasNade = carryingNade
  var
    nadeAim = -1
    nadeThrowD = 0.0
  if carryingNade and not iCarry:
    var bestD = 1e18
    for i in 0 ..< bot.enemies.len:
      let t = bot.enemies[i]
      let age = bot.tick - t.lastSeen
      # -d:campNade (daveey, R1693 review): a STATIONARY enemy that fogged out
      # is a camper, and his remembered position stays true long after the
      # 1-second fresh window — the lob over his cover is exactly what the
      # grenade is for, and the gun only engages fresh tracks so this never
      # competes with a live firefight.
      let camped =
        when defined(campNade):
          age > FreshShotTicks and age <= NadeCampTicks and
            len(t.vel) < NadeCampSpeed
        else:
          false
      if age > FreshShotTicks and not camped:
        continue
      let p =
        if camped: t.pos
        else: t.pos + t.vel * float(age)
      let d = dist(p, me)
      if d < NadeMinRange or d > NadeMaxRange or d >= bestD:
        continue
      let blocked = not client.pixelRayClear(me, p)
      var paired = false
      if not blocked:
        for j in 0 ..< bot.enemies.len:
          if j != i and bot.tick - bot.enemies[j].lastSeen <= FreshShotTicks and
              dist(bot.enemies[j].pos, p) <= NadeBlast:
            paired = true
            break
      if blocked or paired or camped:
        bestD = d
        nadeAim = bradsOf(p - me)
        nadeThrowD = d
        when defined(v57Debug):
          if camped:
            echo "V57 campNade slot=", bot.slot, " tick=", bot.tick,
              " lob at camped track age=", age, " d=", int(d),
              " pos=", int(p.x), ",", int(p.y)
  when defined(siege):
    if carryingNade and not iCarry and nadeAim < 0 and bot.siegePhase == 1 and
        bot.siegeLane != 0:
      # Blind barrage: no live track, but the captain called this vertical —
      # lob at the first pocket beyond the captured line that my own gun
      # cannot see. Behind-cover ground is exactly where a turtler waits.
      let
        laneYb = (case bot.siegeLane
          of 1: LaneTop + 50.0
          of 3: LaneBottom - 50.0
          else: LaneMid)
        ownEdgeXb = (if bot.team == Red: 0.0 else: float(MapW))
        dirXb = (if bot.team == Red: 1.0 else: -1.0)
        baseb = max(bot.siegeFront, HoldFrontCap)
      for k in 0 ..< 4:
        let pk = vec(ownEdgeXb + dirXb * (baseb + 70.0 + 45.0 * float(k)),
                     laneYb + (if (k and 1) == 1: 34.0 else: -34.0))
        let dk = dist(pk, me)
        if dk < NadeMinRange or dk > NadeMaxRange:
          continue
        if bot.gridRayClear(me, pk):
          continue
        nadeAim = bradsOf(pk - me)
        nadeThrowD = dk
        break
  when defined(nadeCluster):
    if carryingNade and not iCarry and nadeAim < 0:
      # Cluster strike: campers do not move, so freshness is the wrong
      # filter — any REMEMBERED pair of enemies within one blast of each
      # other is a target, as long as the midpoint is wall-blocked (the gun
      # owns visible ground) and in lob range. This is where a clustered
      # cover-camper dies.
      var bestScore = -1.0
      for a in 0 ..< bot.campPos.len:
        if bot.tick - bot.campSeen[a] > StaleClusterTtl:
          continue
        for b in (a + 1) ..< bot.campPos.len:
          if bot.tick - bot.campSeen[b] > StaleClusterTtl:
            continue
          if dist(bot.campPos[a], bot.campPos[b]) > ClusterPairPx:
            continue
          let mid = vec((bot.campPos[a].x + bot.campPos[b].x) * 0.5,
                        (bot.campPos[a].y + bot.campPos[b].y) * 0.5)
          let d = dist(mid, me)
          if d < NadeMinRange or d > NadeMaxRange:
            continue
          if bot.gridRayClear(me, mid):
            continue                       # visible: the gun covers it
          # prefer the freshest, tightest cluster
          let score = 2000.0 -
            float(bot.tick - max(bot.campSeen[a], bot.campSeen[b])) -
            dist(bot.campPos[a], bot.campPos[b])
          if score > bestScore:
            bestScore = score
            nadeAim = bradsOf(mid - me)
            nadeThrowD = d
      # Charge salvo: the wave is about to cross — put every held grenade
      # onto remembered ground FIRST so the blasts land as we close. In the
      # salvo window a stale SINGLE behind cover is worth the lob too.
      if nadeAim < 0 and bot.tick < bot.salvoUntil:
        for i in 0 ..< bot.campPos.len:
          if bot.tick - bot.campSeen[i] > StaleClusterTtl:
            continue
          let d = dist(bot.campPos[i], me)
          if d < NadeMinRange or d > NadeMaxRange:
            continue
          if bot.gridRayClear(me, bot.campPos[i]):
            continue
          nadeAim = bradsOf(bot.campPos[i] - me)
          nadeThrowD = d
          break

  # Weapon pickups. SHIELD-THEN-STEAL: the enemy endzone shield sits just
  # behind their pedestal — a rusher near the pocket grabs 6 hp first and
  # steals second (the run home is what kills 3 hp carriers). Defensive
  # roles never take a shield (it slows the gun 3x). PLASMA ARCS arm the
  # pocket brawlers: attackers detour a little for one on the way in — the
  # pocket duel is close-range, where an instant lethal cone beats any gun.
  bot.tripping = false
  if not iCarry and not hasShield and bot.role == MidTop and
      enemyPlanted.len > 0 and
      not (ownStolen and bot.tick - bot.carrierSeen <= ThiefFixTtl):
    # HOME KIT-UP: either team may take either endzone's shield, and OURS
    # sits ~50px from our own spawn — so the LEAD RUSHER gears up at home
    # for near-zero tempo (the enemy-side trip was refuted twice: a 3hp
    # unarmed sprinter cannot cross the map, fighting or not). The rusher
    # arrives at the pocket as a 6hp bruiser; the co-located sword makes
    # the pocket duel an instant-lethal swipe instead of a gunfight.
    for i in 0 ..< bot.shieldPos.len:
      if not pickupAvailable(bot.shieldAbsentAt, i, bot.tick):
        continue
      if homeSign(bot.team) * (bot.shieldPos[i].x - float(CenterX)) < 0.0:
        continue                         # enemy endzone: refuted suicide run
      if dist(me, bot.shieldPos[i]) + dist(bot.shieldPos[i], stealTarget) -
          dist(me, stealTarget) < ShieldStealDetour:
        target = bot.shieldPos[i]
        objMode = "shield_trip"
        break
  elif not iCarry and not hasPlasma and
      bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
      not mateCarry and not pocketRush:
    # Plasma top-up: cone-armed pocket brawls win close range. Cheap when we
    # are already visiting the endzone column (shield chain) or passing by.
    for i in 0 ..< bot.plasmaPos.len:
      if not pickupAvailable(bot.plasmaAbsentAt, i, bot.tick):
        continue
      if dist(me, bot.plasmaPos[i]) <= PlasmaDetour:
        target = bot.plasmaPos[i]
        objMode = "plasma_grab"
        break
  # Med kit heal detour (hurt bots only; the carrier handles its own detour
  # in the carry branch). Wounded: a short opportunistic detour. Critical
  # (1 hp): a heal outranks the current errand at much longer reach — a
  # healed body is a respawn we did not spend. Never while committing to the
  # pocket touch or chasing the enemy running our flag, and the CARRIER gets
  # right of way: if our flag runner is closer to the kit than we are, we
  # leave it — kits are hurt-only pickups, so deferring costs nothing when
  # the carrier turns out healthy.
  if bot.hp < MaxHp and not iCarry and not pocketRush and
      not (ownStolen and bot.tick - bot.carrierSeen <= ThiefFixTtl):
    let reach = if bot.hp <= 1: MedKitCriticalReach else: MedKitDetour
    let kit = bot.bestKitDetour(me, target, reach)
    if kit >= 0 and not (mateCarry and
        dist(mateCarryPos, bot.kitPos[kit]) < dist(me, bot.kitPos[kit]) + 100.0):
      target = bot.kitPos[kit]
      objMode = "heal_detour"

  if not carryingNade and not carryingBarrier and not iCarry and
      not mateCarry and not pocketRush:
    # Collect a pickup: anyone grabs one within a short detour, and the two
    # flankers own their lane's friendly-side corner spawn — it sits right on
    # their border route, so they arm up on the way out every respawn cycle.
    var pickupSet = false
    for o in client.spriteObjectsWithLabel(LabelGrenade):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
          p.y > float(MapH - 40):
        continue                     # HUD indicator shares the label
      when defined(nadeRelay):
        # Seeing a stocked spot teaches it and clears any respawn clock.
        var known = false
        for i in 0 ..< bot.nadeSpotPos.len:
          if dist(bot.nadeSpotPos[i], p) < 24.0:
            bot.nadeSpotEta[i] = 0
            known = true
            break
        if not known:
          bot.nadeSpotPos.add p
          bot.nadeSpotEta.add 0
      let laneMatch =
        (bot.role == FlankTop and p.y < float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0) or
        (bot.role == FlankBottom and p.y > float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0)
      let reach = if laneMatch: 1e9 else: NadePickupDetour
      if dist(p, me) <= reach:
        when defined(nadeDebug):
          echo "DETOUR to pickup at ", p.x, ",", p.y, " role ", bot.role
        target = p
        pickupSet = true
        objMode = "nade_grab"
        break
    when defined(nadeRelay):
      # Relayed respawn clock: a spot that just refilled is worth the same
      # detour as a visible one even through fog — arrive right on time.
      if not pickupSet:
        for i in 0 ..< bot.nadeSpotPos.len:
          let eta = bot.nadeSpotEta[i]
          if eta == 0 or bot.tick < eta or bot.tick > eta + 360:
            continue
          let p = bot.nadeSpotPos[i]
          let laneMatch =
            (bot.role == FlankTop and p.y < float(CenterY) and
             homeSign(bot.team) * (p.x - float(CenterX)) > 0) or
            (bot.role == FlankBottom and p.y > float(CenterY) and
             homeSign(bot.team) * (p.x - float(CenterX)) > 0)
          let reach = if laneMatch: 1e9 else: NadePickupDetour
          if dist(p, me) <= reach:
            target = p
            break

  # Cardboard barrier pickup: a cheap detour when our hands are empty (the
  # sim refuses the grab while a grenade is carried, and vice versa). The
  # grenade detour above wins when both are in reach.
  if not carryingNade and not carryingBarrier and not iCarry and
      not mateCarry and not pocketRush and objMode != "nade_grab":
    for o in client.spriteObjectsWithLabel(LabelBarrier):
      let p = client.mapPos(o)
      if dist(p, me) <= BarrierDetour:
        target = p
        objMode = "barrier_grab"
        break

  # Grenade danger: a visible throw-target ring marks where an enemy's lob
  # will land, and an airborne grenade is seconds from bursting — anything
  # inside the blast radius eats 2 of 3 hit points. Fleeing the marked spot
  # outranks every movement goal except nothing: dead carriers drop the run.
  var
    nadeDanger = false
    nadeDangerFrom: Vec
  block nadeDangerScan:
    for label in ["throw target", "grenade air"]:
      for o in client.spriteObjectsWithLabel(label):
        let p = client.mapPos(o)
        if dist(p, me) <= NadeBlast + 18.0:
          nadeDanger = true
          nadeDangerFrom = p
          break nadeDangerScan

  # Turret + locomotion, decided together but on separate buttons: moveMask
  # is the d-pad, desiredAim feeds the rotate buttons, wantFire pulls A.
  var
    moveMask: uint8
    desiredAim = -1
    deadband = CombatDeadband
    wantFire = false
    acted = false
    holdStill = false
    nadeC = false
    actMode = "navigate"      # telemetry: which turret/act branch ran
  if bot.nadeCharge > 0 or nadeAim >= 0:
    actMode = "nade"
    # Charge-throw: lay the turret on the lob line, then hold C for the ticks
    # the planned distance needs and release — the grenade leaves along the
    # CURRENT aim on release, so the turret keeps correcting while charging.
    if bot.nadeCharge == 0:
      bot.nadeNeed = max(3, int(float(NadeFullChargeTicks) *
        (nadeThrowD - 30.0) / (NadeMaxRange - 30.0)))
    if nadeAim >= 0:
      desiredAim = nadeAim
    if bot.nadeCharge > 0 or (desiredAim >= 0 and
        abs(bradsErr(desiredAim, bot.estAim)) <= CombatDeadband + 2):
      if bot.nadeCharge < bot.nadeNeed:
        nadeC = true
        inc bot.nadeCharge
      else:
        bot.nadeCharge = 0           # release this tick = the throw
    holdStill = true
    acted = true
  elif hasPlasma and engage >= 0:
    actMode = "plasma"
    # Plasma cone: ignition is INSTANT (no windup, no aim lock), reaches 4
    # squares plus a body radius, stays on 5 ticks, and deals 3 hp (lethal to
    # bare cogs) — press A the moment the victim is inside reach and roughly
    # in front.
    desiredAim = bradsOf(aim - me)
    let err = abs(bradsErr(desiredAim, bot.estAim))
    # How far off-axis the cone still catches this target, as an angle: the
    # half-width is PlasmaSlope * range + a whole body radius, so the angle
    # the cone forgives OPENS UP as the range closes. A fixed half-angle gate
    # throws away most of a point-blank spray's reach.
    let plasmaHalfBrads = int(round(
      arctan((PlasmaSlope * engageD + PlasmaBodyRadius) / max(1.0, engageD)) *
        float(AimBrads div 2) / PI))
    # Ignite a little early on the angle: the cone stays on 5 ticks and
    # tracks our aim, so the ongoing traverse sweeps it across the target.
    if engageD <= PlasmaReach - 6.0 and err <= plasmaHalfBrads + 3:
      wantFire = true
      holdStill = true
    else:
      moveMask = octantBits(aim - me)    # charge in
    acted = true
  elif engage >= 0 and shotReady:
    actMode = "fire"
    # Traverse onto the target and fire once the corridor covers it: the
    # perpendicular miss of the current aim error at the target's range must
    # sit inside the ~14px bullet corridor. Advancing scales that miss down
    # linearly, so keep closing while the turret settles.
    desiredAim = bradsOf(aim - me)
    let
      err = abs(bradsErr(desiredAim, bot.estAim))
      perpMiss = engageD * sin(float(err) * PI / float(AimBrads div 2))
    wantFire = perpMiss <= FireSlackPx
    moveMask = octantBits(aim - me)
    acted = true
  elif not iCarry and not rushing and not pocketRush and not shotReady and
      nearThreat >= 0:
    # Cooldown: duck behind the nearest cover that breaks the threat's line
    # and hold there until the gun is back up, keeping the aim (and the
    # vision cone) on the arc the threat would push through.
    let duck = bot.findDuckCell(client, me, bot.enemies[nearThreat].pos)
    if duck >= 0:
      actMode = "duck"
      desiredAim = bradsOf(bot.enemies[nearThreat].pos - me)
      if dist(cellCenter(duck), me) < 5.0:
        holdStill = true
      else:
        moveMask = octantBits(cellCenter(duck) - me)
      acted = true
  elif not iCarry and not rushing and shotReady and haveBlocked:
    # Peek: PRE-LAY the aim on the blocked target while stepping sideways to
    # the nearest cell that opens the firing line — the engage branch fires
    # the moment the ray clears, with the traverse already done.
    desiredAim = bradsOf(blockedAim - me)
    let peek = bot.findPeekCell(client, me, blockedAim)
    if peek >= 0 and dist(cellCenter(peek), me) > 4.0:
      actMode = "peek"
      moveMask = octantBits(cellCenter(peek) - me)
      acted = true

  if not acted:
    # Threat jink: sidestep a visible enemy that is aiming our way while our
    # own shot is not lined up, instead of walking into its muzzle.
    var threat = -1
    var threatD = ThreatRange
    for i in 0 ..< seenEnemies.len:
      let a = seenEnemies[i]
      let facingMe =
        (a.facingRight and a.pos.x < me.x) or
        (not a.facingRight and a.pos.x > me.x)
      let d = dist(a.pos, me)
      if facingMe and d < threatD:
        threatD = d
        threat = i
    if threat >= 0 and not iCarry and not pocketRush:
      actMode = "evade"
      let away = norm(me - seenEnemies[threat].pos)
      var side = vec(-away.y, away.x)
      if (bot.tick div 12 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(side + away * 0.4)
      if desiredAim < 0:
        desiredAim = bradsOf(seenEnemies[threat].pos - me)
    elif bot.role in {Overwatch, HomeDefender} and
        dist(me, target) < 6.0:
      # Holding a watch position: the aim carries the vision cone, so sweep
      # it back and forth across the arc threats cross while standing still.
      # While our flag is stolen the thief comes from our own half;
      # otherwise intruders come from the enemy half.
      actMode = "scan"
      let watch =
        if ownStolen: vec(homeSign(bot.team), 0.0)
        else: vec(-homeSign(bot.team), 0.0)
      if desiredAim < 0:
        desiredAim = bot.scanAim(watch)
      holdStill = true
    else:
      when defined(centerScan):
        # Center-corridor vision sweep: crossing mid-map with a forward-glued
        # aim walks blind past enemies passing a lane above or below. With no
        # live contact, rake the cone across the vertical arcs while moving —
        # alternating the upper and lower sweep so both flanks get eyes.
        if desiredAim < 0 and not iCarry and
            abs(me.x - float(CenterX)) < CenterScanHalf and
            bot.tick - bot.lastEnemySeen > 40:
          if (bot.tick div 180) mod 2 == 0:
            desiredAim = bot.scanAim(vec(0.0, -1.0))
          else:
            desiredAim = bot.scanAim(vec(0.0, 1.0))
      # Navigate: cover-aware path steering plus soft repulsion from nearby
      # teammates so one burst (or our own shot) cannot hit two of us.
      var steer = norm(bot.navSteer(client, me, target))
      for t in bot.mates:
        if bot.tick - t.lastSeen > 12:
          continue
        let d = dist(t.pos, me)
        if d < MateSpacing and d > 0.5:
          steer = steer + norm(me - t.pos) * ((MateSpacing - d) / MateSpacing) * 0.9
      # Serpentine when a straight run would cross watched ground. Fog cuts
      # both ways: a fresh remembered enemy with a clear pixel line pins
      # anyone, and rushers crossing the contested MIDDLE weave even without
      # intel — the snipers watching their lane are exactly the enemies they
      # cannot see. Close threats are the jink/duck branches' job; carriers
      # and the pocket grab skip it — for them speed beats evasion.
      if not iCarry and not pocketRush:
        var weave = false
        if rushing:
          weave = abs(me.x - float(CenterX)) < WeaveBand
        else:
          for t in bot.enemies:
            if bot.tick - t.lastSeen > UnderFireTrackTtl:
              continue
            let d = dist(t.pos, me)
            if d >= SerpentineNear and d <= SerpentineFar and
                client.pixelRayClear(me, t.pos):
              weave = true
              break
        if weave:
          var side = vec(-steer.y, steer.x)
          if (bot.tick div 8 + bot.slot div 2) mod 2 == 0:
            side = side * -1.0
          steer = norm(steer) + side * (float(tuneWeaveGain) / 100.0)
      steer = steer + vec(rand(-0.12 .. 0.12), rand(-0.12 .. 0.12))
      moveMask = octantBits(steer)
      if bot.tick < bot.jinkUntil:
        moveMask = bot.jinkBits            # unsticking burst
      if desiredAim < 0 and ownStolen and
          bot.role in {FlankTop, FlankBottom} and
          bot.tick - bot.carrierSeen > ThiefFixTtl:
        # Flanker rear-view: our flag is out and fogged, and the classic
        # escape is a 1 hp runner hugging exactly this border lane BEHIND
        # us (decoded from Picasso v7 and v14 losses alike). Alternate the
        # sweep between rear and forward along the lane every two seconds —
        # aim is decoupled from movement, so this costs nothing positional.
        let sweepDir =
          if (bot.tick div 48) mod 2 == 0: homeSign(bot.team)
          else: -homeSign(bot.team)
        desiredAim = bot.scanAim(vec(sweepDir, 0.0))
      if desiredAim < 0:
        # No target demands the turret: the aim leads the movement direction
        # so the vision cone watches down-lane where we are heading. Movement
        # no longer leaks our vision, so this is a choice, not a side effect.
        desiredAim = bradsOf(steer)
        deadband = CruiseDeadband

  # Stuck detection: if we have not moved for a second (and are not holding
  # behind cover on purpose), burst in a random direction and force a repath.
  if dist(me, bot.lastPos) < 0.8:
    inc bot.stuckTicks
  else:
    bot.stuckTicks = 0
  bot.lastPos = me
  if holdStill:
    bot.stuckTicks = 0
  var jinked = false
  if bot.stuckTicks > 20 and engage < 0:
    bot.stuckTicks = 0
    bot.jinkUntil = bot.tick + 10
    bot.jinkBits = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))
    bot.navGoal = -1
    if bot.jinkBits == 0:
      bot.jinkBits = ButtonUp
    moveMask = bot.jinkBits
    jinked = true

  if nadeDanger:
    # Sprint straight out of the marked blast zone; drop any hold/duck.
    actMode = "nade_flee"
    let away = me - nadeDangerFrom
    moveMask = octantBits(
      if len(away) < 1.0: vec(homeSign(bot.team), 0.3) else: away
    )
    holdStill = false

  if moveMask == 0 and not holdStill:
    moveMask = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))

  # Rotate toward the desired aim by the shortest arc; inside the deadband
  # (AimRate cannot settle tighter than +-AimRate/2) hold the turret still.
  var rotBits: uint8 = 0
  if desiredAim >= 0:
    let err = bradsErr(desiredAim, bot.estAim)
    if err > deadband:
      rotBits = ButtonB
    elif err < -deadband:
      rotBits = ButtonSelect

  # Only a FRESH A press fires, and the pull locks the aim angle on the same
  # tick — never rotate on the pull tick so the lock takes the settled aim.
  var mask = moveMask or rotBits
  if wantFire and not bot.firedLast:
    mask = moveMask or ButtonA
  if carryingBarrier and nearThreat >= 0 and nearThreatD < BarrierPlaceRange:
    # Wall off the closest threat: placement is a press-edge, so holding C
    # across ticks costs nothing once the cardboard is down.
    nadeC = true
  if nadeC:
    mask = mask or ButtonC
  bot.firedLast = (mask and ButtonA) != 0
  bot.rotSign =
    if (mask and ButtonB) != 0: 1
    elif (mask and ButtonSelect) != 0: -1
    else: 0
  artFrame(FrameSnap(
    tick: bot.tick, alive: true,
    x: int(me.x), y: int(me.y), hp: bot.hp, aim: bot.estAim,
    objective: objMode, action: actMode,
    targetX: int(target.x), targetY: int(target.y),
    iCarry: iCarry, mateCarry: mateCarry, ownStolen: ownStolen,
    sawThief: sawThief, pushOut: pushOut,
    hasShield: hasShield, hasPlasma: hasPlasma, carryNade: carryingNade,
    nadeCharge: bot.nadeCharge, jinked: jinked, nadeDanger: nadeDanger,
    enemiesVisible: seenEnemies.len,
    engageDist: (if engage >= 0: int(engageD) else: -1),
    mask: mask, fired: (mask and ButtonA) != 0))
  mask

const ShoutVocab = [
  "go go go", "on me", "help!", "push left", "flank right",
  "got it!", "cover me", "nice!", "regroup", "incoming"
]
  ## A short kid-friendly chatter set. Only emitted when CTF_BOT_SHOUT is set
  ## (fixture recording), so tournament play is unchanged.

type BaselineComponent* = object
  bot: Bot
  client: ProtocolClient
  lastMask: uint8
  hasSent: bool

proc initBaselineComponent*(slot: int): BaselineComponent =
  ## Builds the deterministic baseline policy without a websocket transport.
  let
    team = (if slot mod 2 == 0: Team.Red else: Team.Blue)
    role = roleForSeat(clamp(slot div 2, 0, 7), team)
  randomize(slot * 7919 + 1)
  SelfStrategyTeam = team
  result.bot = Bot(
    slot: slot,
    team: team,
    role: role,
    myColor: (if team == Red: "red" else: "blue")
  )
  result.bot.resetTransient()
  result.client = initProtocolClient()

proc advancePolicy(component: var BaselineComponent, advance: int) =
  component.bot.tick += advance
  component.bot.estAim = floorMod(
    component.bot.estAim + component.bot.rotSign * AimRate * advance,
    AimBrads
  )

proc policyReplies(component: var BaselineComponent): seq[string] =
  if not component.client.mapCameraReady:
    component.bot.resetTransient()
    return
  if not component.bot.navBuilt and component.client.walkabilityReady:
    component.bot.buildNavGrid(component.client)
  let mask = component.bot.decide(component.client)
  if not component.hasSent or mask != component.lastMask:
    result.add(inputBlob(mask))
    component.lastMask = mask
    component.hasSent = true

proc onMessage*(component: var BaselineComponent, message: string): seq[string] =
  ## Applies one game frame and returns the baseline's changed input frame.
  component.client.applyFrame(message)
  component.advancePolicy(component.client.frameAdvance)
  component.policyReplies()

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    endpoint = ensureWsPath(url, WebSocketPath)
  var component = initBaselineComponent(slot)
  let
    bot = component.bot
    client = component.client
    shoutEnabled = getEnv("CTF_BOT_SHOUT").len > 0
    # Opt-in ONLY (fixture recording): the per-frame ready send measurably
    # corrupts input-application timing in league play — the bot's
    # dead-reckoned aim (estAim) random-walks to a median ~15 brad error at
    # the trigger and gun accuracy collapses 44-54% -> 13-23% (task
    # 1216940574461149: removing this send flipped the same tree from
    # 0W-23L-1M to 8W-10L-6M vs the champion, p=0.0039). League/xreq runners
    # never set this env, so competitive builds do not send ready at all.
    fastReadyEnabled = getEnv("CTF_BOT_FAST_READY").len > 0
  startProfileTrace()
  echo "baseline slot=", slot, " team=", bot.team, " role=", bot.role, " -> ", endpoint
  artInit(slot, $bot.team, $bot.role)
  when defined(taunt):
    startTaunts()                        # worker thread + bank prefetch
  var everConnected = false
  var playing = false
  while true:
    try:
      let ws = newWebSocket(endpoint)
      # TCP_NODELAY lives at IPPROTO_TCP, not the default SOL_SOCKET (where
      # optname 1 is SO_DEBUG: EACCES without CAP_NET_ADMIN, and a silent
      # no-op for Nagle even when privileged).
      ws.socket.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
      # Sprites Off (0x87), sent before anything else so the server strips
      # pixel payloads from the very first frame. Servers that predate the
      # packet ignore unknown client messages, so this is safe everywhere.
      ws.send(spritesOffBlob(), BinaryMessage)
      echo "connected ", endpoint
      everConnected = true
      client.reset()
      bot.navBuilt = false
      bot.resetTransient()
      component.hasSent = false
      while true:
        if not client.receiveLatestFrame(ws, false):
          continue
        let advance = max(1, client.frameAdvance)
        component.advancePolicy(advance)
        if profileShouldDump(bot.tick):
          finishProfileTrace()
        if not client.mapCameraReady:
          if playing:
            playing = false
            artEvent(bot.tick, "game_end")
          bot.resetTransient()             # lobby / game-over interstitial
          continue
        if not playing:
          playing = true
          artEvent(bot.tick, "game_start")
        for reply in component.policyReplies():
          ws.send(reply, BinaryMessage)
        # Fixture-only chatter: shout on a slot-staggered ~2s cadence so a
        # recorded episode carries live shouts to exercise the bubble render.
        if shoutEnabled and
            (bot.tick + bot.slot * 5) mod (2 * 24) < advance:
          let phrase = ShoutVocab[(bot.tick div 48 + bot.slot) mod
            ShoutVocab.len]
          ws.send(chatBlob(phrase), BinaryMessage)
        # Competitive coordination / taunt shouts (compile-gated).
        when defined(shoutCoord) or defined(taunt):
          if bot.shoutWant.len > 0:
            ws.send(chatBlob(bot.shoutWant), BinaryMessage)
            artEvent(bot.tick, "shout_tx", %*{"text": bot.shoutWant})
            bot.shoutWant = ""
        # Done thinking: a fastMode server advances the tick as soon as
        # every player has sent this; older servers ignore the packet.
        # Gated OFF by default (see fastReadyEnabled above): only fixture
        # recording opts in via CTF_BOT_FAST_READY=1.
        if fastReadyEnabled:
          ws.send(readyBlob(), BinaryMessage)
    except Exception as e:
      if everConnected:
        # The game ended and the server went away: exit so the episode
        # runner sees a clean player shutdown. The socket closing is this
        # bot's final game message — ship the telemetry artifact now,
        # before the runner tears the container down.
        echo "game over, exiting: ", e.msg
        artFlush()
        quit(0)
      echo "connect retry: ", e.msg
      sleep(250)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
