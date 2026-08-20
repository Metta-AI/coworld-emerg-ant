## The shipped Emerg-ant checkpoint matches its portable JSON source and the
## controller surface cannot accidentally regain slot/global-map features.

import std/[json, math, os, strutils]
import ../players/baseline/baseline/neural_ant

const NeuralSource = staticRead(
  "../players/baseline/baseline/neural_ant.nim")

static:
  doAssert not NeuralSource.contains(".slot")
  doAssert not NeuralSource.contains("MapW")
  doAssert AntInputSize == 5 * 5 * 7 + 7

block generated_checkpoint_matches_json:
  let path = currentSourcePath().parentDir().parentDir() /
    "players" / "neural" / "checkpoint.json"
  let checkpoint = parseFile(path)
  doAssert checkpoint["format"].getStr == "emerg-ant-mlp-v1"
  doAssert checkpoint["input_size"].getInt == AntInputSize
  doAssert checkpoint["hidden_size"].getInt == AntHiddenSize
  doAssert checkpoint["output_size"].getInt == AntOutputSize
  doAssert checkpoint["metadata"]["slot_feature"].getBool == false
  doAssert checkpoint["metadata"]["reinforce_updates"].getInt > 0
  doAssert checkpoint["metadata"]["selected_reinforce_update"].getInt > 0
  let
    evaluation = checkpoint["metadata"]["evaluation"]
    deliveryFraction = evaluation["episodes_with_delivery_fraction"].getFloat
  doAssert deliveryFraction >= 0.9

  var input: AntInput
  for i in 0 ..< AntInputSize:
    input[i] = float32(((i * 17) mod 23) - 11) / 11.0
  let nimLogits = inferAnt(input)
  let
    w1 = checkpoint["w1"]
    b1 = checkpoint["b1"]
    w2 = checkpoint["w2"]
    b2 = checkpoint["b2"]
  var hidden = newSeq[float](AntHiddenSize)
  for j in 0 ..< AntHiddenSize:
    var z = b1[j].getFloat
    for i in 0 ..< AntInputSize:
      z += float(input[i]) * w1[i * AntHiddenSize + j].getFloat
    hidden[j] = tanh(z)
  var magnitude = 0.0
  for k in 0 ..< AntOutputSize:
    var expected = b2[k].getFloat
    for j in 0 ..< AntHiddenSize:
      expected += hidden[j] * w2[j * AntOutputSize + k].getFloat
    doAssert abs(float(nimLogits[k]) - expected) < 2e-5,
      $k & ": " & $nimLogits[k] & " != " & $expected
    magnitude += abs(expected)
  doAssert magnitude > 0.1, "checkpoint must not be an untrained zero net"

block categorical_turns_are_replay_deterministic:
  var input: AntInput
  input[scalarIndex(0)] = 1.0            # carrying
  input[scalarIndex(2)] = -0.7           # wake behind
  let random = [0.125'f32, 0.5'f32, 0.875'f32]
  doAssert sampleAntAction(input, random) == sampleAntAction(input, random)

block expected_steering_preserves_task_direction:
  var homing: AntInput
  homing[scalarIndex(0)] = 1.0
  homing[scalarIndex(2)] = 0.8
  homing[scalarIndex(4)] = 0.8
  doAssert steerAntAction(homing).move == AntMoveForward

  var foodRight: AntInput
  foodRight[featureIndex(2, 3, 3)] = 1.0
  doAssert steerAntAction(foodRight).move == AntMoveRight
