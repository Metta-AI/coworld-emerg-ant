## Shared neural controller for the Emerg-ant colony.
##
## The deployed policy is deliberately tiny and memoryless, like NAnts: every
## replica evaluates the same MLP from an egocentric local patch, displacement
## from its own wake position, carried-food state, bite state, and a clock.
## This module has no game types, slot, map coordinates, or network client.

import std/math
import neural_ant_checkpoint

const
  AntPatchRadius* = 2
  AntPatchWidth* = AntPatchRadius * 2 + 1
  AntChannels* = 7
  AntPatchFeatures* = AntPatchWidth * AntPatchWidth * AntChannels
  AntScalarFeatures* = 10
  AntInputSize* = AntPatchFeatures + AntScalarFeatures
  AntHiddenSize* = CheckpointHiddenSize
  AntOutputSize* = 14
  AntCheckpointName* = CheckpointName
  AntSamplingTemperature* = 0.35'f32

  AntMoveStay* = 0
  AntMoveForward* = 1
  AntMoveForwardRight* = 2
  AntMoveRight* = 3
  AntMoveBackRight* = 4
  AntMoveBack* = 5
  AntMoveBackLeft* = 6
  AntMoveLeft* = 7
  AntMoveForwardLeft* = 8

type
  AntInput* = array[AntInputSize, float32]
  AntLogits* = array[AntOutputSize, float32]
  AntDecision* = object
    move*: int               ## 0 stay; 1..8 are egocentric octants
    mark*: int               ## 0 none, 1 scout/home, 2 food
    bite*: bool

static:
  doAssert CheckpointInputSize == AntInputSize
  doAssert CheckpointOutputSize == AntOutputSize

proc featureIndex*(row, col, channel: int): int {.inline.} =
  ((row * AntPatchWidth + col) * AntChannels) + channel

proc scalarIndex*(scalar: int): int {.inline.} =
  AntPatchFeatures + scalar

proc inferAnt*(input: AntInput): AntLogits =
  var hidden: array[AntHiddenSize, float32]
  for j in 0 ..< AntHiddenSize:
    var activation = CheckpointB1[j]
    for i in 0 ..< AntInputSize:
      activation += input[i] * CheckpointW1[i * AntHiddenSize + j]
    hidden[j] = tanh(activation)
  for k in 0 ..< AntOutputSize:
    result[k] = CheckpointB2[k]
    for j in 0 ..< AntHiddenSize:
      result[k] += hidden[j] * CheckpointW2[j * AntOutputSize + k]

proc argmax(logits: AntLogits, first, pastLast: int): int =
  result = first
  for i in first + 1 ..< pastLast:
    if logits[i] > logits[result]:
      result = i

proc chooseAntAction*(input: AntInput): AntDecision =
  ## Deterministic tournament inference. Training samples these categorical
  ## heads; deployment takes their maxima for reproducible replay bytes.
  let logits = inferAnt(input)
  result.move = logits.argmax(0, 9)
  result.mark = logits.argmax(9, 12) - 9
  result.bite = logits.argmax(12, 14) == 13

proc steerAntAction*(input: AntInput): AntDecision =
  ## Convert the learned movement distribution into its circular mean. The
  ## old deployment sampled a fresh octant every 24 Hz, so even a strong
  ## preference for forward motion became a diffusive random walk. Expected
  ## steering preserves uncertainty as a smooth heading while keeping turns,
  ## pheromone choice, and contact attack entirely network-derived.
  let logits = inferAnt(input)
  var peak = logits[0]
  for i in 1 ..< 9:
    peak = max(peak, logits[i])
  var
    total = 0.0'f32
    forward = 0.0'f32
    side = 0.0'f32
  for i in 0 ..< 9:
    let weight = exp((logits[i] - peak) / AntSamplingTemperature)
    total += weight
    case i
    of AntMoveForward: forward += weight
    of AntMoveForwardRight:
      forward += weight * 0.70710677'f32
      side += weight * 0.70710677'f32
    of AntMoveRight: side += weight
    of AntMoveBackRight:
      forward -= weight * 0.70710677'f32
      side += weight * 0.70710677'f32
    of AntMoveBack: forward -= weight
    of AntMoveBackLeft:
      forward -= weight * 0.70710677'f32
      side -= weight * 0.70710677'f32
    of AntMoveLeft: side -= weight
    of AntMoveForwardLeft:
      forward += weight * 0.70710677'f32
      side -= weight * 0.70710677'f32
    else: discard
  forward /= total
  side /= total
  if hypot(forward, side) < 0.08'f32:
    result.move = AntMoveStay
  else:
    var octant = int(round(arctan2(side, forward) / (PI.float32 / 4.0'f32))) mod 8
    if octant < 0:
      octant += 8
    result.move = 1 + octant
  result.mark = logits.argmax(9, 12) - 9
  result.bite = logits.argmax(12, 14) == 13

proc categorical(logits: AntLogits, first, pastLast: int, random: float32): int =
  var peak = logits[first]
  for i in first + 1 ..< pastLast:
    peak = max(peak, logits[i])
  var total = 0.0'f32
  for i in first ..< pastLast:
    total += exp((logits[i] - peak) / AntSamplingTemperature)
  let threshold = clamp(random, 0.0'f32, 0.99999994'f32) * total
  var cumulative = 0.0'f32
  for i in first ..< pastLast:
    cumulative += exp((logits[i] - peak) / AntSamplingTemperature)
    if cumulative >= threshold:
      return i
  pastLast - 1

proc sampleAntAction*(input: AntInput, random: array[3, float32]): AntDecision =
  ## NAnts-style categorical turn sampling. Callers supply replay-deterministic
  ## random values; the network and observation remain shared and memoryless.
  let logits = inferAnt(input)
  result.move = logits.categorical(0, 9, random[0])
  result.mark = logits.categorical(9, 12, random[1]) - 9
  result.bite = logits.categorical(12, 14, random[2]) == 13
