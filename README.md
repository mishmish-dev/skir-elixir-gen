[![npm](https://img.shields.io/npm/v/skir-elixir-gen)](https://www.npmjs.com/package/skir-elixir-gen)
[![Hex](https://img.shields.io/hexpm/v/skir_elixir_client)](https://hex.pm/packages/skir_elixir_client)
[![HexDocs](https://img.shields.io/badge/runtime_docs-HexDocs-blue)](https://hexdocs.pm/skir_elixir_client)
[![build](https://github.com/mishmish-dev/skir-elixir-gen/actions/workflows/ci.yml/badge.svg)](https://github.com/mishmish-dev/skir-elixir-gen/actions/workflows/ci.yml)

# skir-elixir-gen — native Elixir code generation for Skir

An unofficial Skir compiler plugin that emits native Elixir structs, enums,
codecs, constants, reflection and RPC helpers. Generated code uses the separate
[skir_elixir_client](https://github.com/mishmish-dev/skir-elixir-client) Mix package.
This repository contains no runtime source or runtime unit tests.

## Set up

Add the runtime dependency to your application's `mix.exs`:

```elixir
{:skir_elixir_client, "~> 0.3"}
```

The Hex package is `skir_elixir_client`; its Mix application is `:skir_elixir_client`, and
its public modules use `Skir.*`. Run `mix deps.get`.

Install the generator alongside the Skir compiler:

```sh
npm install --save-dev skir skir-elixir-gen
```

Add this entry under `generators` in your `skir.yml`:

```yaml
generators:
  - mod: skir-elixir-gen
    outDir: ./lib/skirout
    config:
      namespace: MyApp.Protocol
```

Run `npx skir gen` before `mix compile`. Node is required for generation,
not for running the generated Elixir code. Skir manages directories named
`skirout`; do not put hand-written files there. Keep any other language
generators in the same configuration so they share the same schemas.

`namespace` is the only generator option. It defaults to `Skir.Generated` and
must be an Elixir module namespace. For `accounts/user.skir` defining `User`, the
module is `MyApp.Protocol.Accounts.UserSkir.User`. A nested `User.Pet` becomes
`MyApp.Protocol.Accounts.UserSkir.User.Pet`. Constants and methods are functions
on the source-file module, for example `UserSkir.alice_const/0` and
`UserSkir.get_user_method/0`.

## Elixir generated-code guide

The examples below use [the example schema](https://github.com/mishmish-dev/skir-elixir-gen/blob/main/example/skir-src/user.skir) with
`namespace: Example.Protocol`. Follow the same pattern with your own namespace.

### Structs, enums, and serialization

```elixir
alias Example.Protocol.UserSkir.{User, Event}

user = User.new(id: 42, name: "Alice")
%User{name: "Alice"} = user

# JSON terms and JSON strings are separate APIs.
[42, 0, "Alice"] = User.to_json!(user)
{:ok, json} = User.encode_json(user)
{:ok, ^user} = User.decode_json(json)

# Framed Skir binary, not Erlang external-term format.
{:ok, binary} = User.encode(user)
{:ok, ^user} = User.decode(binary)

# Pure Elixir sum types: atoms for constants, tuples for payloads.
event = {:user_created, user}
{:ok, event_binary} = Event.encode(event)
{:ok, {:user_created, %User{id: 42}}} = Event.decode(event_binary)

# Debug representation; do not use readable JSON as a rename-safe contract.
%{"id" => 42, "name" => "Alice"} = User.to_json!(user, format: :readable)
```

The zero between `id` and `name` is the example schema's permanently removed
field 1. It is not an inferred field position.

### SkirRPC services

The same source module also exposes native SkirRPC helpers. For the example
`GetUser` method:

```elixir
alias Example.Protocol.UserSkir
alias Skir.RPC.{Service, ServiceClient}

service =
  Service.new()
  |> UserSkir.add_get_user(fn id, _metadata ->
    {:ok, %User{id: id, name: "Alice"}}
  end)

client = ServiceClient.new!("https://api.example.com/rpc")
{:ok, %User{}} = UserSkir.get_user(client, 42)
%User{} = UserSkir.get_user!(client, 42)
```

Phoenix/Plug applications can mount `Skir.RPC.Plug` with `forward "/rpc",
Skir.RPC.Plug, service: &MyApp.RPC.service/0`. Studio (`?studio`), method
reflection (`?list`), controlled/unknown errors, request metadata, the compact
SkirRPC HTTP wire format, and a pluggable client transport are implemented. See
[the client RPC guide](https://hexdocs.pm/skir_elixir_client/skirrpc.html) for the complete API and
[the client parity audit](https://github.com/mishmish-dev/skir-elixir-client/blob/main/docs/SKIRRPC_PARITY.md) for the official-runtime parity audit.

### Generated function reference

Every generated record module has `new/1` (structs only), `default/0`, `type/0`,
and these function pairs, each accepting keyword options:

```elixir
User.to_json(value)       # {:ok, JSON-compatible Elixir term}
User.from_json(term)      # {:ok, %User{}}
User.encode_json(value)   # {:ok, UTF-8 JSON binary}
User.decode_json(json)    # {:ok, %User{}}
User.encode(value)        # {:ok, framed Skir binary}
User.decode(binary)      # {:ok, %User{}}; JSON bytes are also accepted
# The same names ending in ! return the value or raise Skir.Error.
```

Non-bang serialization functions return `{:error, %Skir.Error{reason: atom,
path: [...], message: string}}` on validated input failures. Unexpected programming
errors are not swallowed. `new/1` rejects unknown attributes but validates field
values only when serializing; typespecs are not runtime enforcement.

### Defaults and modified copies

```elixir
%User{id: 0, name: ""} = User.default()
updated = %{user | name: "Bob"}
```

Structs are immutable Elixir values. `new/1` accepts a map or keyword list;
omitted fields use schema defaults. Constant enum variants are atoms and payload
variants are tuples, so use ordinary Elixir pattern matching:

```elixir
case event do
  {:user_created, %User{name: name}} -> name
  :unknown -> "Unknown event"
  {:unknown, _metadata} -> "Future event"
  _other -> "Another event"
end
```

### Constants

Constants are zero-arity functions on the source-file module:

```elixir
alias Example.Protocol.UserSkir
alice = UserSkir.alice_const()
```

### Reflection

Inspect any generated type with `Skir.RPC.TypeDescriptor`:

```elixir
descriptor = Skir.RPC.TypeDescriptor.to_map(User.type())
json = Skir.RPC.TypeDescriptor.to_json(User.type())
```

Descriptors include nested types, field numbers, enum variants, documentation,
and removed slots. `User.type/0` is the public type handle; `schema/0` is internal
codec metadata. See the [runtime API reference](https://hexdocs.pm/skir_elixir_client).

## Data model and encoding

| Skir type                  | Native value                                                                   |
| -------------------------- | ------------------------------------------------------------------------------ |
| `struct`                   | Generated `%Module{}` with declared fields and internal unknown-field metadata |
| Constant enum variant      | Atom such as `:connected`                                                      |
| Payload enum variant       | Tuple such as `{:user_created, user}`                                          |
| Implicit enum unknown      | `:unknown`                                                                     |
| Preserved future variant   | `{:unknown, %Skir.Unknown{...}}`                                               |
| Optional                   | `nil` or the underlying value                                                  |
| Array / keyed array        | List; keyed fields also get `index_<field>/1`                                  |
| `bool`                     | Boolean                                                                        |
| `int32`, `int64`, `hash64` | Range-checked integer                                                          |
| `float32`, `float64`       | Finite number, `:nan`, `:infinity`, or `:neg_infinity`                         |
| `string` / `bytes`         | UTF-8 binary / arbitrary binary                                                |
| `timestamp`                | Integer Unix milliseconds, within ±8,640,000,000,000,000                       |

Dense JSON and binary use the compiler's field numbers, retain removed-slot
positions, and omit trailing defaults. The binary API prefixes values with ASCII
`skir`. Large 64-bit JSON integers use decimal strings outside JavaScript's exact
integer range. Bytes use base64 in dense JSON and `hex:` in readable JSON.
Finite float32 values are rounded when encoded to binary, not when encoded to
JSON. Non-finite BEAM values are represented explicitly as atoms.

Nested struct defaults are emitted as literal struct-shaped maps, avoiding
compile-order cycles between generated modules. Unavoidable hard-recursive
defaults terminate in `:skir_default`. The encoder accepts that sentinel only in
struct positions. Explicit default-only recursive chains may canonicalize back
to the finite default; do not rely on their materialized depth surviving a
round trip. Prefer optional links for ordinary application trees.

Keyed-array helpers build a map and **raise `ArgumentError` on duplicate keys**.
Keys can follow nested fields and enum `.kind`. They do not automatically expand
a hard-recursive `:skir_default` sentinel in a key path.

## Evolution and unknown fields

Decoding **discards unknown data by default**, matching the conservative upstream
policy. Preserve it explicitly only when the source is trusted:

```elixir
old_reader = User.from_json!(newer_dense_json, unknown_fields: :preserve)
updated = %{old_reader | name: "Bob"}

# Retained fields survive same-format encoding without repeating the option.
forwarded = User.to_json!(updated)

# Dense unknown values have no type information for conversion to binary.
{:error, %Skir.Error{reason: :unknown_format}} = User.encode(updated)

# Explicitly authorize lossy conversion when that is appropriate.
binary_without_unknowns = User.encode!(updated, unknown_fields: :discard)
```

Unknown binary field values retain their exact original bytes. Unknown values
are validated before being emitted. Removed fields/variants are discarded rather
than treated as newly unknown fields. Readable unknown field names can be
preserved, but readable JSON is not safe across field renames.

Constant-to-payload enum evolution is handled in both directions: reading the
old constant with the new schema supplies a default payload; reading the new
payload with the old constant schema ignores the payload. No atom is created from
an incoming enum name or JSON field name.

Unknown preservation can otherwise allow an untrusted client to smuggle a future
field through an older service. Do not enable it globally at a public API boundary.

## Validation and limits

Serialization options:

```elixir
[
  max_bytes: 4_194_304,
  max_depth: 64,
  max_collection_length: 100_000,
  max_nodes: 200_000,
  unknown_fields: :discard  # decode default; encode preserves already-retained data
]
```

JSON encoding additionally accepts `format: :dense` (default) or `:readable`.
Binary APIs accept only `format: :binary`. Unknown options and invalid limits
are errors.

Wire decoders bound input bytes, nesting, collection lengths, and aggregate
parsed nodes, and reject trailing binary bytes. JSON nesting is pre-scanned
before Jason builds a tree. UTF-8, base64, numbers and payload shapes are checked.
These are defensive measures, **not a completed security audit or a substitute
for HTTP body/time limits**. Native `to_json/3` receives an already-allocated
application tree; its byte limits on terms are not a wire-size guarantee for the
whole returned tree. Apply transport limits before parsing untrusted requests.

This runtime intentionally rejects some malformed/out-of-range values that
upstream implementations may coerce or clamp. It does not claim identical error
permissiveness on invalid inputs. For very large valid timestamps beyond Elixir's
calendar range, readable output contains `unix_millis` without `formatted`.

## Development

Clone both repositories as siblings and select the client revision used by CI:

```sh
git clone https://github.com/mishmish-dev/skir-elixir-gen.git
git clone https://github.com/mishmish-dev/skir-elixir-client.git
cd skir-elixir-gen
git -C ../skir-elixir-client checkout "$(cat .client-revision)"
npm ci --ignore-scripts
mix local.hex --force
mix local.rebar --force
npm run test:all
```

Requires Node 20+, Elixir and Mix. CI pins Elixir 1.20.4 and OTP 27.3.4.18,
28.5.0.7 and 29.1.1. The private client checkout uses a read-only deploy key.
Generator and runtime versions are independent; npm and Hex releases are owned
by their respective repositories. See [release instructions](docs/RELEASING.md).

## Layout

- `src/`: npm plugin and generator core.
- `example/`: schemas, generated bindings and 127 binding/integration tests.
- `test/`: four table-driven Node generator tests.
- `fixtures/upstream/`: pinned upstream golden corpus provenance and license.
- `scripts/integration.mjs`: real compiler and 209 TypeScript interoperability vectors.
- `scripts/package-smoke.mjs`: fresh consumer of the actual npm archive.

Runtime unit tests and the raw RPC oracle belong to the client repository.
See [VERIFICATION.md](VERIFICATION.md) for coverage scope and compatibility limits.

## Run the example

From the cloned generator repository, on a machine with Node, Elixir and Mix:

```sh
npm ci --ignore-scripts
mix local.hex --force
mix local.rebar --force

# Uses the real Skir compiler; also emits the TypeScript reference binding.
npm run generate

cd example
mix deps.get
iex -S mix
```

`npm run generate` first writes a machine-specific `example/skir.yml` with an
absolute `file:` URL for this local plugin. Do not commit that generated config.
It then invokes `skir gen` in `example/`. Skir manages directories named
`skirout`; do not put hand-written files there.

## Tests

```sh
# Requires npm dependencies; exercises the generator and plugin configuration.
npm test
npm run test:coverage
npm run check
npm run generate:fixtures

# Requires Elixir and access to Hex for runtime and test-only HTTP dependencies.
npm run test:elixir

# Requires npm dependencies, Elixir and Hex. Uses real .skir input, not the IR fixture.
npm run test:integration

# Full gate, used by the included CI definition.
npm run test:all
```

`generate:fixtures` intentionally uses a hand-built resolved-IR fixture, not a
Skir parser. Both `test:elixir` and the integration command regenerate example outputs using
the real compiler. Integration compiles the native modules with warnings-as-errors, runs the
127 example tests once, and exchanges JSON and byte-for-byte binary vectors with the
upstream TypeScript runtime. It includes deterministic generated cases and
unknown-data preservation. A missing tool is a failure, never a skipped success.
It writes `.artifacts/reference-vectors.json` and `.artifacts/elixir-vectors.json`.

The example suite runs all 101 cases from the unmodified upstream golden corpus
[v1.0.6](https://github.com/gepheum/skir-golden-tests/tree/v1.0.6), including
infinities and large collections. JSON expectations compare decoded terms; binary
expectations remain byte-for-byte. Four cross-format unknown-field cases also
check Elixir's `:unknown_format` error before explicitly discarding the retained
fields. Only the repository prefix in reflection IDs is translated for the
vendored schema. See [fixture provenance](fixtures/upstream/skir-golden-tests/README.md).

Additional real schemas test constructors, updates, defaults, nested names,
keyed arrays, constants, and recursive types. A test-only Cowboy server on an
OS-assigned localhost port exercises generated GET/POST clients through OTP
`:httpc`, errors, metadata, and reflection. Four fresh BEAM processes test
recursive defaults, codecs, reflection, and concurrent initialization. The concurrent scenario
releases workers together after a readiness barrier and mixes first access to
defaults, codecs, and descriptors. These checks run through `test:elixir`,
`test:all`, and every CI matrix entry.

The full gate reports JavaScript coverage with Node and Elixir line coverage
with Mix. Mix enforces a 90% threshold for handwritten example code; generated
`Example.Protocol.*` modules are excluded. The client dependency is not
instrumented here and its unit tests are not included in this suite. Generated
bindings are checked by the golden and native API tests. Fresh BEAM subprocesses
do not contribute to the parent coverage report. CI uploads coverage and
reference vectors for every matrix entry.

## Current boundaries / release gate

This is an initial native implementation, not an officially supported Skir
backend. Local imports, nested records, optional/array types, constants and method
metadata are implemented. GitHub dependency module paths beginning with `@` are
currently rejected; vendor those schemas as local paths before generation.

Native SkirRPC transport, generated client/server helpers, Phoenix/Plug routing,
Studio, and reflection are included. The SkirRPC surface has been source-audited
against the official TypeScript, Dart, and Gleam runtimes; where TypeScript and
Dart agree, 0.3.0 treats that behavior as the compatibility baseline. The
executable TypeScript ↔ Elixir raw-response oracle runs in the client repository.

Not included: streaming RPC (not part of the current SkirRPC wire protocol), OTP
release benchmarking, a live Dart ↔ Phoenix interoperability run, or independent
security/fuzz review. One current upstream TypeScript `list` anomaly writes the
method name into the `number` field; Elixir intentionally follows the numeric-ID
behavior used by Dart and Gleam instead. See the [client RPC parity guide](https://github.com/mishmish-dev/skir-elixir-client/blob/main/docs/SKIRRPC_PARITY.md).

Before adopting it in production, run the complete test gate on the intended
Elixir/OTP versions, add your schemas and Dart-produced vectors, review the native
codec implementation, and fuzz malformed inputs. Commit `package-lock.json` and
the Mix lockfiles before releasing a reproducible production baseline. The generator is published to npm as `skir-elixir-gen`; the runtime is
published to Hex as `skir_elixir_client`.

## Upstream references used

- Skir compiler plugin interface: https://github.com/gepheum/skir-internal/blob/main/src/types.ts
- Configuration and setup: https://skir.build/docs/setup
- Language and type mappings: https://skir.build/docs/language-reference
- Wire format: https://skir.build/docs/serialization
- Evolution and trust boundary: https://skir.build/docs/schema-evolution
- TypeScript reference runtime: https://github.com/gepheum/skir-typescript-client/blob/main/src/skir-client.ts
- Gleam reference wire behavior: https://github.com/gepheum/skir-gleam-client/tree/main/src/skir_client/internal

These are references for the implementation, not claims of upstream endorsement.
The new generator and native Elixir runtime are licensed under MIT.
