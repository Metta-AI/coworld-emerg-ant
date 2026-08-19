# Build an Emerg-ant policy

This is the agent-facing path from a repository checkout to a league-ready
policy image. A policy is a Docker image that connects one bot process to one
seat. Softmax starts the image for every seat assigned to the policy.

## 1. Read the contract

Before changing code, read:

- [Emerg-ant rules](EMERG_ANT.md) for the food race and pheromone mechanics;
- [wire protocol](PROTOCOL.md) for Sprite v1 frames and input masks;
- [baseline policy notes](../players/baseline/README.md) for navigation, fog,
  aiming, and role assignment;
- [`decide`](../players/baseline/baseline.nim), the baseline's decision loop.

The baseline predates Emerg-ant and is intentionally only a starting point. Its
movement, pathfinding, fog memory, combat, and protocol handling are useful,
but strategy text that refers to hearts or single-capture CTF must be adapted
to repeated food returns.

The policy-visible labels specific to this mode are:

```text
food red cache
food blue cache
food red carried
food blue carried
pheromone red scout
pheromone blue scout
pheromone red food
pheromone blue food
```

Also consume the shared `self ...`, `player ...`, `own aim ...`, walkability,
weapon, and pickup labels documented by the protocol. Sprite frames are deltas:
retain objects until the stream deletes or clears them. Do not send Player
Ready (`0x85`) in league play.

## 2. Choose colony behavior

Optimize food returns, not individual kills. A useful first policy assigns the
eight same-team seats deterministic roles:

1. Two scouts discover short routes and lay ordinary trail.
2. Three foragers follow promising food trail, raid the enemy cache, and choose
   a covered return route.
3. One escort follows a food carrier and screens nearby enemies.
4. Two defenders patrol the nest and erase or exploit enemy trail.

Treat a bright `pheromone <team> food` trail as evidence of a recent carrier,
not a guaranteed current route. Enemy deposits can cancel it. Keep navigation
fallbacks for stale, erased, blocked, or deliberately deceptive trails.

Combat is instrumental: shoot a carrier, clear a route, or defend the nest.
Standing still for kills while the opponent returns food is a losing policy.

## 3. Implement

Fork this repository and edit `players/baseline/baseline.nim`. Keep the socket,
frame-draining, aim correction, and walkability code intact until a replacement
has tests. Put new policy modules under `players/baseline/baseline/`, or copy
the complete baseline directory to a new directory and update its Dockerfile
paths.

Policy code should be deterministic for a given observation history and seat.
Use the assigned seat for role selection; do not depend on process start order,
wall-clock timing, or access to another policy container.

Build the Linux policy image from the repository root:

```bash
docker build --platform linux/amd64 \
  -f players/baseline/Dockerfile \
  -t emerg-ant-policy:dev .
```

The image must start its player from `CMD` or `ENTRYPOINT`. The supplied image
runs `/bin/baseline`.

## 4. Test and audit full episodes

First verify the game and protocol tests:

```bash
nimby --global sync nimby.lock
nim c -d:release -r tests/tests.nim
```

Then run the policy in all sixteen seats against the published Coworld:

```bash
uvx --from "coworld[auth]" coworld scrimmage \
  cow_82623c46-cd6a-4e39-a271-5874949d10ff \
  emerg-ant-policy:dev \
  --variant emerg-ant \
  --output-dir build/scrimmage \
  --verify-replay
```

Review complete replays, not only final scores. For several episodes, record:

- colony food returns and time of each return;
- which roles reached the enemy cache;
- carrier deaths and whether an escort was present;
- pheromone paths created, followed, cancelled, and abandoned;
- time spent stuck, idle, fighting without objective value, or following stale
  trail.

Make one behavioral change at a time and rerun the same evaluation set before
promoting it. A policy is ready to upload only when it completes full matches,
produces valid replays, and improves food-return results without new timeouts or
disconnects.

## 5. Upload and submit

Authenticate once, then upload the tested image under a unique policy name:

```bash
uvx --from "coworld[auth]" softmax login
uvx --from "coworld[auth]" coworld upload-policy \
  emerg-ant-policy:dev --name YOUR_POLICY_NAME
```

The upload prints a version such as `YOUR_POLICY_NAME:v1`. Once a Softmax team
administrator has promoted the Coworld to a league, submit that exact version:

```bash
uvx --from "coworld[auth]" coworld submit \
  YOUR_POLICY_NAME:v1 \
  --league LEAGUE_ID \
  --no-open-browser
```

Do not submit an unversioned local tag, and do not rebuild an image after the
scrimmage without testing the rebuilt digest.

## Coding-agent completion checklist

An agent implementing a policy should leave behind:

- the policy source and Docker build path;
- a concise mechanics/role contract;
- commands and results for tests and scrimmages;
- replay-backed examples of the first observed failure and the behavior that
  corrected it;
- the uploaded policy name and immutable version, if upload was requested;
- the league submission result, if a league ID and submission authority were
  available.
