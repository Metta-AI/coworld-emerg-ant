#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arena_dir="$repo_dir/arena"
generated_dir="$(mktemp -d "${TMPDIR:-/tmp}/coworld-ctf-bindings.XXXXXX")"
trap 'rm -r "$generated_dir"' EXIT

: "${WASI_SDK_PATH:?Set WASI_SDK_PATH to wasi-sdk 33}"
: "${WIT_BINDGEN:?Set WIT_BINDGEN to wit-bindgen 0.60.0}"
: "${WASM_TOOLS:?Set WASM_TOOLS to wasm-tools 1.255.0}"
: "${WASI_VFS:?Set WASI_VFS to wasi-vfs 0.6.3}"
: "${WASI_VFS_LIB:?Set WASI_VFS_LIB to wasi-vfs 0.6.3 libwasi_vfs.a}"
: "${WASI_ADAPTER:?Set WASI_ADAPTER to Wasmtime 46.0.1 wasi_snapshot_preview1.reactor.wasm}"

"$WIT_BINDGEN" --version | grep -F "wit-bindgen-cli 0.60.0"
"$WASM_TOOLS" --version | grep -F "wasm-tools 1.255.0"
"$WASI_VFS" --version | grep -Fx "wasi-vfs-cli 0.6.3"
"$WASI_SDK_PATH/bin/clang" --version | grep -F "clang version 22.1.0-wasi-sdk"
nim --version | grep -F "Nim Compiler Version 2.2.6"

mkdir -p "$generated_dir/game" "$generated_dir/player"
"$WIT_BINDGEN" c "$arena_dir/wit/softmax-game" \
  --world game --out-dir "$generated_dir/game"
"$WIT_BINDGEN" c "$arena_dir/wit/softmax-player" \
  --world player --out-dir "$generated_dir/player"
diff -qr "$generated_dir/game" "$arena_dir/bindings/game"
diff -qr "$generated_dir/player" "$arena_dir/bindings/player"

nim c "$arena_dir/game_component.nim"
nim c "$arena_dir/player_component.nim"

"$WASI_VFS" pack "$arena_dir/ctf_game.core.wasm" \
  --dir "$repo_dir/data::/data" -o "$arena_dir/ctf_game.packed.wasm"
"$WASM_TOOLS" component new "$arena_dir/ctf_game.packed.wasm" \
  --adapt "wasi_snapshot_preview1=$WASI_ADAPTER" \
  -o "$arena_dir/ctf_game.wasm"
"$WASM_TOOLS" component new "$arena_dir/ctf_player_baseline.core.wasm" \
  --adapt "wasi_snapshot_preview1=$WASI_ADAPTER" \
  -o "$arena_dir/ctf_player_baseline.wasm"
"$WASM_TOOLS" validate "$arena_dir/ctf_game.wasm"
"$WASM_TOOLS" validate "$arena_dir/ctf_player_baseline.wasm"
