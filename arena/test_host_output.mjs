export const replayChunks = [];
export let resultBody;

export function replayAppend(chunk) {
  replayChunks.push(chunk.slice());
}

export function results(body) {
  resultBody = body.slice();
}

export function line() {}
