# skir-elixir-gen — native Elixir code generation for Skir

An **unofficial, initial implementation**, maintained in this standalone repository. It emits native
Elixir structs and tagged enum values. Neither the generated code nor its runtime
uses Gleam, a port, a NIF, or a JavaScript process for serialization.

**Verification status:** the dependency-free generator core has been executed and
its tests pass. The Elixir runtime, plugin loading through the real Skir compiler,
and cross-language integration have **not** been executed in the authoring
sandbox: Elixir/Erlang are absent and package downloads are unavailable. This is
not a production-readiness claim. See [VERIFICATION.md](VERIFICATION.md) for the
actual commands, results, and remaining release gates.

## Repository

This repository starts from the existing `skir-elixir-0.3.0` implementation.
It contains the npm generator and its companion Elixir runtime; both remain
unpublished packages. The repository is private initially.

```sh
git clone https://github.com/mishmish-dev/skir-elixir-gen.git
cd skir-elixir-gen
npm install
npm run check
npm test
```

The reports under `reports/` and [VERIFICATION.md](VERIFICATION.md) record the
original implementation's verification results. They do not establish that the
Elixir runtime or cross-language tests have passed in this repository.

## Layout

```text
src/                       npm plugin and dependency-free generator core
runtime/                   native codecs + SkirRPC service/client/Plug adapter
example/skir-src/           real Skir example schemas
example/lib/skirout/        sample generated Elixir (from resolved-IR fixtures)
test/                      Node generator-core tests
runtime/test/              ExUnit codec + SkirRPC + Plug tests
example/test/              generated types, evolution, and RPC round-trip tests
scripts/integration.mjs    real compiler + upstream TypeScript serialization interoperability
scripts/rpc-parity.mjs   official TypeScript ↔ native Elixir SkirRPC oracle
.github/workflows/ci.yml   CI definition; not executed in the authoring sandbox
```

The plugin targets the interfaces declared by `skir@1.2.22` and
`skir-internal@0.2.21`. Reference dependencies are pinned to `skir-client@1.0.19`
and `skir-typescript-gen@1.0.11`. These versions were read from upstream source
manifests; registry installation was not verified here. Runtime target: Elixir
1.14+ with a compatible Erlang/OTP release. Node target: 20+.

## Run the example

From the unpacked project root, on a machine with Node, Elixir and Mix:

```sh
npm install
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

The generated API is:

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
[`docs/SKIRRPC.md`](docs/SKIRRPC.md) for the complete API and
[`docs/SKIRRPC_PARITY.md`](docs/SKIRRPC_PARITY.md) for the official-runtime parity audit.


Every generated record module has `new/1` (structs only), `default/0`, `type/0`,
`schema/0`, and these function pairs, each accepting keyword options:

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

## Use in an existing application

Vendor this source package, for example under `vendor/skir-elixir`. Add the
runtime as a **local** dependency in your application's `mix.exs`:

```elixir
{:skir, path: "vendor/skir-elixir/runtime"}
```

Neither component is published by this implementation. Do not assume
`{:skir, "~> 0.2"}` on Hex or an npm registry package belongs to this project.

Install the generator locally alongside the Skir compiler:

```sh
npm install --save-dev skir@1.2.22 ./vendor/skir-elixir
```

Then add this generator entry to your existing `skir.yml`:

```yaml
generators:
  - mod: skir-elixir-gen
    outDir: ./lib/skirout
    config:
      namespace: MyApp.Protocol
```

Keep your existing Dart generator entry. Both bindings must be generated from the
same schemas. This package does not replace or change the Dart generator.
Run `npx skir gen` before `mix compile`. Generated files require the runtime Mix
dependency. A local package install into the project containing `skir` lets the
compiler resolve the generator by its npm module name. For unusual monorepo or
package-manager resolution layouts, use an absolute `file:` URL, as the example
configuration script does.

`namespace` is the only generator option. It defaults to `Skir.Generated` and
must be an Elixir module namespace. For `accounts/user.skir` defining `User`, the
module is `MyApp.Protocol.Accounts.UserSkir.User`. A nested `User.Pet` becomes
`MyApp.Protocol.Accounts.UserSkir.User.Pet`. Constants and methods are functions
on the source-file module, for example `UserSkir.alice_const/0` and
`UserSkir.get_user_method/0`.

## Data model and encoding

| Skir type | Native value |
|---|---|
| `struct` | Generated `%Module{}` with declared fields and internal unknown-field metadata |
| Constant enum variant | Atom such as `:connected` |
| Payload enum variant | Tuple such as `{:user_created, user}` |
| Implicit enum unknown | `:unknown` |
| Preserved future variant | `{:unknown, %Skir.Unknown{...}}` |
| Optional | `nil` or the underlying value |
| Array / keyed array | List; keyed fields also get `index_<field>/1` |
| `bool` | Boolean |
| `int32`, `int64`, `hash64` | Range-checked integer |
| `float32`, `float64` | Finite number, `:nan`, `:infinity`, or `:neg_infinity` |
| `string` / `bytes` | UTF-8 binary / arbitrary binary |
| `timestamp` | Integer Unix milliseconds, within ±8,640,000,000,000,000 |

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

## Tests

```sh
# Runs without downloading any dependencies; exercises the generator core only.
npm test
npm run check
npm run generate:fixtures

# Requires Elixir and access to Hex for Jason.
npm run test:runtime
npm run test:elixir

# Requires npm dependencies, Elixir and Hex. Compares raw SkirRPC behavior with
# the official TypeScript Service implementation.
npm run test:rpc-parity

# Requires npm dependencies, Elixir and Hex. Uses real .skir input, not the IR fixture.
npm run test:integration

# Full gate, used by the included CI definition.
npm run test:all
```

`generate:fixtures` intentionally uses a hand-built resolved-IR fixture, not a
Skir parser. The integration command overwrites those example outputs by invoking
the real compiler, compiles the native modules with warnings-as-errors, runs the
example tests, and exchanges JSON and byte-for-byte binary vectors with the
upstream TypeScript runtime. It includes deterministic generated cases and
unknown-data preservation. A missing tool is a failure, never a skipped success.
It writes `.artifacts/reference-vectors.json` and `.artifacts/elixir-vectors.json`.

## Current boundaries / release gate

This is an initial native implementation, not an officially supported Skir
backend. Local imports, nested records, optional/array types, constants and method
metadata are implemented. GitHub dependency module paths beginning with `@` are
currently rejected; vendor those schemas as local paths before generation.

Native SkirRPC transport, generated client/server helpers, Phoenix/Plug routing,
Studio, and reflection are included. The SkirRPC surface has been source-audited
against the official TypeScript, Dart, and Gleam runtimes; where TypeScript and
Dart agree, 0.3.0 treats that behavior as the compatibility baseline. The
executable TypeScript ↔ Elixir raw-response oracle is included as
`npm run test:rpc-parity` but could not run in this sandbox because Elixir/Mix and
installed npm dependencies are unavailable.

Not included: streaming RPC (not part of the current SkirRPC wire protocol), OTP
release benchmarking, a live Dart ↔ Phoenix interoperability run, or independent
security/fuzz review. One current upstream TypeScript `list` anomaly writes the
method name into the `number` field; Elixir intentionally follows the numeric-ID
behavior used by Dart and Gleam instead. See `docs/SKIRRPC_PARITY.md`.

Before adopting it in production, run the complete test gate on the intended
Elixir/OTP versions, add your schemas and Dart-produced vectors, review the native
codec implementation, and fuzz malformed inputs. After dependencies can be
resolved, commit `package-lock.json` and the Mix lockfiles. The authoring sandbox
could not produce dependency locks or execute the CI definition. Neither the npm generator nor the Elixir runtime has been published.

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
