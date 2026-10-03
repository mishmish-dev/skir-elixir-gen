import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const harnessUrl = new URL('../scripts/rpc-parity.mjs', import.meta.url);
const oracleUrl = new URL('../scripts/rpc-parity.exs', import.meta.url);

test('package exposes executable SkirRPC parity gate', async () => {
  assert.equal(pkg.scripts['test:rpc-parity'], 'node scripts/rpc-parity.mjs');
  assert.match(pkg.scripts['test:all'], /test:rpc-parity/);
});

test('parity harness compares official TypeScript service with native Elixir service', async () => {
  const harness = await readFile(harnessUrl, 'utf8');
  const oracle = await readFile(oracleUrl, 'utf8');
  assert.match(harness, /from ['"]skir-client['"]/);
  assert.match(harness, /new Service/);
  assert.match(harness, /ServiceClient/);
  assert.match(harness, /invokeRemote/);
  assert.match(harness, /primitiveSerializer\(['"]string['"]\)/);
  assert.match(harness, /scripts\/rpc-parity\.exs/);
  assert.match(harness, /deepEqual/);
  assert.match(harness, /client_wire/);
  assert.match(oracle, /Skir\.RPC\.Service/);
  assert.match(oracle, /%Skir\.Method/);
  assert.match(oracle, /Service\.handle_request/);
  assert.match(oracle, /ServiceClient\.invoke/);
});
