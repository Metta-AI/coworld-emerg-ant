import std/unittest

include ../src/ctf/server

suite "replay requests":
  test "duplicate URI is ignored while pending, loading, and current":
    initAppState()

    "file:///replay-a.bitreplay".queueReplayUri()
    "file:///replay-a.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == "file:///replay-a.bitreplay"

    withLock appState.lock:
      appState.loadingReplayUri = appState.pendingReplayUri
      appState.pendingReplayUri = ""
    "file:///replay-a.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == ""

    withLock appState.lock:
      appState.currentReplayUri = appState.loadingReplayUri
      appState.loadingReplayUri = ""
    "file:///replay-a.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == ""

    "file:///replay-b.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == "file:///replay-b.bitreplay"

  test "startup env replay URI is recorded so requests for it do not reload":
    initAppState()
    putEnv(CogameLoadReplayUriEnv, "file:///startup.bitreplay")

    recordStartupReplayUri(loaded = true)
    check "file:///startup.bitreplay".replayUriKnown()
    "file:///startup.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == ""

    delEnv(CogameLoadReplayUriEnv)

  test "startup URI is not recorded when the replay failed to load":
    initAppState()
    putEnv(CogameLoadReplayUriEnv, "file:///startup.bitreplay")

    recordStartupReplayUri(loaded = false)
    check not "file:///startup.bitreplay".replayUriKnown()

    delEnv(CogameLoadReplayUriEnv)

  test "startup recording without an env URI records nothing":
    initAppState()
    delEnv(CogameLoadReplayUriEnv)

    recordStartupReplayUri(loaded = true)
    check appState.currentReplayUri == ""
