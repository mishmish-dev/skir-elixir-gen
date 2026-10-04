import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateCode } from '../src/generator.js';
import { GENERATOR } from '../src/index.js';
import { literal, atom, moduleInfo } from '../src/naming.js';
import { ModuleSet } from 'skir/dist/module_set.js';
import {
  input,
  record,
  field,
  primitive as p,
  ref,
  exampleInput,
} from '../fixtures/schema.mjs';

test('generation is deterministic and leaves compiler input unchanged', () => {
  const a = exampleInput();
  const user = a.modules
    .find((m) => m.path === 'user.skir')
    .records.find((r) => r.record.name.text === 'User').record;
  user.fields.find((f) => f.name.text === 'pets').type.key = {
    path: [{ name: { text: 'name' } }],
    keyType: p('string'),
  };
  const primitives = record(
    'primitives.skir',
    ['Primitives'],
    'struct',
    [
      'bool',
      'int32',
      'int64',
      'hash64',
      'float32',
      'float64',
      'timestamp',
      'string',
      'bytes',
    ].map((t, n) => field(t, n, p(t))),
  );
  a.modules.push(...input([primitives]).modules);
  a.recordMap.set(primitives.record.key, primitives);
  const original = structuredClone(a),
    b = structuredClone(a);
  b.modules.reverse();
  b.modules.forEach((m) => m.records.reverse());
  assert.deepEqual(generateCode(a), generateCode(b));
  assert.deepEqual(a, original);
  assert.deepEqual(generateCode(input([])), { files: [] });
  assert.equal(
    generateCode(input([record('a.skir', ['Empty'], 'enum', [])])).files[0]
      .path,
    'a_skir.ex',
  );
  assert.deepEqual(moduleInfo('accounts/HTTP-user.skir', 'My.App'), {
    name: 'My.App.Accounts.HttpUserSkir',
    path: 'accounts/http_user_skir.ex',
  });
});

test('plugin configuration rejects unknown options and invalid namespaces', () => {
  for (const config of [{}, { namespace: 'My.App' }])
    assert.ok(GENERATOR.configType.safeParse(config).success);
  for (const config of [
    { namespace: 1 },
    { namespace: 'Bad;Code' },
    { other: true },
  ]) {
    assert.equal(GENERATOR.configType.safeParse(config).success, false);
    assert.throws(() => generateCode(input([], config)));
  }
});

test('GitHub dependencies resolve transitive imports and retain reflection IDs', () => {
  const sources = new Map([
    ['@acme/base/types.skir', 'struct Address { city: string; }'],
    [
      '@acme/shared-models/accounts/user.skir',
      'import { Address } from "@acme/base/types.skir"; struct User { address: Address; struct Pet { name: string; } pets: [Pet]; }',
    ],
    [
      'user.skir',
      'import { User } from "@acme/shared-models/accounts/user.skir"; struct Envelope { user: User; } const GUEST: User = { address: { city: "London" }, pets: [] }; method GetUser(int64): User = 12345;',
    ],
  ]);
  const compiled = ModuleSet.compile(sources, 'no-cache', 'strict');
  assert.deepEqual(compiled.errors, []);
  const compilerInput = {
    modules: [...compiled.modules.values()].map((m) => m.result),
    recordMap: compiled.recordMap,
    config: { namespace: 'My.App' },
  };
  const original = structuredClone(compilerInput);
  const { files } = generateCode(compilerInput);
  assert.deepEqual(compilerInput, original);
  const shared = files.find(
    (f) => f.path === 'external/acme/shared_models/accounts/user_skir.ex',
  );
  assert.match(
    shared.code,
    /defmodule My\.App\.External\.Acme\.SharedModels\.Accounts\.UserSkir\.User do/,
  );
  assert.match(
    shared.code,
    /My\.App\.External\.Acme\.Base\.TypesSkir\.Address/,
  );
  assert.match(
    shared.code,
    /key: "@acme\/shared-models\/accounts\/user\.skir:User\.Pet"/,
  );
  assert.match(
    files.find((f) => f.path === 'user_skir.ex').code,
    /response: \{:record, My\.App\.External\.Acme\.SharedModels\.Accounts\.UserSkir\.User\}/,
  );
  assert.deepEqual(moduleInfo('@123/456/types.skir', 'My.App'), {
    name: 'My.App.External.N123.N456.TypesSkir',
    path: 'external/123/456/types_skir.ex',
  });
  for (const [repo, module] of [
    ['_123', 'N123'],
    ['.123', 'N123'],
    ['-123', 'N123'],
    ['___', 'N'],
  ]) {
    assert.equal(
      moduleInfo(`@acme/${repo}/types.skir`, 'My.App').name,
      `My.App.External.Acme.${module}.TypesSkir`,
    );
  }
  assert.throws(
    () =>
      generateCode(
        input([
          record('@acme/shared/a.skir', ['A'], 'struct', []),
          record('external/acme/shared/a.skir', ['A'], 'struct', []),
        ]),
      ),
    /collision/,
  );
});

test('invalid compiler IR fails before producing partial output', () => {
  const cases = [
    [
      (i) => {
        i.recordMap = {};
      },
      /recordMap/,
    ],
    [
      (i) => {
        i.modules.push(i.modules[0]);
      },
      /collision/,
    ],
    [
      (i) => {
        i.modules[0].records[0].modulePath = 'wrong.skir';
      },
      /mismatch/,
    ],
    [
      (i) => {
        i.modules[0].records[0].recordAncestors = [];
      },
      /ancestor/,
    ],
    [
      (i) => {
        i.modules[0].records.push({
          ...i.modules[0].records[0],
          recordAncestors: [{ name: { text: 'Other' } }],
        });
      },
      /Duplicate record key/,
    ],
    [
      (i) => {
        i.recordMap.clear();
      },
      /record/,
    ],
    [
      (i) => {
        i.modules[0].records[0].record.recordType = 'class';
      },
      /record kind/,
    ],
    [
      (i) => {
        i.modules[0].records[0].record.numSlotsInclRemovedNumbers++;
      },
      /slot count/,
    ],
    [
      (i) => {
        i.modules[0].records[0].record.fields[0].type = undefined;
      },
      /Unresolved/,
    ],
    [
      (i) => {
        i.modules[0].records[0].record.fields[0].type = p('uint128');
      },
      /primitive/,
    ],
    [
      (i) => {
        i.modules[0].records[0].record.fields[0].type = { kind: 'map' };
      },
      /type kind/,
    ],
    [
      (i) => {
        i.modules[0].records[0].record.fields[0].type = ref('missing');
      },
      /record/,
    ],
    [
      (i) => {
        i.modules[0].constants.push({ name: { text: 'MISSING' } });
      },
      /constant/,
    ],
    [
      (i) => {
        const m = i.modules.find((m) => m.methods.length);
        m.methods.push({ ...m.methods[0] });
      },
      /collision/,
    ],
    [
      (i) => {
        const m = i.modules.find((m) => m.constants.length);
        m.constants.push({ ...m.constants[0] });
      },
      /collision/,
    ],
  ];
  for (const [mutate, error] of cases) {
    const i = exampleInput();
    mutate(i);
    assert.throws(() => generateCode(i), error);
  }
  for (const path of [
    '../bad.skir',
    '/bad.skir',
    'bad.txt',
    'a\\b.skir',
    'a//b.skir',
    '@external/b.skir',
    '@acme/repo.skir',
    '@acme/repo/../bad.skir',
    '@acme/repo//bad.skir',
    '@acme/repo/@bad.skir',
    '@ac_me/repo/bad.skir',
    '@acme/../bad.skir',
    '123.skir',
  ]) {
    assert.throws(() =>
      generateCode(input([record(path, ['A'], 'struct', [])])),
    );
  }
  for (const fields of [
    [field('userID', 0, p('string')), field('user_id', 1, p('string'))],
    [field('a', 0, p('string')), field('b', 0, p('string'))],
    ...['__struct__', '__skir_unknown_fields__', 'bad!'].map((n) => [
      field(n, 0, p('string')),
    ]),
    ...[-1, 1.5, 0x80000000].map((n) => [field('a', n, p('string'))]),
  ])
    assert.throws(() =>
      generateCode(input([record('a.skir', ['A'], 'struct', fields)])),
    );
  for (const removed of [[-1], [1.5], [0x80000000], [1, 1], [0]]) {
    assert.throws(() =>
      generateCode(
        input([
          record(
            'a.skir',
            ['A'],
            'struct',
            [field('a', 0, p('string'))],
            removed,
          ),
        ]),
      ),
    );
  }
  for (const n of [-1, 1.5, 0x100000000]) {
    const i = exampleInput();
    i.modules.find((m) => m.methods.length).methods[0].number = n;
    assert.throws(() => generateCode(i), /method number/);
  }
  assert.throws(
    () =>
      generateCode(
        input([
          record('a-b.skir', ['A'], 'struct', []),
          record('a_b.skir', ['A'], 'struct', []),
        ]),
      ),
    /collision/,
  );
  assert.throws(
    () =>
      generateCode(
        input([record('a.skir', ['E'], 'enum', [field('unknown', 1)])]),
      ),
    /Reserved/,
  );
  for (const slots of ['raise("injected")', -1, 1.5, NaN, Infinity, 1]) {
    const malicious = record('a.skir', ['E'], 'enum', []);
    malicious.record.numSlotsInclRemovedNumbers = slots;
    assert.throws(() => generateCode(input([malicious])), /slot count/);
  }
  // A DAG can expand exponentially despite having few source records.
  const dag = Array.from({ length: 18 }, (_, n) =>
    record(
      'a.skir',
      [`R${n}`],
      'struct',
      n
        ? [
            field('left', 0, ref(`a.skir:R${n - 1}`)),
            field('right', 1, ref(`a.skir:R${n - 1}`)),
          ]
        : [],
    ),
  );
  assert.throws(() => generateCode(input(dag)), /Expanded defaults/);
});

test('Elixir literal escaping preserves compiler values and rejects non-JSON constants', () => {
  for (const [value, expected] of [
    [null, 'nil'],
    [true, 'true'],
    [-0, '-0.0'],
    [1e-100, '1.0e-100'],
    [1e20, '100000000000000000000'],
    [[1, 'x'], '[1, "x"]'],
    ['#{raise "bad"}', String.raw`"\#{raise \"bad\"}"`],
  ]) {
    assert.equal(literal(value), expected);
  }
  assert.equal(atom('with space'), ':"with space"');
  for (const value of [undefined, NaN, Infinity, {}])
    assert.throws(() => literal(value));
});
