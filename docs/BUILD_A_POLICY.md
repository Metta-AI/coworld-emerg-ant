# Build an Emerg-ant policy

This is the agent-facing path from a repository checkout to a league-ready
policy image. A policy is a Docker image that connects one bot process to one
seat. Softmax starts the image for every seat assigned to the policy.

## Create a policy with your agent harness

Open this repository in Claude Code, Codex, or another coding-agent harness and
paste this prompt:

```text
Create a new competitive Emerg-ant policy from players/baseline. Do not change
the game server or rules. First read docs/EMERG_ANT.md, docs/PROTOCOL.md,
docs/BUILD_A_POLICY.md, and players/baseline/README.md, then inspect complete
baseline replays or run local scrimmages before designing the policy.

The match is always one policy versus one policy, with several connected copies
of each policy forming a colony. A colony starts with one immobile queen and one
worker; every food returned to the queen activates one dormant copy. All living
ants smell the positions of loose food, but must navigate around walls to reach
it. Food then reappears elsewhere. The queen can bite but cannot move, and the
whole colony dies if she is killed. There are no guns or items: damage happens
only when enemy ants physically touch and A is held.

Implement a deterministic policy that (1) identifies queen versus worker from
the documented labels, (2) sends workers to sensed food using walkability-aware
navigation and a stuck-recovery fallback, (3) returns carried food to the own
queen, (4) uses public scout/food pheromones without blindly following stale
trails, and (5) physically defends or attacks queens when worthwhile. Ensure
newly hatched copies can choose useful roles without private communication.

Put the policy in a new players/<policy-name>/ directory with its own Dockerfile
and README. Add focused tests, build the linux/amd64 image, run full-episode
scrimmages against the baseline, inspect the replays, and report food returns,
queen survival, stuck time, wins/losses, and the exact commands used. Do not
upload or submit anything unless I explicitly authorize it.
```

## 1. Read the contract

Before changing code, read:

- [Emerg-ant rules](EMERG_ANT.md) for the food race and pheromone mechanics;
- [wire protocol](PROTOCOL.md) for Sprite v1 frames and input masks;
- [baseline policy notes](../players/baseline/README.md) for navigation, fog,
  aiming, and role assignment;
- [`decide`](../players/baseline/baseline.nim), the baseline's decision loop.

The baseline contains a simple search/forage controller and remains only a
starting point. Its movement, pathfinding, fog memory, and protocol handling are
useful; stronger role selection, route choice, defense, and stuck recovery are
the competitive work.

The policy-visible labels specific to this mode are:

```text
food patch
food carried
weapon mandibles
pheromone red scout
pheromone blue scout
pheromone red food
pheromone blue food
queen red left
queen red right
self queen red left
self queen red right
```

Also consume the shared `self ...`, `player ...`, `own aim ...`, and walkability
labels documented by the protocol. There are no item labels in Emerg-ant.
Sprite frames are deltas:
retain objects until the stream deletes or clears them. Do not send Player
Ready (`0x85`) in league play.

## 2. Choose colony behavior

Optimize food returns and queen survival, not individual kills. At the opening
only the queen and one worker are alive. As deliveries hatch more copies, use
stable seat identity and current observations to expand into scouts, foragers,
escorts, and queen defenders. Every copy runs the same network/program and has
no private colony channel, so role allocation must work from public state and
deterministic identity.

Treat `food patch` as a scent target: it gives the current location, not a free
path through walls. Treat a bright `pheromone <team> food` trail as evidence of
a recent carrier, not a guaranteed current route. Enemy deposits can cancel it.
Keep navigation fallbacks for stale, erased, blocked, or deceptive trails.

Combat is instrumental and strictly physical. Approach a carrier, hold A only
once bodies touch, then decide whether to keep fighting or resume foraging.
There is no value in aiming for a distant shot because the engine cannot create
one. Standing still for kills while the opponent returns food is a losing policy.

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
- which roles discovered each new food position;
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
