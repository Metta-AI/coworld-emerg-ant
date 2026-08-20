# Emerg-ant v0.2: Two Brains, 32 Bodies

## Thesis

Emerg-ant v0.2 is a competitive artificial-life experiment, not a reskinned
capture-the-flag match. Two policies each inhabit a colony of 16 identical
ants. Every seat runs an independent copy of its colony policy. There is no
manager process, shared hidden state, or global dynamic-resource feed.

The platform currently supports at most 32 independently controlled seats, so
v0.2 uses 16 ants per colony. The controller contract deliberately remains
replica-friendly so a later host can raise the body count without changing the
policy idea.

## Rules

- Two neutral food patches sit on the arena center line. Either colony may
  harvest either patch by touch.
- An ant carries one food item at a time. Delivering it to that ant's home
  endzone scores one forage point. The emptied patch regrows after a fixed
  delay; food is finite at every instant rather than an enemy-owned cache.
- `B` deposits a home/scout pheromone and `C` deposits a food pheromone. A
  held button can deposit at most once per `PheromoneStepTicks`. Marks expire,
  opposing deposits cancel locally, and the configured mid-match wash removes
  the whole field once to measure colony recovery.
- `A` is a mandible attack. A fresh press can damage only one enemy whose
  physical body is within `AntBiteRange`; there are no guns, grenades, spray
  cans, shields, med kits, or cardboard barriers in this mode. All bites on a
  tick resolve from one post-movement snapshot, so mutual kills are possible.
- The first colony to `forageGoal` wins. At the time limit, a unique forage
  leader wins and a tied score draws. A total colony wipe can still end the
  match, preserving the useful lives/respawn machinery from CTF.

## Observation contract

Static terrain remains known and map-absolute for Sprite protocol
compatibility. Dynamic ecology is local:

- other ants use the existing fog/vision contract;
- planted food and pheromone marks are emitted only within
  `antSenseRadius` of the observing ant;
- carried food is visible exactly when its carrier is visible;
- dead ants receive no dynamic player observation.

This is local sensing rather than a shared colony blackboard. An authored
policy can still maintain its own recurrent memory, but 16 replicas cannot
read one another's memory except through movement, contact, and marks left in
the environment.

## Input contract

| Input | Emerg-ant v0.2 meaning |
| --- | --- |
| D-pad | Move; the movement heading also points the ant's vision cone |
| A | Bite one enemy in physical contact |
| B | Deposit home/scout pheromone |
| C | Deposit food pheromone |
| Select | Reserved / no-op |

Ordinary CTF retains its existing input meanings and rules.

## Replay contract

The new food respawn state, explicit pheromone input, wash event, local
observation rules, and contact combat are replay-incompatible with GV44. The
change therefore claims GV45 after the 2026-08-19 remote-branch scan found
only GV44 on `origin/main` and no other claim at or above it.
