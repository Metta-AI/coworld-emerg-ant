## CI shard 1 of 4. The shards are balanced by measured suite runtime so the
## four binaries finish together; when adding a test module, put it in the
## currently fastest shard (tests.nim imports all four, so every shard member
## is also part of the full local run).
{.warning[UnusedImport]: off.}
import
  test_cog_drive,
  test_ctf_game,
  test_damage_pop,
  test_identity_privacy,
  test_input_buffer,
  test_lobby_join_timeout,
  test_manifest_schema,
  test_map_editor,
  test_map_editor_core,
  test_sym_none,
  test_rasterizer_mirror,
  test_plasma_arc,
  test_replay_requests,
  # test_replay_switch_caches hot-switches the process-wide board render
  # caches onto other maps, but no longer has to run last: it restores the
  # default arena and invalidates the caches at module end, and the endzone
  # caches self-heal on a map size mismatch (both pinned by its own tests).
  test_replay_switch_caches,
  test_rich_events,
  test_trade_pair
{.warning[UnusedImport]: on.}
