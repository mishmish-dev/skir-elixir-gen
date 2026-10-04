# Developing skir-elixir-gen

Clone this repository; the example and CI download the exact runtime release
`skir_elixir_client` 0.2.0 from Hex. No client checkout or deploy key is required:

```sh
git clone https://github.com/mishmish-dev/skir-elixir-gen.git
cd skir-elixir-gen
npm ci --ignore-scripts
mix local.hex --force
mix local.rebar --force
npm run test:all
```

Requires Node 20+, Elixir 1.18+, OTP 27+ and Mix. CI tests the minimum supported
Elixir 1.18.4 / OTP 27.3.4.18 pair and Elixir 1.20.4 with OTP 27.3.4.18,
28.5.0.7 and 29.1.1.
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
mix deps.get --check-locked
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
vendored schema. See [fixture provenance](https://github.com/mishmish-dev/skir-elixir-gen/blob/main/fixtures/upstream/skir-golden-tests/README.md).

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
