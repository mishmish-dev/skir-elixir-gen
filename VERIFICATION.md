# Verification

The generator tests run against the published Hex runtime `skir_elixir_client`
0.2.0, pinned exactly in `example/mix.exs` and `example/mix.lock`.
The split preserves each existing test in exactly one repository.

| Check | Generator | Client |
|---|---|---|
| Generator unit tests | Five Node tests, including real-compiler GitHub/transitive imports | — |
| Generated binding tests | 127 ExUnit tests, including all 101 upstream goldens | — |
| Serialization interoperability | 209 vectors through the real compiler and TypeScript reference | — |
| Runtime unit tests | — | 44 ExUnit tests |
| Raw RPC oracle | — | 16 server cases plus GET/POST client wire comparisons |
| Distribution consumer | npm archive installed in a fresh compiler project; transitive imports executed in Elixir | Hex archive installed in a fresh Mix project |
| Malformed-input checks | Deterministic bounded mutations across six generated schemas, three decoders and both unknown-field policies | — |
| OTP release benchmark | Binary/JSON codec medians inside the release executable; environment recorded | — |
| Security review | Independent agent source review and targeted runtime probes; findings in docs/SECURITY_REVIEW.md | Runtime fixes require a separate release |
| CI | Node 20; Elixir 1.18.4 / OTP 27 and Elixir 1.20.4 / OTP 27/28/29 | Same matrix, independently |

Generator `npm run test:all` reports JavaScript coverage. Mix coverage measures
handwritten example code, excludes generated `Example.Protocol.*` modules and
retains the 90% threshold. Client code is a dependency, not instrumented here.
The client's standalone unit suite runs separately without a coverage gate.
The prior combined 98.96% runtime/example result is not a coverage claim for
either separated suite. Historical implementation reports remain under `reports/`.

The golden schema is unchanged from the pinned upstream corpus; provenance is
in `fixtures/upstream/skir-golden-tests/README.md`. Cross-format unknown-field
cases explicitly check `:unknown_format` before discarding unknown data.

The TypeScript reference has two documented anomalies: long bytes crossing its
initial buffer are checked against its decoder and the wire specification;
RPC list method numbers are normalized only in the client-owned oracle.
Float32 values normalize through binary to make rounding explicit.

GitHub schema import paths starting with `@` are supported; reflection preserves
the original paths. The archive gate exercises compiler-cached direct/transitive
dependencies without requiring live GitHub downloads. Client-language-specific
deployments are not a generator release requirement. The existing reference
serializer is an oracle for the shared wire format.

Deterministic mutation checks and an independent agent review are included;
third-party certification and exhaustive fuzzing are not claimed. The review's
two runtime RPC resource-limit findings remain open in Hex 0.2.0. See
[the review](docs/SECURITY_REVIEW.md) for reproduction and adoption requirements.

## Upstream references


- Skir compiler plugin interface: https://github.com/gepheum/skir-internal/blob/main/src/types.ts
- Configuration and setup: https://skir.build/docs/setup
- Language and type mappings: https://skir.build/docs/language-reference
- Wire format: https://skir.build/docs/serialization
- Evolution and trust boundary: https://skir.build/docs/schema-evolution
- TypeScript reference runtime: https://github.com/gepheum/skir-typescript-client/blob/main/src/skir-client.ts
- Gleam reference wire behavior: https://github.com/gepheum/skir-gleam-client/tree/main/src/skir_client/internal

These are references for the implementation, not claims of upstream endorsement.
The new generator and native Elixir runtime are licensed under MIT.
