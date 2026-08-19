## Puts the repo's `src/` on the search path so this bot can import the SHARED
## sprite-label vocabulary (`ctf/labels`) that the engine emits against, instead
## of keeping its own copies of those strings — a copy that drifts silently is
## how a policy goes blind (see the retired `aim dot` scan).
##
## `ctf/labels` is deliberately import-free, so this pulls in exactly one file:
## the renderer's dependency cone (pixie/aseprite/mummy) must NOT reach a bot
## binary whose shipped image carries no `data/` directory.
##
## Mirrors tests/config.nims, which reaches `src/` the same way. Nim picks this
## up automatically because the project dir is the dir of the file being
## compiled — true both for `nim c players/baseline/baseline.nim` from the repo
## root and for the identical invocation in players/baseline/Dockerfile.
import std/os

switch("path", currentSourcePath().parentDir().parentDir().parentDir() / "src")
