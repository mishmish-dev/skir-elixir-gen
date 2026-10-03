import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('runtime exposes explicit unknown service errors and dispatches them as hidden 500s', async () => {
  const [rpc, service] = await Promise.all([
    read('runtime/lib/skir/rpc.ex'),
    read('runtime/lib/skir/rpc/service.ex'),
  ]);
  assert.match(rpc, /defmodule Skir\.RPC\.UnknownError do/);
  assert.match(rpc, /def unknown_error\(message\)/);
  assert.match(service, /\{:error, %UnknownError\{} = error\}/);
  assert.match(service, /error\.message/);
});

test('runtime contains the SkirRPC wire, Studio/list, client, and Plug adapter surface', async () => {
  const [service, client, plug, descriptor, pkg] = await Promise.all([
    read('runtime/lib/skir/rpc/service.ex'),
    read('runtime/lib/skir/rpc/service_client.ex'),
    read('runtime/lib/skir/rpc/plug.ex'),
    read('runtime/lib/skir/rpc/type_descriptor.ex'),
    read('package.json').then(JSON.parse),
  ]);
  assert.match(service, /"bad request: invalid request format"/);
  assert.match(service, /body == "list"/);
  assert.match(service, /<skir-studio-app>/);
  assert.match(client, /method\.name <> ":" <> Integer\.to_string\(method\.number\) <> "::" <> request_json/);
  assert.match(client, /"text\/plain; charset=utf-8"/);
  assert.match(descriptor, /"key_extractor"/);
  assert.match(plug, /remote_ip: conn\.remote_ip/);
  assert.doesNotMatch(plug, /peer: conn\.peer/);
  assert.equal(pkg.version, '0.3.0');
  assert.ok(pkg.files.includes('runtime'));
  assert.ok(pkg.files.includes('docs'));
});

test('service bounds JSON structure before handing it to Jason', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.match(service, /Skir\.Limits\.json_code\(code, ctx\)/);
  assert.match(service, /Skir\.Limits\.context\(\[max_bytes: service\.max_request_bytes\], :readable\)/);
});

test('service rejects non-UTF-8 request bodies before String operations', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.match(service, /not String\.valid\?\(body\) ->\s*text\(400, "invalid request body"\)/);
});
