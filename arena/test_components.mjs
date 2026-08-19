import assert from 'node:assert/strict';
import { finish, init, step } from './game/ctf_game.js';
import { onMessage, start } from './player/ctf_player_baseline.js';
import { replayChunks, resultBody } from './test_host_output.mjs';

const seed = 0xfedcba9876543210n;
const ticks = 13;
const config = JSON.stringify({
  players: [{ name: 'alpha' }, { name: 'beta' }],
  minPlayers: 2,
  maxTicks: 12,
  maxGames: 1,
});
const masks = [
  [8, 8, 0, 16, 0, 2],
  [4, 4, 0, 32, 0, 1],
];
const playerMasks = [];

init(config, 2, seed);
start(0, undefined);
for (let tick = 0; tick < ticks; tick += 1) {
  const output = step(masks.map((seatMasks, seat) => ({
    seat,
    payload: Uint8Array.of(0x84, seatMasks[tick % seatMasks.length]),
  })));
  assert.equal(output.done, tick === ticks - 1);
  assert.equal(output.messages.length, 2);
  const replies = onMessage(output.messages[0].payload);
  playerMasks.push(replies.length === 0 ? -1 : replies[0][1]);
  if (replies.length > 0) {
    assert.equal(replies.length, 1);
    assert.equal(replies[0][0], 0x84);
  }
}
finish();
assert.throws(() => step([]), /not initialized/);

const componentHashes = replayChunks
  .filter((chunk) => chunk.length === 13 && chunk[0] === 1)
  .map((chunk) => new DataView(
    chunk.buffer,
    chunk.byteOffset,
    chunk.byteLength,
  ).getBigUint64(5, true).toString());
const nativeHashes = process.env.NATIVE_HASHES.split(',');
assert.equal(componentHashes.length, ticks);
assert.deepEqual(componentHashes, nativeHashes);
const results = JSON.parse(new TextDecoder().decode(resultBody));
assert.deepEqual(results, JSON.parse(process.env.NATIVE_RESULTS));
assert.deepEqual(playerMasks, process.env.NATIVE_PLAYER_MASKS.split(',').map(Number));
assert(playerMasks.some((mask) => mask >= 0));
console.log(`native/component parity: ${componentHashes.length} hashes, results, and player masks`);
