# Arena Wasm components

This directory builds the CTF simulation and baseline player as the
`softmax:game@0.1.0` and `softmax:player@0.1.0` WebAssembly components. The
game component drives the deterministic simulation one tick per `step`, emits
fog-limited Sprite v1 frames, and streams the existing CTF replay format. The
player component runs the same baseline policy as the container entrypoint,
with the WebSocket receive loop inverted into `on-message`.

The checked-in WIT files are copied from the platform contract. Generated C
bindings are checked in so contract changes remain visible in review; `build.sh`
regenerates them in a temporary directory and rejects any checked-in drift.

## Pinned toolchain

- Nim 2.2.6 (the repository Nimby toolchain)
- wasi-sdk 33 / clang 22.1.0
- wit-bindgen 0.60.0
- wasm-tools 1.255.0
- wasi-vfs 0.6.3
- Wasmtime 46.0.1 Preview 1 reactor adapter

Set `WASI_SDK_PATH`, `WIT_BINDGEN`, `WASM_TOOLS`, `WASI_VFS`,
`WASI_VFS_LIB` (the release's `libwasi_vfs.a`), and `WASI_ADAPTER` to those
pinned tools, then run:

```sh
./arena/build.sh
```

When the WIT intentionally changes, regenerate each checked-in binding set
with the pinned generator before building:

```sh
$WIT_BINDGEN c arena/wit/softmax-game --world game --out-dir arena/bindings/game
$WIT_BINDGEN c arena/wit/softmax-player --world player --out-dir arena/bindings/player
```

`wasi-vfs` packs the repository `data/` tree at `/data` in the game core before
componentization. This preserves the existing map, font, and sprite loaders
while keeping `ctf_game.wasm` a single deployable artifact. Build products and
the Nim cache are ignored; the generated bindings and component-type objects
are source inputs and remain tracked.

The Preview 1 reactor adapter exposes the standard WASI Preview 2 CLI, clocks,
filesystem, and I/O imports in addition to the `softmax:*` interfaces. Hosts
must provide those adapter imports. Inspect the exact component contract with:

```sh
wasm-tools component wit arena/ctf_game.wasm
```

The host may pass any `u64` seed; the runtime folds it to the simulation's
portable non-negative 31-bit seed space identically in native and wasm builds.
An `err` result is terminal for that component instance because Nim's goto
exception state is not recoverable; the host must discard the instance. The
player `config` value is currently reserved and ignored. Game `seats` must
match a closed roster exactly and cannot be smaller than an open configured
roster.

All seats are installed during `init`; the first `step` performs the normal sim
lobby-to-playing transition with no network wait. That transition is retained
in the replay so the canonical replay engine can reproduce every recorded hash.

The player component follows league defaults: it emits changed input masks but
does not send the opt-in fast-ready or fixture/taunt shouts used by the
WebSocket entrypoint under environment flags.

## Validation

With the same toolchain variables set, run:

```sh
./arena/test.sh
```

The test drives the native and component builds with the same full-width seed
and scripted Sprite v1 inputs, replays and compares all 13 `gameHash` records,
compares native/Wasm baseline outputs, and verifies identical final results.
