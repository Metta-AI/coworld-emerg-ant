import
  std/unittest,
  ctf/global

## The per-map spectator supersample cap. Board dimensions here are the real
## generated sizes: the 2-team shell is 1235x659 scaled by the class factor,
## the 4-team shell 960x960 (see arena.nim scaledGenShell/scaledGenShell4).
## The cap exists for the wasm32 static replay viewer: at RenderScale 2 the
## hot + cold arena bakes cost mapPixels*16 bytes and a colossal board blew
## through the 2 GB address space before its first frame (empty-error load
## failure); at 1x its wire carries the same byte volume as the proven
## giant 2x wire.

suite "board render scale cap":
  test "every ladder size class keeps the supersample":
    # small .. giant (2-team 2.6x: 3211x1713) and the 4-team giant square
    # (2496x2496, the largest class verified at 2x in the hosted viewer).
    check boardRenderScaleFor(1235, 659) == RenderScale
    check boardRenderScaleFor(3211, 1713) == RenderScale
    check boardRenderScaleFor(2496, 2496) == RenderScale

  test "colossal boards emit at 1x":
    check boardRenderScaleFor(6422, 3427) == 1   # 2-team 5.2x
    check boardRenderScaleFor(4992, 4992) == 1   # 4-team 5.2x

  test "predicted viewer footprint fits wasm32 for every supported class":
    check predictedViewerRenderBytes(3211, 1713) < WasmViewerBudgetBytes
    check predictedViewerRenderBytes(2496, 2496) < WasmViewerBudgetBytes
    check predictedViewerRenderBytes(6422, 3427) < WasmViewerBudgetBytes
    check predictedViewerRenderBytes(4992, 4992) < WasmViewerBudgetBytes

  test "a future beyond-colossal class trips the viewer preflight":
    # 2x colossal on each axis: even at 1x the map-sized buffers alone
    # exceed the 32-bit address space, so ctf_load_replay must refuse it
    # with a diagnostic instead of aborting mid-bake.
    check predictedViewerRenderBytes(9984, 9984) > WasmViewerBudgetBytes
