/** Real compiler + reference-runtime test. No mocks and no silent skips.
 * Requires `npm install`, Elixir/Mix, and fetched Mix dependencies.
 */
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = fileURLToPath(new URL('../', import.meta.url));
const example = path.join(root, 'example');
function run(command, args, cwd = root) {
  const result = spawnSync(command, args, { cwd, stdio: 'inherit' });
  if (result.error)
    throw new Error(`Cannot execute ${command}: ${result.error.message}`);
  if (result.status !== 0)
    throw new Error(`${command} ${args.join(' ')} exited ${result.status}`);
}
run('mix', ['--version']);
run(process.execPath, ['scripts/configure-example.mjs']);
const skirDir = path.join(root, 'node_modules/skir');
const skirPackage = JSON.parse(
  await readFile(path.join(skirDir, 'package.json'), 'utf8'),
);
const cli =
  typeof skirPackage.bin === 'string' ? skirPackage.bin : skirPackage.bin.skir;
run(process.execPath, [path.join(skirDir, cli), 'gen'], example);

// Generation above must go through the installed compiler. Do not replace it
// with the fixture generator: this gate is what detects upstream IR drift.
const { User, Event } = await import(
  pathToFileURL(path.join(example, 'reference/skirout/user.js'))
);
const { Node, Loop } = await import(
  pathToFileURL(path.join(example, 'reference/skirout/tree.js'))
);
const { primitiveSerializer, arraySerializer, optionalSerializer } =
  await import('skir-client');
const records = { User, Event, Node, Loop };
function serializer(type) {
  if (Array.isArray(type))
    return type[0] === 'array'
      ? arraySerializer(serializer(type[1]))
      : optionalSerializer(serializer(type[1]));
  return records[type]?.serializer ?? primitiveSerializer(type);
}
const cases = [];
function add(type, values) {
  for (const value of values)
    cases.push({
      name: `${JSON.stringify(type)}:${cases.length}`,
      type,
      value,
    });
}
add('User', [
  [],
  [42, 0, 'Alice'],
  [
    '9223372036854775807',
    0,
    'Jørgen ☃',
    1,
    '',
    [['Mo', 'cat.png']],
    ['Oslo'],
    'AAH/',
    1735689600000,
    [5, 'Hello'],
  ],
]);
add('Event', [0, 1, [2, [42, 0, 'Alice']], [5, 'Hi'], [5, '']]);
add('Node', [[], ['root', null, [['leaf']]], ['root', ['next'], []]]);
add('Loop', [[]]);
add('bool', [0, 1]);
add(
  'int32',
  [
    0, 1, 231, 232, 65535, 65536, 2147483647, -1, -256, -257, -65536, -65537,
    -2147483648,
  ],
);
add('int64', [
  0,
  2147483647,
  2147483648,
  4294967295,
  '9007199254740992',
  '9223372036854775807',
  '-9223372036854775808',
]);
add('hash64', [
  0,
  4294967295,
  4294967296,
  '9007199254740992',
  '18446744073709551615',
]);
add('float32', [0, 1.5, -3.25, 3.14159, 'NaN', 'Infinity', '-Infinity']);
add('float64', [
  0,
  1.5,
  Math.PI,
  1e-300,
  1e300,
  'NaN',
  'Infinity',
  '-Infinity',
]);
add(
  'timestamp',
  [0, -1, 1, 1735689600000, -8640000000000000, 8640000000000000],
);
add('string', ['', 'hello', '🌍\u0000\n"#{not_interpolation}']);
add('bytes', [
  '',
  'AAH/',
  Buffer.from(Array.from({ length: 117 }, (_, i) => i & 255)).toString(
    'base64',
  ),
]);
add(['optional', 'string'], [null, '', 'name', 0]);
add(['array', 'int32'], [[], [1], [1, 2], [1, 2, 3], [1, 2, 3, 4]]);
add(['array', ['optional', 'User']], [[], [null, [], [42, 0, 'Alice']]]);
// Deterministic generated cases: failures can be reproduced without a fuzzer.
let seed = 0x534b4952;
const random = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0);
for (let i = 0; i < 128; i++) {
  const id = random() | 0;
  const dense = [
    id,
    0,
    `user-${i}`,
    random() & 1,
    random() & 1 ? null : '',
    [[`pet-${random() % 7}`, '']],
    [`city-${random() % 13}`],
    Buffer.from([random() & 255, random() & 255]).toString('base64'),
    random(),
    random() & 1 ? 1 : [5, `message-${i}`],
  ];
  add('User', [dense]);
}
const vectors = cases.map(({ name, type, value }) => {
  const s = serializer(type);
  // Normalize through binary first so float32 rounding is explicit. JSON itself
  // does not force every implementation to round a float32 at parse time.
  const bytes = s.toBytes(s.fromJson(value)).toBuffer();
  const normalized = s.fromBytes(bytes);
  return {
    name,
    type,
    mode: 'all',
    dense: s.toJson(normalized),
    readable: s.toJson(normalized, 'readable'),
    binary: Buffer.from(bytes).toString('base64'),
  };
});
// skir-client 1.0.19 corrupts OutputStream.putBytes when the payload crosses
// its initial 128-byte buffer. Check long bytes against its decoder instead:
// documented wire format = "skir", bytes marker, uint16 length, payload.
const longPayload = Buffer.from(Array.from({ length: 257 }, (_, i) => i & 255));
const longBytes = Buffer.concat([
  Buffer.from('skir'),
  Buffer.from([0xf5, 0xe8, 1, 1]),
  longPayload,
]);
const bytesSerializer = serializer('bytes');
const longValue = bytesSerializer.fromBytes(Uint8Array.from(longBytes).buffer);
assert.equal(bytesSerializer.toJson(longValue), longPayload.toString('base64'));
vectors.push({
  name: 'long-bytes',
  type: 'bytes',
  mode: 'all',
  reference_encode: false,
  dense: bytesSerializer.toJson(longValue),
  readable: bytesSerializer.toJson(longValue, 'readable'),
  binary: longBytes.toString('base64'),
});
const futureUser = [42, 0, 'Alice', 0, null, [], [], '', 0, 0, ['future', 123]];
for (const [name, type, dense] of [
  ['future-struct', 'User', futureUser],
  ['future-enum', 'Event', [77, ['future']]],
]) {
  const s = serializer(type);
  vectors.push({
    name,
    type,
    mode: 'dense_only',
    dense: s.toJson(s.fromJson(dense, 'keep-unrecognized-values')),
  });
}
const unknownBinary = Buffer.concat([
  Buffer.from('skir'),
  Buffer.from([
    0xfa,
    11,
    42,
    0,
    0xf3,
    5,
    ...Buffer.from('Alice'),
    0,
    0xff,
    0xf6,
    0xf6,
    0xf4,
    0,
    0,
    0xf5,
    0xe8,
    1,
    0,
    0xfe,
  ]),
]);
const unknownBuffer = unknownBinary.buffer.slice(
  unknownBinary.byteOffset,
  unknownBinary.byteOffset + unknownBinary.byteLength,
);
assert.deepEqual(
  Buffer.from(
    User.serializer
      .toBytes(
        User.serializer.fromBytes(unknownBuffer, 'keep-unrecognized-values'),
      )
      .toBuffer(),
  ),
  unknownBinary,
);
vectors.push({
  name: 'future-binary-struct',
  type: 'User',
  mode: 'binary_only',
  binary: unknownBinary.toString('base64'),
});

const artifacts = path.join(root, '.artifacts');
await mkdir(artifacts, { recursive: true });
const input = path.join(artifacts, 'reference-vectors.json');
const output = path.join(artifacts, 'elixir-vectors.json');
await writeFile(input, JSON.stringify(vectors));
run('mix', ['deps.get', '--check-locked'], example);
run('mix', ['compile', '--warnings-as-errors'], example);
run('mix', ['test', '--cover', '--warnings-as-errors'], example);
run(
  'mix',
  ['run', path.join(root, 'scripts/interop.exs'), input, output],
  example,
);
const results = JSON.parse(await readFile(output, 'utf8'));
assert.equal(results.length, vectors.length);
for (let i = 0; i < vectors.length; i++) {
  const expected = vectors[i],
    actual = results[i],
    s = serializer(expected.type);
  assert.equal(actual.name, expected.name);
  if (expected.mode !== 'binary_only') {
    const value = s.fromJson(actual.dense, 'keep-unrecognized-values');
    assert.deepEqual(
      s.toJson(value),
      expected.dense,
      `${expected.name}: Elixir dense -> reference`,
    );
  }
  if (expected.mode === 'all') {
    assert.deepEqual(
      s.toJson(s.fromJson(actual.readable)),
      expected.dense,
      `${expected.name}: Elixir readable -> reference`,
    );
  }
  if (expected.mode !== 'dense_only') {
    assert.equal(
      actual.binary,
      expected.binary,
      `${expected.name}: byte-for-byte encoding`,
    );
    const bytes = Uint8Array.from(Buffer.from(actual.binary, 'base64')).buffer;
    const value = s.fromBytes(bytes, 'keep-unrecognized-values');
    if (expected.reference_encode !== false) {
      assert.equal(
        Buffer.from(s.toBytes(value).toBuffer()).toString('base64'),
        expected.binary,
      );
    }
  }
}
console.log(
  `PASS: ${vectors.length} interoperability vectors, real Skir compiler, native Elixir runtime.`,
);
