# Verification report — 2026-10-04

`npm run test:all` completed successfully on Node 24.17.0 and the official
`elixir:1.20.4` Docker image (Erlang/OTP 29). CI runs this same gate with Node 20
and Elixir 1.20.4 on pinned OTP 27.3.4.18, 28.5.0.7, and 29.1.1 releases.

| Check | Observed result |
|---|---|
| Generator syntax and Node tests | 45 passed, no failures or skips. |
| Runtime ExUnit/Plug tests | 59 passed. |
| Generated-code ExUnit tests | 24 passed with fixtures and again with real compiler output. |
| Raw RPC parity | 16 server cases and GET/POST client wire checks passed. |
| Real Skir compiler and serialization interoperability | 209 vectors passed, including dense/readable JSON, canonical binary, recursion, unknown preservation, and long bytes. |

The runtime fixes address forward struct references during compilation, native
validation of structs, and compiler warnings treated as errors. The RPC Studio
HTML now matches the upstream shell, including its blank line after the doctype.

Two oracle boundaries are explicit:

- Malformed typed JSON must produce HTTP 400 with the same content type and RPC
  error prefix; V8 and Jason keep their own syntax-error diagnostics.
- `skir-client` 1.0.19 corrupts binary encoding when a bytes payload crosses its
  initial 128-byte output buffer. The 257-byte case uses the documented wire
  format, checks the upstream decoder and JSON serializers, and requires exact
  Elixir encoding. Upstream binary re-encoding is excluded only for this case.
  A 117-byte case still checks both binary encoders.

The TypeScript reflection-number anomaly remains documented in
[docs/SKIRRPC_PARITY.md](docs/SKIRRPC_PARITY.md). A live Dart/Phoenix deployment
check and independent security/fuzz review remain outside this test gate.

---

# Historical authoring report — 2026-10-03

## Scope in 0.3.0

This revision keeps the native Elixir serializer/code generator and SkirRPC
implementation from 0.2.0, then audits the RPC behavior directly against the
current official TypeScript, Dart, and Gleam implementations.

The parity work covers strict request parsing, method lookup/error precedence,
duplicate-name behavior, controlled error defaults, response-serialization
errors, Studio/reflection, media types, optional GET client calls, and the client
non-2xx error surface. See `docs/SKIRRPC_PARITY.md` for the detailed matrix and
the intentional handling of the current TypeScript `list.number` anomaly.

0.3.0 also adds `npm run test:rpc-parity`: an executable oracle that feeds the
same raw requests to the official TypeScript `Service` from `skir-client` and to
native `Skir.RPC.Service`, then compares status code, content type, and body.

## Executed in the authoring sandbox

Environment: Node v22.16.0. `elixir`, `mix`, and `erl` are absent.

| Command / check | Observed result |
|---|---|
| `npm run check` | Exit 0. Generator JavaScript syntax checks passed. |
| `node --check` over every JS/MJS file in `scripts/` and `test/` | Exit 0. |
| `npm run generate:fixtures` | Exit 0. Three Elixir files regenerated from resolved-IR fixtures. |
| `npm test -- --test-reporter=spec` | Exit 0. **45 tests passed, 0 failed, 0 skipped.** This includes 12 official-runtime RPC parity source regressions plus 2 executable-oracle source checks. |
| `npm run test:runtime` | Exit 127: `mix: not found`. ExUnit/Plug tests were not executed. |
| `npm run test:rpc-parity` | Exit 1 before the Elixir phase because `skir-client` is not installed locally (`ERR_MODULE_NOT_FOUND`). |
| `timeout 20s apt-get update` | Exit 124. Debian package metadata could not be reached before timeout. |
| `timeout 25s npm install --ignore-scripts --no-audit --no-fund` | Exit 124. Package installation could not complete in the sandbox network environment. |

Raw outputs for these environment/release checks are under `reports/`.

## Dependency-free parity evidence

The Node source-level suite asserts the audited observable SkirRPC surface in the
Elixir source, including:

- exact `list` / `studio` keyword matching without trimming;
- strict signed-decimal compact method numbers;
- HTTP 400 detailed lookup errors and duplicate-name ambiguity;
- method lookup before typed request JSON decoding;
- visible response-serialization failures;
- `text/plain; charset=utf-8` errors;
- TypeScript/Dart Studio shell;
- numeric IDs in reflection;
- optional GET client transport, WHATWG-compatible query escaping, and `HTTP status N[: body]` client errors;
- standard HTTP reason phrases for controlled errors without a custom message;
- boolean-or-predicate unknown-error disclosure matching the TypeScript control surface;
- `text/plain` MIME-token matching using the TypeScript word-boundary rule;
- pre-Jason JSON structure limits and invalid UTF-8 rejection.

These checks are useful against accidental source drift, but they are not a
substitute for compiling or executing the Elixir code.

## Native tests present but not executable here

`runtime/test/rpc_test.exs` covers compact numeric/name routing, readable JSON,
manual JSON calls, malformed requests, lookup precedence, duplicate-name
ambiguity, controlled/default errors, unknown errors, metadata/error callbacks,
Studio, list/type reflection, request limits, invalid UTF-8, client POST/GET wire
behavior, client HTTP/transport/decode errors, and response serialization errors.

`runtime/test/rpc_plug_test.exs` covers POST delegation, metadata extraction, GET
Studio/list, unsupported methods, bounded bodies, and Plug media types.

`example/test/rpc_test.exs` connects generated `add_get_user/2`, `get_user/3`, and
`get_user!/3` helpers through an in-process transport.

`scripts/integration.mjs` invokes the real Skir compiler, compiles generated
Elixir with warnings-as-errors, runs the example suite, and compares JSON/binary
vectors against the official TypeScript runtime.

`scripts/rpc-parity.mjs` is the new raw SkirRPC oracle. It uses the official
TypeScript `Service` and `primitiveSerializer("string")`, invokes the native
Elixir oracle in `scripts/rpc-parity.exs`, and deep-compares the responses. It
normalizes only the documented TypeScript 1.0.19 reflection-number anomaly.

## Verification boundary

The evidence produced in this sandbox proves that the JavaScript generator and
source-level parity gates pass and that the executable cross-runtime gate is
present and fails loudly when its prerequisites are unavailable. It does **not**
prove that the Elixir source compiles, that ExUnit/Plug tests pass, or that the
TypeScript↔Elixir oracle passes at runtime.

Before production deployment, run on the intended Elixir/OTP version:

```sh
npm install
mix local.hex --force
mix local.rebar --force
npm run test:all
```

Then run the application's actual Dart client against the Phoenix endpoint,
exercise authentication/proxies/timeouts, fuzz malformed inputs, load-test the
configured limits, and perform an independent security/code review. Do not
represent this source as production-qualified until those native gates pass.
