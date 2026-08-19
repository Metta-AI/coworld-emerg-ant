## The full suite: the four CI shards, which together import every test
## module. Add new test modules to a shard file (pick the fastest one),
## never here — CI runs the shards as four parallel release binaries.
{.warning[UnusedImport]: off.}
import
  shard_1,
  shard_2,
  shard_3,
  shard_4
{.warning[UnusedImport]: on.}
