# Agent skins (first skin: crown)

## Problem

Players want cosmetic skins for their agents. The first skin is a **crown**:
the agent's full-body soldier art with a crown added. Skins must be assignable
per agent at game start.

## Design

### Config (how a skin is specified at game start)

`slots[i].skin` — a new **optional** string field on the existing `slots[]`
entries in `config.json`, next to `team`/`color`/`token`, parsed in
`readConfigSlots` into a new `PlayerSlotConfig.skin` field.

**Tolerance is a hard requirement:** existing configs must keep working
unchanged. A missing `skin` field silently means the default skin. An
*unrecognized* skin value also falls back to the default skin — it must never
abort startup — but logs a one-line stderr warning naming the slot and the bad
value, so an operator typo (`"crwon"`) is discoverable. This is deliberately
laxer than the `color`/`team` fields (which raise `CtfError`): skins are pure
cosmetics, so a bad value should never take the game down.

Recognized values: `"default"` and `"crown"`.

### Skin = alternate master PNGs

Each team's player-view soldier is a single master PNG (`data/soldier_red.png` /
`data/soldier_blue.png`) that `soldierRotPixels` (src/ctf/sim.nim) measures,
gun-mounts, and pre-rotates into all `SoldierRotations` steps; the corpse
(grey desaturation) and selected-outline variants are *derived* from those
rendered pixels. The global spectator board uses an articulated rig whose head
is independently skin-aware while its limbs and weapon remain shared.

- `default` → the existing `soldier_red/blue.png`.
- `crown` → new `data/soldier_red_crown.png` / `data/soldier_blue_crown.png`:
  the existing masters with a gold outlined crown composited over the helmet,
  generated deterministically by `tools/generate_crown_skins.nim` (checked in
  alongside the PNGs, so the art can be regenerated). The same generator emits
  `data/rig_real/{red,blue}/head_crown.png` for the spectator rig.

Everything downstream — rotations, corpses, selected outlines, the POV self
sprite — comes free through the existing pipeline.

### Sim state

`Player.skin` (a small `Skin` enum), set from the slot config at join.
Cosmetic only: excluded from `gameHash` like `color`. No sim behavior,
protocol, or `GameVersion` change. `soldierRotPixels` and the master
loading/caching vars gain a skin dimension.

### Rendering and sprite ids

`soldierPlayerSpriteId`, `corpseSoldierSpriteId`,
`selectedSoldierPlayerSpriteId`, the POV self-sprite pool, and the articulated
rig-head pool gain a skin offset (live 100..163, corpse 1500..1563, selected
6000..6063, self 5100..5131, rig head 40000..40063; the sprite-id collision
audit in CI guards overlaps). Everywhere a visible player head sprite id is
computed from `(team, rot)` it becomes `(team, skin, rot)`.

Skin sprite pools are only registered in the init snapshot when some
configured slot actually uses that skin, so skinless games pay nothing.

### Labels: byte-identical (the key constraint)

Sprite labels are per sprite *definition* and the client keys sprites by id,
not label — the 16 rotation sprites per team already share two labels. Crown
sprites carry the **exact same** documented labels: `player <color> <side>`,
`corpse <color> <side>`, `selected player <color> <side>`. No new label
vocabulary; exact-match label readers (the baseline bot, the CI label-contract
canary) are untouched. Policies cannot distinguish skins — they are
spectator-facing decoration only, by design.

### Non-goals

- Skinned endscreen roster chips (they stay the compact default soldier).
- Player-chosen skins via connect params (config-only for now).
- Any policy-visible skin signal (labels, protocol fields).

## Touched surfaces

- `src/ctf/sim.nim`: `Skin` enum + registry (skin → master paths), tolerant
  `slots[i].skin` parsing, `PlayerSlotConfig.skin`, `Player.skin`,
  skin-dimensioned soldier master loading + `soldierRotPixels`, and
  `configJson` round-tripping non-default skins into replay configs (default
  skins are omitted so existing replay JSON keeps its shape).
- `src/ctf/global.nim`: skin offsets in the soldier and articulated rig-head
  sprite-id helpers, `(team, skin, rot)` at every visible head call site, and
  used-skins-only registration and render-cache prewarming.
- `data/soldier_red_crown.png`, `data/soldier_blue_crown.png`, and
  `data/rig_real/{red,blue}/head_crown.png`: new art;
  `tools/generate_crown_skins.nim` generates them;
  `tools/dump_soldier_preview.nim` previews all skins.
- `docs/RULES.md`: one-liner — skins are cosmetic, label vocabulary unchanged.
- Tests: config parsing (missing / valid / invalid skin), the referenced global
  rig head differs for crown and default players, the sprite-id collision audit
  covers the new pools, and the label-contract canary stays green.

## Validation

Build the server and baseline bot. Run 16 bots with a config giving a few
slots `"skin": "crown"`; verify crowns in the global viewer and in a POV
client; confirm labels are byte-identical to today's; run with the current
unmodified `config.json` to prove nothing changed; expand an existing replay
to confirm no regression.

## Trade-offs

Each *used* skin adds 96 rasterized soldier sprite definitions (2 teams × 16
rotations × live/corpse/selected) to the init snapshot. The articulated
renderer lazily adds up to 32 skin-specific head definitions (2 teams × 16 aim
directions) when that skin is referenced; the rest of the rig stays shared.
The used-skins-only registration rule keeps this bounded if skins proliferate.
