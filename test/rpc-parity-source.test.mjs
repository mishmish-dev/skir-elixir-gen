import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const read = path => readFile(new URL(`../${path}`, import.meta.url), 'utf8');

test('service follows TypeScript/Dart exact endpoint matching and 400 error surface', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.doesNotMatch(service, /trimmed\s*=\s*String\.trim\(body\)/);
  assert.match(service, /body == "list"/);
  assert.match(service, /body in \["", "studio"\]/);
  assert.match(service, /"bad request: invalid request format"/);
  assert.match(service, /"bad request: can't parse method number"/);
  assert.match(service, /"bad request: method not found: #\{name\}"/);
  assert.match(service, /"bad request: method name '#\{name\}' is ambiguous; use method number instead"/);
  assert.match(service, /"bad request: method not found: #\{name\}; number: #\{number\}"/);
});

test('service permits duplicate method names and resolves names by scanning numeric registrations', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.doesNotMatch(service, /duplicate SkirRPC method name/);
  assert.match(service, /service\.by_number\s*\n\s*\|> Map\.values\(\)/);
  assert.match(service, /Enum\.filter/);
});

test('service resolves a colon method before decoding request JSON', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  const lookup = service.indexOf('lookup_method');
  const decode = service.indexOf('decode_request_json');
  assert.notEqual(lookup, -1);
  assert.notEqual(decode, -1);
  assert.ok(lookup < decode, 'lookup_method should appear before decode_request_json in colon handling');
});

test('service exposes response serializer failures and qualifies text errors with UTF-8 charset', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.match(service, /server error: can't serialize response to JSON:/);
  assert.match(service, /content_type: "text\/plain; charset=utf-8"/);
});

test('service Studio HTML matches TypeScript/Dart surface', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.match(service, /<title>RPC Studio<\/title>/);
  assert.match(service, /<body style="margin: 0; padding: 0;">/);
});

test('list endpoint is keyed from numeric registrations and emits numeric method ids', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  const listBlock = service.slice(service.indexOf('defp serve_list'), service.indexOf('defp serve_studio'));
  assert.match(listBlock, /service\.by_number/);
  assert.doesNotMatch(listBlock, /service\.by_name/);
  assert.match(listBlock, /"number" => method\.number/);
});

test('client supports TypeScript-compatible optional GET and HTTP status messages', async () => {
  const client = await read('runtime/lib/skir/rpc/service_client.ex');
  assert.match(client, /Keyword\.get\(opts, :http_method, :post\)/);
  assert.match(client, /:get/);
  assert.match(client, /String\.replace\(body, "%", "%25"\)/);
  assert.match(client, /"HTTP status #\{status\}"/);
});

test('Plug adapter returns charset-qualified text errors', async () => {
  const plug = await read('runtime/lib/skir/rpc/plug.ex');
  assert.match(plug, /"text\/plain; charset=utf-8"/);
});

test('controlled service errors support official default HTTP reason phrases', async () => {
  const rpc = await read('runtime/lib/skir/rpc.ex');
  assert.match(rpc, /@http_error_messages/);
  assert.match(rpc, /def error\(status_code, message \\\\ nil\)/);
  assert.match(rpc, /400 => "Bad Request"/);
  assert.match(rpc, /418 => "I'm a teapot"/);
  assert.match(rpc, /511 => "Network Authentication Required"/);
});

test('GET query encoding follows WHATWG special-query percent encoding used by TypeScript URL.search', async () => {
  const client = await read('runtime/lib/skir/rpc/service_client.ex');
  assert.match(client, /char >= 0x21 and char <= 0x7E/);
  assert.match(client, /char not in \[\?", \?#, \?', \?<, \?>\]/);
  assert.doesNotMatch(client, /char in ~c\":\{\}\[\],&\?\"/);
});

test('client text error detection uses the TypeScript text/plain word-boundary rule', async () => {
  const client = await read('runtime/lib/skir/rpc/service_client.ex');
  assert.ok(client.includes(String.raw`Regex.match?(~r/text\/plain\b/`));
  assert.doesNotMatch(client, /String\.contains\?\(String\.downcase\(value\), "text\/plain"\)/);
});

test('service accepts boolean or predicate unknown-error disclosure like TypeScript', async () => {
  const service = await read('runtime/lib/skir/rpc/service.ex');
  assert.match(service, /set_can_send_unknown_error_message\(%__MODULE__\{} = service, value\) when is_boolean\(value\)/);
  assert.match(service, /fn _ -> value end/);
  assert.match(service, /set_can_send_unknown_error_message\(%__MODULE__\{} = service, fun\) when is_function\(fun, 1\)/);
});
