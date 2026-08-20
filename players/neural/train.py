#!/usr/bin/env python3
"""Train the shared Emerg-ant MLP and emit the Nim deployment checkpoint.

The curriculum teaches only from the same local observation contract used by
the container. A short REINFORCE phase then optimizes two identical colonies in
a stigmergic foraging/contact world. No slot, global position, or team-wide
state enters the network. NumPy is the only dependency.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

PATCH = 5
CHANNELS = 7
PATCH_FEATURES = PATCH * PATCH * CHANNELS
INPUTS = PATCH_FEATURES + 10
HIDDEN = 48
OUTPUTS = 14
DEPLOY_TEMPERATURE = 0.35
MOVE_OFFSETS = np.array([0, 0, 1, 2, 3, 4, -3, -2, -1], dtype=np.int8)
DIRS = np.array(
    [[1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]],
    dtype=np.int16,
)
MOVE_VECTORS = np.array(
    [[0, 0], [1, 0], [math.sqrt(0.5), math.sqrt(0.5)], [0, 1],
     [-math.sqrt(0.5), math.sqrt(0.5)], [-1, 0],
     [-math.sqrt(0.5), -math.sqrt(0.5)], [0, -1],
     [math.sqrt(0.5), -math.sqrt(0.5)]],
    dtype=np.float32,
)


def feature(row: int, col: int, channel: int) -> int:
    return (row * PATCH + col) * CHANNELS + channel


def softmax(x: np.ndarray) -> np.ndarray:
    z = x - x.max(axis=-1, keepdims=True)
    exp = np.exp(z)
    return exp / exp.sum(axis=-1, keepdims=True)


def steering_moves(logits: np.ndarray) -> np.ndarray:
    """Match deployment's circular-mean decoder for persistent locomotion."""
    vectors = softmax(logits[:, :9] / DEPLOY_TEMPERATURE) @ MOVE_VECTORS
    angle = np.arctan2(vectors[:, 1], vectors[:, 0])
    moves = 1 + (np.rint(angle / (math.pi / 4)).astype(np.int16) % 8)
    moves[np.linalg.norm(vectors, axis=1) < 0.08] = 0
    return moves


class Policy:
    def __init__(self, rng: np.random.Generator):
        self.w1 = rng.normal(0, 0.08, (INPUTS, HIDDEN)).astype(np.float32)
        self.b1 = np.zeros(HIDDEN, np.float32)
        self.w2 = rng.normal(0, 0.08, (HIDDEN, OUTPUTS)).astype(np.float32)
        self.b2 = np.zeros(OUTPUTS, np.float32)
        self.m = [np.zeros_like(x) for x in self.params]
        self.v = [np.zeros_like(x) for x in self.params]
        self.adam_step = 0

    @property
    def params(self) -> list[np.ndarray]:
        return [self.w1, self.b1, self.w2, self.b2]

    def forward(self, x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        h = np.tanh(x @ self.w1 + self.b1)
        return h, h @ self.w2 + self.b2

    def adam(self, grads: list[np.ndarray], lr: float) -> None:
        self.adam_step += 1
        for p, g, m, v in zip(self.params, grads, self.m, self.v):
            np.clip(g, -2.0, 2.0, out=g)
            m *= 0.9
            m += 0.1 * g
            v *= 0.999
            v += 0.001 * g * g
            mh = m / (1.0 - 0.9**self.adam_step)
            vh = v / (1.0 - 0.999**self.adam_step)
            p += lr * mh / (np.sqrt(vh) + 1e-8)


def relative_move(side: float, forward: float) -> int:
    if side == 0 and forward == 0:
        return 0
    angle = math.atan2(side, forward)
    return 1 + (int(round(angle / (math.pi / 4))) % 8)


def curriculum(rng: np.random.Generator, count: int) -> tuple[np.ndarray, np.ndarray]:
    """Generate varied local situations and local teacher actions.

    This is behavioral initialization, not deployed logic. The policy-gradient
    phase is free to alter every weight from the colony reward.
    """
    x = np.zeros((count, INPUTS), np.float32)
    labels = np.zeros((count, 3), np.int16)
    for n in range(count):
        # Homing remains heavily represented. In the physical Coworld a carrier
        # must hold a heading for hundreds of ticks and enter a compact nest
        # disc; under-weighting this branch produces attractive foraging that
        # never converts into a score.
        carrying = rng.random() < 0.4
        bite_ready = rng.random() < 0.8
        x[n, PATCH_FEATURES] = carrying
        x[n, PATCH_FEATURES + 1] = bite_ready
        home_forward, home_side = rng.uniform(-1, 1, 2)
        x[n, PATCH_FEATURES + 2 : PATCH_FEATURES + 4] = [home_forward, home_side]
        x[n, PATCH_FEATURES + 4] = min(1.0, math.hypot(home_forward, home_side))
        phase = rng.uniform(0, 2 * math.pi)
        x[n, PATCH_FEATURES + 5 : PATCH_FEATURES + 7] = [math.sin(phase), math.cos(phase)]

        # Available fruit emits a global odor bearing. Distance is deliberately
        # compressed to a weak intensity: antennae say which way and roughly
        # how strong, while walls/ants/patch contact remain in the local grid.
        odor_side = odor_forward = odor_strength = 0.0
        if not carrying and rng.random() < 0.94:
            odor_angle = rng.uniform(-math.pi, math.pi)
            odor_forward = math.cos(odor_angle)
            odor_side = math.sin(odor_angle)
            odor_strength = rng.uniform(0.08, 0.75)
            x[n, PATCH_FEATURES + 7 : PATCH_FEATURES + 10] = [
                odor_forward, odor_side, odor_strength,
            ]

        # Sparse walls and nearby ants make the imitation curriculum teach
        # obstacle avoidance and contact without exposing world coordinates.
        for _ in range(rng.integers(0, 5)):
            r, c = rng.integers(0, PATCH, 2)
            x[n, feature(r, c, 0)] = 1
        enemy_contact = rng.random() < 0.16
        if enemy_contact:
            x[n, feature(2, 2, 2)] = 1

        food_cells: list[tuple[int, int]] = []
        trail_cells: list[tuple[int, int]] = []
        if not carrying and rng.random() < 0.55:
            for _ in range(rng.integers(1, 4)):
                r, c = rng.integers(0, PATCH, 2)
                x[n, feature(r, c, 3)] = 1
                food_cells.append((r, c))
        elif not carrying and rng.random() < 0.65:
            for _ in range(rng.integers(1, 5)):
                r, c = rng.integers(0, PATCH, 2)
                x[n, feature(r, c, 5)] = rng.uniform(0.4, 1)
                trail_cells.append((r, c))

        if carrying:
            side, forward = home_side, home_forward
            labels[n] = [relative_move(side, forward), 2, 0]
        elif food_cells or trail_cells:
            cells = food_cells or trail_cells
            r, c = min(cells, key=lambda rc: (rc[0] - 2) ** 2 + (rc[1] - 2) ** 2)
            labels[n] = [relative_move(c - 2, 2 - r), 1, int(enemy_contact and bite_ready)]
        elif odor_strength > 0:
            labels[n] = [relative_move(odor_side, odor_forward), 1,
                         int(enemy_contact and bite_ready)]
        else:
            # Uncued locomotion is a correlated-random-walk motor primitive in
            # deployment. The shared net learns the task-directed reactions.
            labels[n] = [1, 1, int(enemy_contact and bite_ready)]
        # If the intended cell is a wall, rotate one octant toward an open one.
        if labels[n, 0] != 0:
            offset = int(MOVE_OFFSETS[labels[n, 0]])
            for turn in range(8):
                candidate = (offset + (turn + 1) // 2 * (-1 if turn % 2 else 1)) % 8
                d = DIRS[candidate]
                row, col = 2 - int(np.sign(d[1])), 2 + int(np.sign(d[0]))
                if x[n, feature(row, col, 0)] == 0:
                    labels[n, 0] = 1 + candidate
                    break
    return x, labels


def imitate(policy: Policy, rng: np.random.Generator, samples: int, epochs: int) -> None:
    x, y = curriculum(rng, samples)
    batch = 1024
    for _ in range(epochs):
        for start in rng.permutation(np.arange(0, samples, batch)):
            xb = x[start : start + batch]
            yb = y[start : start + batch]
            h, logits = policy.forward(xb)
            dl = np.zeros_like(logits)
            for head, (lo, hi) in enumerate(((0, 9), (9, 12), (12, 14))):
                probs = softmax(logits[:, lo:hi])
                one = np.zeros_like(probs)
                one[np.arange(len(xb)), yb[:, head]] = 1
                dl[:, lo:hi] = (one - probs) / len(xb)
            old_w2 = policy.w2.copy()
            dh = (dl @ old_w2.T) * (1 - h * h)
            policy.adam([xb.T @ dh, dh.sum(0), h.T @ dl, dl.sum(0)], 0.002)


class ColonyWorld:
    """Small transfer world containing the same local ALife mechanics."""

    size = 21
    ants_per_team = 5
    ants = ants_per_team * 2

    def __init__(self, rng: np.random.Generator, episodes: int):
        self.rng = rng
        self.episodes = episodes
        self.home = np.zeros((episodes, 2, 2), np.int16)
        self.home[:, 0] = [2, self.size // 2]
        self.home[:, 1] = [self.size - 3, self.size // 2]
        self.pos = np.zeros((episodes, self.ants, 2), np.int16)
        self.heading = np.zeros((episodes, self.ants), np.int8)
        self.phase_offset = rng.integers(0, 240, (episodes, self.ants), dtype=np.int16)
        self.carrying = np.zeros((episodes, self.ants), bool)
        self.team = np.tile(np.repeat(np.arange(2), self.ants_per_team), (episodes, 1))
        self.pheromone = np.zeros((episodes, 2, 2, self.size, self.size), np.float32)
        self.food = np.zeros((episodes, self.size, self.size), np.int16)
        self.walls = np.zeros((episodes, self.size, self.size), bool)
        self.deliveries = np.zeros((episodes, 2), np.int16)
        self.reset()

    def reset(self) -> None:
        self.pheromone.fill(0)
        self.food.fill(0)
        self.walls.fill(0)
        self.deliveries.fill(0)
        self.carrying.fill(False)
        self.walls[:, [0, -1], :] = True
        self.walls[:, :, [0, -1]] = True
        for e in range(self.episodes):
            # Light mirrored cover, followed by fruit distributed through the
            # interior rather than fixed on one center line.
            for _ in range(7):
                x = int(self.rng.integers(6, self.size // 2))
                y = int(self.rng.integers(2, self.size - 2))
                self.walls[e, y, x] = self.walls[e, y, self.size - 1 - x] = True
            candidates = np.array([
                (x, y)
                for y in range(3, self.size - 3)
                for x in range(4, self.size - 4)
                if not self.walls[e, y, x]
            ], np.int16)
            for x, y in candidates[
                self.rng.choice(len(candidates), 8, replace=False)
            ]:
                self.food[e, y, x] = 20
            for a in range(self.ants):
                team = self.team[e, a]
                self.pos[e, a] = self.home[e, team] + [0, (a % self.ants_per_team) - 2]
                self.heading[e, a] = 0 if team == 0 else 4

    def observe(self, tick: int) -> np.ndarray:
        obs = np.zeros((self.episodes, self.ants, INPUTS), np.float32)
        for e in range(self.episodes):
            for a in range(self.ants):
                p = self.pos[e, a]
                heading = int(self.heading[e, a])
                f = DIRS[heading]
                right = DIRS[(heading + 2) % 8]
                for row in range(PATCH):
                    for col in range(PATCH):
                        q = p + f * (2 - row) + right * (col - 2)
                        x, y = int(q[0]), int(q[1])
                        if x < 0 or y < 0 or x >= self.size or y >= self.size or self.walls[e, y, x]:
                            obs[e, a, feature(row, col, 0)] = 1
                            continue
                        if self.food[e, y, x] > 0:
                            obs[e, a, feature(row, col, 3)] = 1
                        team = self.team[e, a]
                        obs[e, a, feature(row, col, 4)] = self.pheromone[e, team, 0, y, x]
                        obs[e, a, feature(row, col, 5)] = self.pheromone[e, team, 1, y, x]
                        obs[e, a, feature(row, col, 6)] = self.pheromone[e, 1 - team, :, y, x].max()
                        for other in range(self.ants):
                            if other == a or np.any(self.pos[e, other] != q):
                                continue
                            channel = 1 if self.team[e, other] == team else 2
                            obs[e, a, feature(row, col, channel)] = 1
                team = self.team[e, a]
                home_delta = self.home[e, team] - p
                hf = float(home_delta @ f) / self.size
                hs = float(home_delta @ right) / self.size
                phase = ((tick + int(self.phase_offset[e, a])) % 240) * 2 * math.pi / 240
                odor_forward = odor_side = odor_strength = 0.0
                if not self.carrying[e, a]:
                    food_yx = np.argwhere(self.food[e] > 0)
                    if len(food_yx):
                        nearest_yx = min(
                            food_yx,
                            key=lambda yx: np.linalg.norm(p - yx[::-1]),
                        )
                        odor = (nearest_yx[::-1] - p).astype(np.float32)
                        odor_dist = float(np.linalg.norm(odor))
                        if odor_dist > 0:
                            odor /= odor_dist
                            odor_forward = float(odor @ f)
                            odor_side = float(odor @ right)
                            odor_strength = 2.0 / (2.0 + odor_dist)
                obs[e, a, PATCH_FEATURES:] = [
                    self.carrying[e, a], 1, np.clip(hf, -1, 1), np.clip(hs, -1, 1),
                    min(1, np.linalg.norm(home_delta) / self.size), math.sin(phase), math.cos(phase),
                    odor_forward, odor_side, odor_strength,
                ]
        return obs

    def step(self, moves: np.ndarray, marks: np.ndarray, bites: np.ndarray) -> np.ndarray:
        reward = np.full((self.episodes, self.ants), -0.002, np.float32)
        self.pheromone *= 0.975
        for e in range(self.episodes):
            for a in range(self.ants):
                team = self.team[e, a]
                if self.carrying[e, a]:
                    before_goal = np.linalg.norm(self.pos[e, a] - self.home[e, team])
                else:
                    food_yx = np.argwhere(self.food[e] > 0)
                    before_goal = (
                        min(np.linalg.norm(self.pos[e, a] - yx[::-1]) for yx in food_yx)
                        if len(food_yx) else 0.0
                    )
                if marks[e, a] > 0:
                    x, y = self.pos[e, a]
                    self.pheromone[e, team, marks[e, a] - 1, y, x] = 1
                move = int(moves[e, a])
                if move:
                    heading = (int(self.heading[e, a]) + int(MOVE_OFFSETS[move])) % 8
                    q = self.pos[e, a] + DIRS[heading]
                    x, y = int(q[0]), int(q[1])
                    if not self.walls[e, y, x]:
                        self.pos[e, a] = q
                        self.heading[e, a] = heading
                    else:
                        reward[e, a] -= 0.02
                if self.carrying[e, a]:
                    after_goal = np.linalg.norm(self.pos[e, a] - self.home[e, team])
                else:
                    food_yx = np.argwhere(self.food[e] > 0)
                    after_goal = (
                        min(np.linalg.norm(self.pos[e, a] - yx[::-1]) for yx in food_yx)
                        if len(food_yx) else before_goal
                    )
                reward[e, a] += 0.015 * float(before_goal - after_goal)
                x, y = self.pos[e, a]
                if not self.carrying[e, a] and self.food[e, y, x] > 0:
                    self.food[e, y, x] -= 1
                    self.carrying[e, a] = True
                    reward[e, a] += 0.5
                if self.carrying[e, a] and np.max(np.abs(self.pos[e, a] - self.home[e, team])) <= 1:
                    self.carrying[e, a] = False
                    self.deliveries[e, team] += 1
                    reward[e, a] += 5
                    reward[e, self.team[e] == team] += 0.15
                if bites[e, a]:
                    enemies = np.where(self.team[e] != team)[0]
                    for victim in enemies:
                        if np.max(np.abs(self.pos[e, victim] - self.pos[e, a])) <= 1:
                            if self.carrying[e, victim]:
                                vx, vy = self.pos[e, victim]
                                self.food[e, vy, vx] += 1
                            self.carrying[e, victim] = False
                            self.pos[e, victim] = self.home[e, 1 - team]
                            reward[e, a] += 0.2
                            break
        return reward


def eval_key(evaluation: dict[str, float]) -> tuple[float, float]:
    return (
        evaluation["episodes_with_delivery_fraction"],
        evaluation["mean_total_deliveries"],
    )


def reinforce(
    policy: Policy,
    rng: np.random.Generator,
    updates: int,
    episodes: int,
    horizon: int,
    eval_seed: int,
) -> tuple[list[float], int, dict[str, float]]:
    history: list[float] = []
    best_update = 0
    best_params = [p.copy() for p in policy.params]
    best_eval = deterministic_eval(policy, eval_seed, episodes=16)
    print(f"initializer eval: {best_eval}")
    for update in range(updates):
        world = ColonyWorld(rng, episodes)
        xs: list[np.ndarray] = []
        hs: list[np.ndarray] = []
        probs_all: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
        actions: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
        rewards: list[np.ndarray] = []
        for tick in range(horizon):
            x = world.observe(tick)
            flat = x.reshape(-1, INPUTS)
            h, logits = policy.forward(flat)
            pm, pp, pb = softmax(logits[:, :9]), softmax(logits[:, 9:12]), softmax(logits[:, 12:14])
            sample = lambda p: np.array([rng.choice(p.shape[1], p=row) for row in p], np.int16)
            am, ap, ab = sample(pm), sample(pp), sample(pb)
            reward = world.step(am.reshape(episodes, -1), ap.reshape(episodes, -1), ab.reshape(episodes, -1))
            xs.append(flat)
            hs.append(h)
            probs_all.append((pm, pp, pb))
            actions.append((am, ap, ab))
            rewards.append(reward.reshape(-1))
            if tick == horizon // 2:
                world.pheromone.fill(0)  # wash: recovery is part of selection

        returns = np.zeros((horizon, episodes * world.ants), np.float32)
        running = np.zeros(episodes * world.ants, np.float32)
        for tick in reversed(range(horizon)):
            running = rewards[tick] + 0.985 * running
            returns[tick] = running
        advantage = (returns - returns.mean()) / (returns.std() + 1e-5)
        dl_parts, x_parts, h_parts = [], [], []
        for tick in range(horizon):
            dl = np.zeros((episodes * world.ants, OUTPUTS), np.float32)
            for (lo, hi), p, a in zip(((0, 9), (9, 12), (12, 14)), probs_all[tick], actions[tick]):
                one = np.zeros_like(p)
                one[np.arange(len(p)), a] = 1
                dl[:, lo:hi] = (one - p) * advantage[tick, :, None]
            dl_parts.append(dl)
            x_parts.append(xs[tick])
            h_parts.append(hs[tick])
        dl = np.concatenate(dl_parts) / (horizon * episodes * world.ants)
        x = np.concatenate(x_parts)
        h = np.concatenate(h_parts)
        old_w2 = policy.w2.copy()
        dh = (dl @ old_w2.T) * (1 - h * h)
        policy.adam([x.T @ dh, dh.sum(0), h.T @ dl, dl.sum(0)], 0.00035)
        score = float(world.deliveries.mean())
        history.append(score)
        if update % 10 == 0 or update + 1 == updates:
            print(f"reinforce {update + 1:03d}/{updates}: deliveries/team={score:.3f}")
        if (update + 1) % 5 == 0 or update + 1 == updates:
            evaluation = deterministic_eval(policy, eval_seed, episodes=16)
            print(f"eval after update {update + 1:03d}: {evaluation}")
            if eval_key(evaluation) > eval_key(best_eval):
                best_update = update + 1
                best_eval = evaluation
                best_params = [p.copy() for p in policy.params]
    for parameter, best in zip(policy.params, best_params):
        parameter[...] = best
    return history, best_update, best_eval


def deterministic_eval(policy: Policy, seed: int, episodes: int = 32, horizon: int = 300) -> dict[str, float]:
    rng = np.random.default_rng(seed)
    world = ColonyWorld(rng, episodes)
    for tick in range(horizon):
        flat = world.observe(tick).reshape(-1, INPUTS)
        _, logits = policy.forward(flat)
        moves = steering_moves(logits).reshape(episodes, -1)
        marks = logits[:, 9:12].argmax(1).reshape(episodes, -1)
        bites = logits[:, 12:14].argmax(1).reshape(episodes, -1)
        world.step(moves, marks, bites)
        if tick == horizon // 2:
            world.pheromone.fill(0)
    totals = world.deliveries.sum(1)
    return {
        "episodes": episodes,
        "horizon": horizon,
        "mean_total_deliveries": round(float(totals.mean()), 4),
        "episodes_with_delivery_fraction": round(float((totals > 0).mean()), 4),
        "max_total_deliveries": int(totals.max()),
    }


def nim_values(values: np.ndarray) -> str:
    flat = values.reshape(-1)
    chunks = []
    for start in range(0, len(flat), 8):
        chunks.append("    " + ", ".join(f"{float(v):.8g}'f32" for v in flat[start : start + 8]))
    return ",\n".join(chunks)


def save(policy: Policy, output: Path, nim_output: Path, metadata: dict) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "format": "emerg-ant-mlp-v1",
        "input_size": INPUTS,
        "hidden_size": HIDDEN,
        "output_size": OUTPUTS,
        "metadata": metadata,
        "w1": policy.w1.reshape(-1).tolist(),
        "b1": policy.b1.tolist(),
        "w2": policy.w2.reshape(-1).tolist(),
        "b2": policy.b2.tolist(),
    }
    output.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
    name = (
        f"local-colony-seed{metadata['seed']}"
        f"-best{metadata['selected_reinforce_update']}"
    )
    nim_output.write_text(
        "## GENERATED by players/neural/train.py; do not edit by hand.\n\n"
        "const\n"
        f"  CheckpointInputSize* = {INPUTS}\n"
        f"  CheckpointHiddenSize* = {HIDDEN}\n"
        f"  CheckpointOutputSize* = {OUTPUTS}\n"
        f"  CheckpointName* = \"{name}\"\n"
        f"  CheckpointW1*: array[CheckpointInputSize * CheckpointHiddenSize, float32] = [\n{nim_values(policy.w1)}\n  ]\n"
        f"  CheckpointB1*: array[CheckpointHiddenSize, float32] = [\n{nim_values(policy.b1)}\n  ]\n"
        f"  CheckpointW2*: array[CheckpointHiddenSize * CheckpointOutputSize, float32] = [\n{nim_values(policy.w2)}\n  ]\n"
        f"  CheckpointB2*: array[CheckpointOutputSize, float32] = [\n{nim_values(policy.b2)}\n  ]\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=260819)
    parser.add_argument("--curriculum-samples", type=int, default=50000)
    parser.add_argument("--curriculum-epochs", type=int, default=1)
    parser.add_argument("--reinforce-updates", type=int, default=20)
    parser.add_argument("--episodes", type=int, default=6)
    parser.add_argument("--horizon", type=int, default=180)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("players/neural/checkpoint.json"))
    parser.add_argument(
        "--nim-output", type=Path,
        default=Path("players/baseline/baseline/neural_ant_checkpoint.nim"),
    )
    args = parser.parse_args()
    if args.smoke:
        args.curriculum_samples, args.curriculum_epochs = 512, 1
        args.reinforce_updates, args.episodes, args.horizon = 1, 2, 12
    rng = np.random.default_rng(args.seed)
    policy = Policy(rng)
    imitate(policy, rng, args.curriculum_samples, args.curriculum_epochs)
    history, best_update, selection_eval = reinforce(
        policy, rng, args.reinforce_updates, args.episodes, args.horizon,
        args.seed + 1,
    )
    evaluation = deterministic_eval(policy, args.seed + 1)
    metadata = {
        "seed": args.seed,
        "curriculum_samples": args.curriculum_samples,
        "curriculum_epochs": args.curriculum_epochs,
        "reinforce_updates": args.reinforce_updates,
        "episodes_per_update": args.episodes,
        "horizon": args.horizon,
        "final_training_deliveries_per_team": round(history[-1], 4),
        "selected_reinforce_update": best_update,
        "selection_evaluation": selection_eval,
        "evaluation": evaluation,
        "observation": "5x5x7 egocentric patch + carry/bite/wake displacement/clock + global food-odor bearing/intensity",
        "slot_feature": False,
        "deployment_temperature": DEPLOY_TEMPERATURE,
    }
    save(policy, args.output, args.nim_output, metadata)
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
