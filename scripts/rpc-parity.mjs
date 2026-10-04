/**
 * Executable SkirRPC server parity oracle.
 *
 * Requires installed npm dependencies and an Elixir/Mix toolchain. It executes
 * identical raw requests against the official TypeScript Service from
 * `skir-client` and this package's native Elixir Service, then compares their
 * transport-neutral responses.
 */
import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {Service, ServiceClient, ServiceError, primitiveSerializer} from 'skir-client';

const root = fileURLToPath(new URL('../', import.meta.url));
const runtime = path.join(root, 'runtime');
const artifacts = path.join(root, '.artifacts');

function run(command, args, cwd = root) {
  const result = spawnSync(command, args, {cwd, stdio: 'inherit'});
  if (result.error) throw new Error(`Cannot execute ${command}: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${command} ${args.join(' ')} exited ${result.status}`);
}

const string = primitiveSerializer('string');
const echo = {name: 'Echo', number: 12345, requestSerializer: string, responseSerializer: string, doc: ''};
const echo2 = {name: 'Echo', number: 12346, requestSerializer: string, responseSerializer: string, doc: ''};
const conflict = {name: 'Conflict', number: 23456, requestSerializer: string, responseSerializer: string, doc: ''};

function makeSingleService() {
  return new Service()
    .addMethod(echo, async (request) => request)
    .addMethod(conflict, async () => {
      throw new ServiceError({statusCode: 409, desc: 'Conflict'});
    });
}

function makeAmbiguousService() {
  return new Service()
    .addMethod(echo, async (request) => request)
    .addMethod(echo2, async (request) => request);
}

const services = {
  single: makeSingleService(),
  ambiguous: makeAmbiguousService(),
};

const cases = [
  {name: 'number dispatch', service: 'single', body: 'Echo:12345::"hello"'},
  {name: 'name dispatch', service: 'single', body: 'Echo:::"hello"'},
  {name: 'manual JSON name dispatch', service: 'single', body: '{"method":"Echo","request":"hello"}'},
  {name: 'manual JSON number dispatch', service: 'single', body: '{"method":12345,"request":"hello"}'},
  {name: 'leading whitespace JSON', service: 'single', body: '  {"method":"Echo","request":"hello"}'},
  {name: 'invalid method number', service: 'single', body: 'Echo:+12345::"hello"'},
  {name: 'unknown method wins before malformed request JSON', service: 'single', body: 'Missing:99999::{'},
  {name: 'known method malformed request JSON', service: 'single', body: 'Echo:12345::{'},
  {name: 'unknown method number', service: 'single', body: 'Missing:99999::"hello"'},
  {name: 'controlled default error phrase', service: 'single', body: 'Conflict:23456::"hello"'},
  {name: 'exact list keyword', service: 'single', body: 'list'},
  {name: 'exact studio keyword', service: 'single', body: 'studio'},
  {name: 'empty studio keyword', service: 'single', body: ''},
  {name: 'keywords are not trimmed', service: 'single', body: ' list '},
  {name: 'ambiguous name', service: 'ambiguous', body: 'Echo:::"hello"'},
  {name: 'ambiguous service numeric dispatch', service: 'ambiguous', body: 'Echo:12346::"hello"'},
];

const methodNumbers = new Map([
  ['Echo', 12345],
  ['Conflict', 23456],
]);

function normalizedResponse(testCase, raw) {
  const response = {
    status_code: raw.statusCode ?? raw.status_code,
    content_type: raw.contentType ?? raw.content_type,
    data: raw.data,
  };

  if (testCase.name === 'known method malformed request JSON') {
    // V8 and Jason report syntax errors differently. Require the same status
    // and RPC error prefix while allowing the parser-specific diagnostic.
    assert.equal(response.status_code, 400);
    assert.match(response.data, /^bad request: can't parse JSON: .+$/);
    response.data = "bad request: can't parse JSON: <parser diagnostic>";
  }

  if (testCase.body === 'list' && response.status_code === 200) {
    const parsed = JSON.parse(response.data);
    for (const method of parsed.methods ?? []) {
      // skir-client 1.0.19 currently writes the method name into `number`.
      // Dart/Gleam and the reflection contract use the numeric ID. Normalize
      // only that known upstream anomaly so this oracle remains useful after
      // TypeScript fixes it.
      if (typeof method.number !== 'number' && method.number === method.method) {
        method.number = methodNumbers.get(method.method);
      }
    }
    parsed.methods?.sort((a, b) => a.number - b.number);
    response.data = parsed;
  }

  return response;
}

const expected = [];
for (const testCase of cases) {
  const raw = await services[testCase.service].handleRequest(testCase.body, {source: 'parity-oracle'});
  expected.push({name: testCase.name, response: normalizedResponse(testCase, raw)});
}

const clientRequest = "a b%?&#$=+/@'";
async function captureTypeScriptClient(httpMethod) {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (input, init = {}) => {
    captured = {
      method: init.method,
      url: String(input),
      body: typeof init.body === 'string' ? init.body : '',
    };
    return new Response('"ok"', {status: 200, headers: {'content-type': 'application/json'}});
  };
  try {
    const response = await new ServiceClient('https://example.test/rpc').invokeRemote(
      echo,
      clientRequest,
      httpMethod,
    );
    assert.equal(response, 'ok');
    return captured;
  } finally {
    globalThis.fetch = originalFetch;
  }
}

const expectedClientWire = {
  GET: await captureTypeScriptClient('GET'),
  POST: await captureTypeScriptClient('POST'),
};

await mkdir(artifacts, {recursive: true});
const input = path.join(artifacts, 'rpc-parity-input.json');
const output = path.join(artifacts, 'rpc-parity-elixir.json');
await writeFile(input, JSON.stringify(cases));

run('mix', ['--version'], runtime);
run('mix', ['deps.get'], runtime);
run('mix', ['compile', '--warnings-as-errors'], runtime);
run('mix', ['run', path.join(root, 'scripts/rpc-parity.exs'), input, output], runtime);

const actualRaw = JSON.parse(await readFile(output, 'utf8'));
assert.equal(actualRaw.server.length, cases.length);
const actual = actualRaw.server.map((entry, index) => ({
  name: entry.name,
  response: normalizedResponse(cases[index], entry.response),
}));
assert.deepEqual(actual, expected);
assert.deepEqual(actualRaw.client_wire, expectedClientWire);

console.log(`PASS: ${cases.length} raw SkirRPC server cases plus GET/POST client wire behavior match official TypeScript.`);
