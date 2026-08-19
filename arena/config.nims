import std/os

let
  arenaDir = currentSourcePath().parentDir()
  repoDir = arenaDir.parentDir()
  wasiSdk = getEnv("WASI_SDK_PATH")

if wasiSdk.len == 0:
  quit("WASI_SDK_PATH must point at wasi-sdk 33.", 1)

switch("nimcache", arenaDir / ".nimcache" / projectName())
switch("path", repoDir / "src")
switch("path", repoDir / "players" / "baseline")
switch("threads", "off")
switch("os", "linux")
switch("cpu", "wasm32")
switch("cc", "clang")
switch("clang.exe", wasiSdk / "bin" / "clang")
switch("clang.linkerexe", wasiSdk / "bin" / "clang")
switch("clang.cpp.exe", wasiSdk / "bin" / "clang++")
switch("clang.cpp.linkerexe", wasiSdk / "bin" / "clang++")
switch("mm", "arc")
switch("exceptions", "goto")
switch("define", "noSignalHandler")
switch("define", "release")
# Generated canonical-ABI post-return shims call free() on Nim allocations.
switch("define", "useMalloc")
switch("define", "arenaComponent")
switch("define", "artlogNoCurl")
switch("noMain", "on")
switch("passL", "-mexec-model=reactor")

if projectName() == "game_component":
  switch("passL", arenaDir / "bindings" / "game" / "game_component_type.o")
  let wasiVfsLib = getEnv("WASI_VFS_LIB")
  if wasiVfsLib.len == 0:
    quit("WASI_VFS_LIB must point at wasi-vfs 0.6.3 libwasi_vfs.a.", 1)
  switch("passL", wasiVfsLib)
  switch("out", arenaDir / "ctf_game.core.wasm")
elif projectName() == "player_component":
  switch("passL", arenaDir / "bindings" / "player" / "player_component_type.o")
  switch("out", arenaDir / "ctf_player_baseline.core.wasm")
else:
  quit("arena/config.nims only builds the game and player components.", 1)
