import
  ctf/replays

echo "Testing lull span construction"
block:
  # One quiet stretch between two beats, trimmed by the lead on both sides.
  let spans = buildLullSpans(@[100, 1000], 0, 2000)
  doAssert spans.len == 2, "expected a mid lull and a tail lull"
  doAssert spans[0] == [100 + LullLeadTicks + 1, 1000 - LullLeadTicks - 1],
    "mid lull must keep lead-out and lead-in context"
  doAssert spans[1] == [1000 + LullLeadTicks + 1, 2000],
    "tail lull runs lead-free to the end"

block:
  # Beats closer than the minimum lull leave no span between them.
  let spans = buildLullSpans(@[100, 100 + MinLullTicks], 0, 100 + MinLullTicks)
  doAssert spans.len == 0, "short breathers must not be skipped"

block:
  # A beat-free replay is one whole lull after the start lead.
  let spans = buildLullSpans(@[], 0, 2000)
  doAssert spans.len == 1
  doAssert spans[0] == [LullLeadTicks + 1, 2000]

echo "Testing skip-lulls default"
block:
  # Every replay starts fast-forwarding the quiet stretches; 'f' opts out.
  var replay = initReplayPlayer(ReplayData())
  doAssert replay.skipLulls, "skip-lulls must be on by default"

echo "Testing lull tick lookup and step budget"
block:
  var replay: ReplayPlayer
  replay.lullSpans = @[[100, 200], [500, 700]]
  doAssert not replay.isLullTick(99)
  doAssert replay.isLullTick(100)
  doAssert replay.isLullTick(200)
  doAssert not replay.isLullTick(201)
  doAssert replay.isLullTick(600)
  doAssert not replay.isLullTick(701)

  # Budget is plain speed outside a lull, boosted inside, and capped.
  replay.speedIndex = 0
  doAssert replay.replayStepBudget(50) == 1
  doAssert replay.replayStepBudget(150) == 1, "boost only applies when on"
  replay.skipLulls = true
  doAssert replay.replayStepBudget(50) == 1
  doAssert replay.replayStepBudget(150) == LullSpeedBoost
  replay.speedIndex = PlaybackSpeeds.high
  doAssert replay.replayStepBudget(150) == MaxLullTicksPerFrame,
    "boosted budget must respect the per-frame cap"

echo "All lull span tests passed"
