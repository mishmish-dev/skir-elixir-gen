import {test} from 'node:test';
import assert from 'node:assert/strict';
import {generateCode} from '../src/generator.js';
import {input, record, field, primitive as p, optional, array, ref, exampleInput} from '../fixtures/schema.mjs';

const source = i => generateCode(i).files.map(f => f.code).join('\n');
test('emits native structs and tagged enum types, not Gleam calls', () => {
  const code = source(exampleInput());
  assert.match(code, /defmodule Example\.Protocol\.UserSkir\.User do/);
  assert.match(code, /defstruct/);
  assert.match(code, /\{:user_created, \(Example\.Protocol\.UserSkir\.User\.t\(\) \| :skir_default\)\}/);
  assert.doesNotMatch(code, /gleam|skir_client/);
});
test('uses compiler field numbers and retains removed-slot metadata', () => {
  const code = source(input([record('a.skir', ['A'], 'struct', [field('later', 7, p('string')), field('first', 0, p('int32'))], [1,2,3,4,5,6])]));
  assert.match(code, /name: :later, json_name: "later", number: 7/);
  assert.match(code, /slots: 8/);
  assert.match(code, /removed: \[1, 2, 3, 4, 5, 6\]/);
});
test('resolves nested and imported records', () => {
  const code = source(exampleInput());
  assert.match(code, /\{:record, Example\.Protocol\.CommonSkir\.Address\}/);
  assert.match(code, /\{:array, \{:record, Example\.Protocol\.UserSkir\.User\.Pet\}\}/);
});
test('emits constants through the dense decoder and method metadata', () => {
  const code = source(exampleInput());
  assert.match(code, /def alice_const\(\)/);
  assert.match(code, /Skir\.from_json!/);
  assert.match(code, /def get_user_method\(\)/);
  assert.match(code, /number: 12345/);
});
test('terminates recursive defaults without compile-time struct expansion', () => {
  const code = source(exampleInput());
  assert.match(code, /:skir_default/);
  assert.match(code, /:__struct__ => Example\.Protocol\.CommonSkir\.Address/);
  assert.doesNotMatch(code, /%Example\.Protocol\.CommonSkir\.Address\{/);
  assert.ok(code.length < 30000);
});
test('all primitive, optional and nested-array types have mappings', () => {
  const types = ['bool','int32','int64','hash64','float32','float64','timestamp','string','bytes'];
  const code = source(input([record('a.skir', ['A'], 'struct', types.map((t,i) => field(t,i,p(t))).concat([field('nested',9,array(optional(p('string'))))]))]));
  for (const t of types) assert.ok(code.includes(`type: :${t}`));
  assert.match(code, /\{:array, \{:optional, :string\}\}/);
});
test('output is deterministic even when module order changes', () => {
  const a = exampleInput(); const b = exampleInput(); b.modules.reverse();
  assert.deepEqual(generateCode(a), generateCode(b));
});
test('rejects unresolved types instead of silently omitting fields', () => {
  assert.throws(() => source(input([record('a.skir',['A'],'struct',[field('broken',0)])])), /unresolved/i);
});
test('rejects unknown primitive types', () => {
  assert.throws(() => source(input([record('a.skir',['A'],'struct',[field('broken',0,p('uint128'))])])), /primitive/i);
});
test('rejects missing recordMap entries', () => {
  assert.throws(() => source(input([record('a.skir',['A'],'struct',[field('broken',0,ref('missing'))])])), /record/i);
});
test('rejects field-name collisions after snake casing', () => {
  assert.throws(() => source(input([record('a.skir',['A'],'struct',[field('userID',0,p('string')),field('user_id',1,p('string'))])])), /collision/i);
});
test('rejects reserved internal field names', () => {
  for (const name of ['__struct__','__skir_unknown_fields__']) {
    assert.throws(() => source(input([record('a.skir',['A'],'struct',[field(name,0,p('string'))])])), /reserved/i);
  }
});
test('rejects module collisions', () => {
  assert.throws(() => source(input([record('a-b.skir',['A'],'struct',[]),record('a_b.skir',['A'],'struct',[])])), /collision/i);
});
test('rejects output path traversal and malformed namespaces', () => {
  assert.throws(() => source(input([record('../bad.skir',['A'],'struct',[])])), /path/i);
  assert.throws(() => source(input([], {namespace: 'Foo; System.cmd("x", [])'})), /namespace/i);
});
test('escapes Elixir interpolation in schema documentation and constants', () => {
  const i = exampleInput(); i.modules[0].records[0].record.doc.text = '#{System.cmd("bad", [])}';
  i.modules[0].constants.push({name:{text:'TEXT'},type:p('string'),valueAsDenseJson:'#{raise "bad"}'});
  const code = source(i);
  assert.match(code, /\\#\{/);
});
test('rejects duplicate field numbers', () => {
  assert.throws(() => source(input([record('a.skir',['A'],'struct',[field('a',0,p('string')),field('b',0,p('string'))])])), /number/i);
});
test('enum implicit unknown does not collide with user variants', () => {
  assert.throws(() => source(input([record('a.skir',['E'],'enum',[field('unknown',1)])])), /reserved/i);
});
test('empty records and modules are valid', () => {
  assert.match(source(input([record('a.skir',['Empty'],'struct',[])])), /defstruct/);
  assert.deepEqual(generateCode(input([])), {files:[]});
});

test('emits Elixir double-backslash default arguments', () => {
  const code = source(exampleInput());
  assert.ok(code.includes(String.raw`opts \\ []`));
  assert.ok(code.includes(String.raw`attrs \\ %{}`));
});

test('rejects out-of-range removed field numbers', () => {
  assert.throws(() => source(input([record('a.skir',['A'],'struct',[],[0x80000000])])), /removed field number/i);
});
test('emits keyed-array helpers using the resolved key path', () => {
  const user = record('a.skir',['User'],'struct',[field('id',0,p('int64'))]);
  const keyed = {...array(ref(user.record.key)),key:{path:[{name:{text:'id'}}],keyType:p('int64')}};
  const registry = record('a.skir',['Registry'],'struct',[field('users',0,keyed)]);
  const code = source(input([user,registry]));
  assert.match(code, /def index_users\(value\), do: Skir.index_by\(Map.fetch!\(value, :users\), \[:id\]\)/);
});
test('does not mutate the resolved compiler input', () => {
  const value = exampleInput(); const original = structuredClone(value);
  generateCode(value);
  assert.deepEqual(value, original);
});

test('emits complete SkirRPC method descriptors and a module method list', () => {
  const code = source(exampleInput());
  assert.match(code, /%Skir\.Method\{name: "GetUser", number: 12345, doc: "Load one user\.", request: :int64, response: \{:record, Example\.Protocol\.UserSkir\.User\}\}/);
  assert.match(code, /def methods\(\), do: \[get_user_method\(\)\]/);
  assert.match(code, /def get_user\(client, request, opts \\\\ \[\]\), do: Skir\.RPC\.ServiceClient\.invoke\(client, get_user_method\(\), request, opts\)/);
});

test('emits schema documentation needed for SkirRPC type descriptors', () => {
  const i = exampleInput();
  const user = i.modules.find(m => m.path === 'user.skir').records.find(r => r.record.name.text === 'User');
  user.record.doc.text = 'A user.';
  user.record.fields.find(f => f.name.text === 'name').doc.text = 'Display name.';
  const code = source(i);
  assert.match(code, /doc: "A user\."/);
  assert.match(code, /name: :name, json_name: "name", number: 2, doc: "Display name\."/);
});

test('retains keyed-array extractor metadata for SkirRPC reflection', () => {
  const user = record('a.skir',['User'],'struct',[field('id',0,p('int64'))]);
  const keyed = {...array(ref(user.record.key)),key:{path:[{name:{text:'id'}}],keyType:p('int64')}};
  const registry = record('a.skir',['Registry'],'struct',[field('users',0,keyed)]);
  const code = source(input([user,registry]));
  assert.match(code, /type: \{:array, \{:record, Skir\.Generated\.ASkir\.User\}, "id"\}/);
});

test('emits typed SkirRPC client helpers including bang variants', () => {
  const code = source(exampleInput());
  assert.match(code, /@spec get_user\(Skir\.RPC\.ServiceClient\.t\(\), integer\(\), keyword\(\)\) :: \{:ok, Example\.Protocol\.UserSkir\.User\.t\(\) \| :skir_default\} \| \{:error, Skir\.RPC\.RpcError\.t\(\)\}/);
  assert.match(code, /def get_user!\(client, request, opts \\\\ \[\]\), do: Skir\.RPC\.ServiceClient\.invoke!\(client, get_user_method\(\), request, opts\)/);
  assert.match(code, /@spec get_user!\(Skir\.RPC\.ServiceClient\.t\(\), integer\(\), keyword\(\)\) :: Example\.Protocol\.UserSkir\.User\.t\(\) \| :skir_default/);
});

test('emits typed SkirRPC server registration helpers', () => {
  const code = source(exampleInput());
  assert.match(code, /@type get_user_handler :: \(integer\(\), term\(\) -> \{:ok, Example\.Protocol\.UserSkir\.User\.t\(\) \| :skir_default\} \| \{:error, Skir\.RPC\.ServiceError\.t\(\) \| Skir\.RPC\.UnknownError\.t\(\)\}\)/);
  assert.match(code, /@spec add_get_user\(Skir\.RPC\.Service\.t\(\), get_user_handler\(\)\) :: Skir\.RPC\.Service\.t\(\)/);
  assert.match(code, /def add_get_user\(service, handler\), do: Skir\.RPC\.Service\.add_method\(service, get_user_method\(\), handler\)/);
});
