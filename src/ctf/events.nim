## The tier-2 event WIRE FORMAT, shared by live emission and re-simulation.
##
## This lived in `tools/extract_events.nim` when re-simulating a stored replay
## was the only way to obtain an event stream. The live server now emits the
## same events as it plays (see `server.nim`), and both paths must produce
## byte-identical rows: a consumer cannot be asked to tell them apart, and a
## second serializer would drift the moment a field is added.
##
## `SimEvent` never enters `gameHash`, so nothing here can affect determinism.

import std/json

import ./sim

proc key*(kind: SimEventKind): string =
  ## Returns the JSON event key for one tier-2 event kind.
  case kind
  of Shot: "shot"
  of Hit: "hit"
  of Damage: "damage"
  of Kill: "kill"
  of Death: "death"
  of FlagSteal: "flag_steal"
  of FlagReturn: "flag_return"
  of Capture: "capture"
  of Respawn: "respawn"
  of Heal: "heal"
  of PhaseChange: "phase"
  of GunTrigger: "gun_trigger"
  of ShotImpact: "shot_impact"
  of GrenadeThrow: "grenade_throw"
  of GrenadeImpact: "grenade_impact"
  of SprayUse: "spray_use"
  of Pickup: "item_pickup"
  of ShoutEvent: "shout"

proc jsonRow*(event: SimEvent): JsonNode =
  ## Returns one JSON-lines row for a tier-2 sim event.
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["source"] = %event.source
  result["target"] = %event.target
  result["weapon"] = %event.weapon
  result["amount"] = %event.amount
  result["hp"] = %event.hp
  result["blocked"] = %event.blocked
  result["x"] = %event.x
  result["y"] = %event.y
  result["action_id"] = %event.actionId
  result["heading_brads"] = %event.headingBrads
  result["distance"] = %event.distance
  result["item"] = %event.item
  result["content"] = %event.content
  result["damages"] = newJArray()
  for damage in event.damages:
    result["damages"].add(%*{
      "slot": damage.slot,
      "amount": damage.amount,
      "hp": damage.hp,
      "blocked": damage.blocked
    })

proc eventsJsonl*(
    events: openArray[SimEvent], ticks: int, summaryExtra: JsonNode = nil
): string =
  ## Returns the full JSON-lines stream: one row per event, then a summary.
  ##
  ## The trailing summary row is part of the contract, not decoration — it is
  ## how a reader distinguishes "this episode had no events" from "the file was
  ## truncated", and it carries the GameVersion the events were produced under
  ## so a consumer never has to infer it.
  ##
  ## `summaryExtra` merges extra keys into that row for a producer that knows
  ## more than the event stream does — the offline extractor attaches the
  ## episode's roster and outcome there. The four keys above are always
  ## present, so a reader can treat everything else as optional.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
