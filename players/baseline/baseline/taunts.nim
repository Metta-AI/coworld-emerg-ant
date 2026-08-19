## Bedrock-backed taunt generation for the baseline bot, built so the game
## loop can NEVER block on it: one background worker thread owns all HTTP,
## and the bot talks to it through non-blocking channels. If the Bedrock
## sidecar is absent (no AWS_ENDPOINT_URL_BEDROCK_RUNTIME — local runs,
## non-Bedrock leagues) or a call fails or dawdles, everything falls back to
## a compiled-in bank, so the taunt system degrades to canned lines instead
## of degrading the bot.
##
## Hosted-tournament contract (packages/coworld/docs/BEDROCK.md):
## POST $AWS_ENDPOINT_URL_BEDROCK_RUNTIME/model/$BEDROCK_MODEL/invoke with an
## Anthropic Messages body and NO auth header — the sidecar signs. Never the
## real AWS host, never Converse.

import std/[json, os, strutils, random]
import curly

const
  TauntMaxChars* = 10          # the shout limit; anything longer is dropped
  BankTarget = 24              # taunts to prefetch per game
  DefaultModel = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  # Fallback bank: used until (or instead of) the Bedrock bank arrives.
  CannedTaunts* = [
    "IN PEACE!", "OOPS SORRY", "MY BAD!", "DONT SHOOT", "BE FRIENDS",
    "FRIENDS?", "WHY FIGHT?", "IM NICE!", "TRUCE?", "PACIFIST!",
    "SO SORRY!", "HUG IT OUT", "PLAY NICE!", "NO OFFENSE", "STOP PLS!",
    "PEACE OK?"
  ]
  CannedComebacks* = [
    "THATS MEAN", "BE KIND :(", "IM HURT :(", "WOW RUDE", "LOVE U TOO",
    "HUGS?", "SO HOSTILE", "WHY MEAN?", "PEACE PLS", "NO NEED :("
  ]

type
  TauntJob = object
    kind: char                 # 'B' = prefetch bank, 'R' = comeback
    heard: string              # the enemy line to respond to (kind 'R')

var
  jobs: Channel[TauntJob]
  results: Channel[string]     # 'B'/'R' prefix + sanitized taunt
  worker: Thread[void]
  started = false

proc sidecarBase(): string =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")

proc modelId(): string =
  let m = getEnv("BEDROCK_MODEL")
  if m.len > 0: m else: DefaultModel

proc sanitizeTaunt*(raw: string): string =
  ## One shout-safe taunt from a model line: strip quotes/whitespace, cap at
  ## TauntMaxChars, and refuse anything that parses like our "C.. .." /
  ## "T.. .." coordinate wire format so a taunt can never spoof a mate fix.
  result = raw.strip().replace("\"", "").replace("'", "")
  if result.len > TauntMaxChars:
    result.setLen(TauntMaxChars)
  result = result.strip()
  for c in result:
    if c < ' ':
      return ""
  if result.len >= 2 and result[0] in {'H', 'B', 'A'} and
      result[1] in {'1', '2', '3'}:
    return ""                            # lane-order call shape: drop
  if result.len >= 4 and result[0] in {'C', 'T', 'E', 'G'}:
    let parts = result[1 .. ^1].split(' ')
    if parts.len == 2:
      try:
        discard parseInt(parts[0])
        discard parseInt(parts[1])
        return ""                        # looks like a coordinate shout: drop
      except ValueError:
        discard

proc invokeBedrock(pool: CurlPool, system, user: string, maxTokens: int): string =
  ## One blocking InvokeModel call via the sidecar. Worker thread only.
  ## Returns "" on any failure — callers always have a canned fallback.
  let base = sidecarBase()
  if base.len == 0:
    return ""
  try:
    let body = $(%*{
      "anthropic_version": "bedrock-2023-05-31",
      "max_tokens": maxTokens,
      "system": system,
      "messages": [{"role": "user", "content": user}]
    })
    let response = pool.post(
      base & "/model/" & modelId() & "/invoke",
      @[("Content-Type", "application/json"),
        ("Accept", "application/json")],
      body
    )
    if response.code != 200:
      echo "taunt: bedrock ", response.code, " ",
        response.body[0 ..< min(200, response.body.len)]
      return ""
    let data = parseJson(response.body)
    for part in data["content"]:
      if part{"type"}.getStr() == "text":
        result.add part["text"].getStr()
  except CatchableError as e:
    echo "taunt: bedrock call failed: ", e.msg

proc workerLoop() {.thread.} =
  ## Owns all Bedrock I/O. Converts jobs into sanitized taunt lines.
  let pool = newCurlPool(1)
  while true:
    let job = jobs.recv()                # blocks: this thread has nothing else
    case job.kind
    of 'B':
      let reply = pool.invokeBedrock(
        "You write lines for an arena-shooter bot playing wide-eyed " &
        "innocent: it insists it comes in peace, asks people to stop " &
        "shooting, wants to be friends — even as it wins. Like I COME IN " &
        "PEACE, DONT SHOOT, BE FRIENDS. Output ONLY lines, one per line, " &
        "each AT MOST 10 characters, uppercase, no quotes, no numbering. " &
        "Sweet and apologetic, never aggressive, never profane.",
        "Write " & $BankTarget & " distinct lines.", 400)
      var sent = 0
      for line in reply.splitLines():
        let t = sanitizeTaunt(line)
        if t.len >= 2:
          discard results.trySend("B" & t)
          inc sent
      if sent == 0:
        echo "taunt: bank prefetch fell back to canned lines"
    of 'R':
      let reply = pool.invokeBedrock(
        "You play an arena-shooter bot that acts wide-eyed innocent. The " &
        "enemy just taunted you. Reply with ONE hurt-but-friendly line — " &
        "wounded feelings, offers of peace or friendship, never a " &
        "counter-attack. AT MOST 10 characters, uppercase, no quotes. " &
        "Never aggressive, never profane.",
        "Enemy taunt: " & job.heard, 30)
      var t = ""
      for line in reply.splitLines():
        t = sanitizeTaunt(line)
        if t.len >= 2:
          break
      if t.len >= 2:
        discard results.trySend("R" & t)
      else:
        discard results.trySend("R")     # signals: use a canned comeback
    else:
      discard

proc startTaunts*() =
  ## Spawns the worker and queues the bank prefetch. Call once at startup.
  if started:
    return
  started = true
  randomize()
  jobs.open(16)
  results.open(64)
  createThread(worker, workerLoop)
  discard jobs.trySend(TauntJob(kind: 'B'))

proc requestComeback*(heard: string) =
  ## Non-blocking: hand the enemy's line to the worker.
  if started:
    discard jobs.trySend(TauntJob(kind: 'R', heard: heard))

proc pollTaunts*(bank: var seq[string], comeback: var string) =
  ## Non-blocking drain of worker output into the caller's stores. A bare
  ## "R" means the model had nothing usable: serve a canned comeback so the
  ## reply still happens on time.
  if not started:
    return
  while true:
    let (ok, line) = results.tryRecv()
    if not ok:
      break
    if line.len == 0:
      continue
    if line.len < 2:
      if line[0] == 'R':
        comeback = sample(CannedComebacks)
      continue
    case line[0]
    of 'B': bank.add(line[1 .. ^1])
    of 'R': comeback = line[1 .. ^1]
    else: discard
