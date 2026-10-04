# Verification

The split preserves each existing test in exactly one repository.

| Check | Generator | Client |
|---|---|---|
| Generator unit tests | Four table-driven Node tests | — |
| Generated binding tests | 127 ExUnit tests, including all 101 upstream goldens | — |
| Serialization interoperability | 209 vectors through the real compiler and TypeScript reference | — |
| Runtime unit tests | — | 44 ExUnit tests |
| Raw RPC oracle | — | 16 server cases plus GET/POST client wire comparisons |
| Distribution consumer | npm archive installed in a fresh compiler project | Hex archive installed in a fresh Mix project |
| CI | Node 20, Elixir 1.20.4, OTP 27/28/29 | Same matrix, independently |

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

GitHub schema import paths starting with `@` remain unsupported. No live
Dart/Phoenix deployment or independent security/fuzz audit is claimed.
