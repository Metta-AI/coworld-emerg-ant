import std/[os, strutils], ../players/baseline/baseline/taunts

# No AWS_ENDPOINT_URL_BEDROCK_RUNTIME: the worker must fall back to canned
# lines without blocking or crashing.
startTaunts()
var bank: seq[string]
var comeback = ""
requestComeback("GIT GUD")
for i in 0 ..< 30:
  sleep(100)
  pollTaunts(bank, comeback)
  if comeback.len > 0:
    break
echo "bank(empty ok): ", bank.len, " comeback: ", comeback
doAssert comeback.len in 2 .. 10
doAssert comeback in CannedComebacks
echo "FALLBACK-OK"
