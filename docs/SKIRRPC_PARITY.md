# SkirRPC official-runtime parity audit

Audit date: **2026-10-03**. This document records the protocol behavior used to
shape `skir-elixir-gen` **0.3.0**.

## Reference implementations

The audit compared the current official SkirRPC implementations rather than only
the prose documentation:

- TypeScript: `skir-client` 1.0.19, `src/skir-client.ts`
- Dart: `skir_client` 1.0.12, `lib/src/skir_client.dart`
- Gleam: `skir_client` 1.0.5, service/client modules under `src/skir_client`

TypeScript and Dart agree on the strict request/error surface in most places.
Where those two agree and Gleam differs, this Elixir implementation follows the
TypeScript/Dart behavior. This is a compatibility choice, not a claim that the
Gleam implementation is invalid.

One narrow TypeScript/Dart difference is retained deliberately: TypeScript accepts
any JavaScript number in the manual JSON envelope's `method` field, whereas Dart
requires an integer method ID. Elixir follows Dart here because Skir method IDs are
integers and the compact wire syntax is integer-only.

## Behavior matrix

| Behavior | TypeScript | Dart | Gleam | Elixir 0.3.0 |
|---|---|---|---|---|
| `list`, `studio`, and empty-body keywords | Exact; no trim | Exact; no trim | Trims body | **Exact** |
| Compact method-number syntax | Strict signed decimal | Strict signed decimal | More permissive | **Strict signed decimal** |
| Non-empty method number | Dispatch by number | Dispatch by number | Dispatch by number when parsed | **Dispatch by number** |
| Empty method-number slot | Lookup by name | Lookup by name | Lookup by name | **Lookup by name** |
| Unknown method | HTTP 400, detailed | HTTP 400, detailed | HTTP 404, generic | **HTTP 400, detailed** |
| Duplicate method numbers | Registration error | Registration error | Registration error | **Registration error** |
| Duplicate method names | Allowed; name-only request becomes ambiguous | Same | Name map overwrites | **Allowed; ambiguous name-only request is HTTP 400** |
| Method lookup vs typed request decode | Lookup first | Lookup first | Different implementation path | **Lookup first** |
| JSON-envelope numeric `method` | Any JS number | Integer | Integer-oriented decoder | **Integer (follows Dart)** |
| `text/plain` error media type | Includes `charset=utf-8` | Includes `charset=utf-8` | Plain `text/plain` | **Includes charset** |
| Controlled error with no custom message | Standard HTTP reason phrase | Standard HTTP reason phrase | Runtime-specific API | **Standard HTTP reason phrase** |
| Unknown handler errors | Hidden by default | Hidden by default | Hidden/default policy | **Hidden by default** |
| Unknown-error disclosure control | Boolean or predicate | Boolean or callback policy | Runtime-specific API | **Boolean or predicate** |
| Response serialization failure | Visible HTTP 500 message | Visible HTTP 500 message | Different error path | **Visible HTTP 500 message** |
| Studio title/body shell | `RPC Studio` | `RPC Studio` | `Skir Studio` | **TypeScript/Dart form** |
| `list` method `number` | **Current 1.0.19 source anomaly: emits method name** | Numeric ID | Numeric ID | **Numeric ID** |
| Reflection type envelope | `type` + `records` | Compatible | Compatible | **Compatible** |
| Client POST | Yes | Yes | Yes | **Yes** |
| Client GET | Yes, optional; WHATWG `URL.search` encoding | No public equivalent in audited client | No public equivalent in audited client | **Yes; matches TypeScript query encoding** |
| Non-2xx client message | `HTTP status N[: text]` | Same | Exposes text differently | **TypeScript/Dart form** |
| Successful response preserves unknown values | Yes | Yes | Yes | **Yes** |
| Default server error logger | Console | stderr-style logging | No-op | **No-op (documented policy divergence)** |

### TypeScript `list` anomaly

In `skir-client` 1.0.19 the TypeScript `list` implementation currently constructs
an entry equivalent to:

```text
method: methodImpl.method.name
number: methodImpl.method.name
```

The `number` field therefore contains a string method name. Dart and Gleam emit
the numeric method ID, which is also what Studio/reflection consumers expect.
Elixir deliberately emits the numeric ID. The executable parity oracle normalizes
only this known TypeScript anomaly so it will continue working if upstream fixes
the line.

## Executable parity oracle

`npm run test:rpc-parity` instantiates the official TypeScript `Service` from
`skir-client` and a native Elixir `Skir.RPC.Service` with equivalent primitive
methods. It feeds both services the same raw requests and compares status code,
content type, and response body. Cases include:

- numeric and name dispatch;
- JSON-envelope dispatch and leading whitespace;
- strict invalid method numbers;
- unknown-method precedence over malformed typed request JSON;
- malformed request JSON for a known method;
- standard controlled-error messages;
- exact `list` / `studio` keyword behavior;
- duplicate-name ambiguity and numeric disambiguation.

The `list` response is compared semantically after normalizing the one documented
TypeScript `number` anomaly. The malformed request JSON case checks the HTTP
status, content type, and RPC error prefix, allowing V8 and Jason to use their
own syntax-error diagnostics. All other cases compare the transport-neutral raw
response directly.

The oracle is intentionally a hard gate: missing Node dependencies, `mix`, or
Elixir fails the command rather than silently skipping cross-runtime comparison.

## Runtime verification

On 2026-10-04 the oracle passed all 16 raw server cases and GET/POST client wire
checks on Elixir 1.20.4 / OTP 29. CI runs the complete gate on pinned OTP 27, 28,
and 29 releases. To reproduce with the normal toolchains:

```sh
npm install
mix local.hex --force
mix local.rebar --force
npm run test:all
```

A live Dart client ↔ Phoenix endpoint test remains a separate deployment gate,
especially for middleware, authentication, proxy behavior, and application timeouts.
