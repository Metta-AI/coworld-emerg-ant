## The live event sink: what the server writes as it plays.
##
## The value of first-party emission is that the stream cannot skew from the
## game that produced it. These cases pin the two things that would quietly
## break that: a second serializer drifting from the extractor's, and the sink
## turning itself on when nobody asked for it.

import
  helpers,
  std/[json, os, strutils, unittest],
  ../src/ctf/events,
  ../src/ctf/replays,
  ../src/ctf/sim,
  "../tools/extract_events"

const
  EventsFixture = GameDir / "tests" / "replays" / "ctf.bitreplay"

suite "live event emission (src/ctf/events)":
  test "the shared serializer is the extractor's, field for field":
    ## The live server and the re-simulator MUST produce identical rows: a
    ## consumer cannot be asked to tell them apart, and the whole point of
    ## emitting during play is that it replaces re-simulation transparently.
    ## This caught a real regression — a serializer copied from a stale branch
    ## silently dropped action_id/heading_brads/distance/item/content/damages,
    ## and `damages` is what carries the fatal-blow hp the kill map reads.
    let
      data = loadReplay(EventsFixture)
      extraction = extractEvents(data)

    check extraction.events.len > 0
    let rendered = extraction.events.eventsJsonl(extraction.ticks)

    # Every event row, plus the summary.
    let lines = rendered.strip(chars = {'\n'}).split('\n')
    check lines.len == extraction.events.len + 1

    let first = parseJson(lines[0])
    for field in [
      "tick", "kind", "source", "target", "weapon", "amount", "hp", "blocked",
      "x", "y", "action_id", "heading_brads", "distance", "item", "content",
      "damages"
    ]:
      check first.hasKey(field)

  test "the summary row carries the GameVersion the events were produced under":
    ## A consumer must never have to INFER which build made a stream — that
    ## inference is exactly what re-simulation got wrong.
    let
      data = loadReplay(EventsFixture)
      extraction = extractEvents(data)
      lines = extraction.events.eventsJsonl(extraction.ticks).strip(chars = {'\n'}).split('\n')
      summary = parseJson(lines[^1])

    check summary["type"].getStr() == "summary"
    check summary["events"].getInt() == extraction.events.len
    check summary["ticks"].getInt() == extraction.ticks
    # GameVersion is a STRING ("27" today); the warehouse that broke
    # was built at 26, which is the skew first-party emission removes.
    check summary["gameVersion"].getStr() == GameVersion

  test "an empty match still yields a readable stream":
    ## Zero events is an ordinary outcome. The file must still parse, so a
    ## reader can tell "this match had none" from "the upload never happened".
    var none: seq[SimEvent] = @[]
    let lines = none.eventsJsonl(0).strip(chars = {'\n'}).split('\n')

    check lines.len == 1
    check parseJson(lines[0])["events"].getInt() == 0

  test "collection stays OFF unless a sink is configured":
    ## `emitEvent` is a no-op behind this flag so live servers pay nothing.
    ## A fresh sim must never arrive with it already on.
    var sim = initSimServer(defaultGameConfig())
    check not sim.collectEvents
