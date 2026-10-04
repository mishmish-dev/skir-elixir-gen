# Native Skir Elixir runtime

Local Mix dependency for source emitted by `skir-elixir-gen`:

```elixir
{:skir, path: "path/to/skir-elixir/runtime"}
```

This source package is **not published on Hex**. It targets Elixir 1.14+ and uses
Jason for JSON; binary serialization and SkirRPC run as ordinary BEAM code. No
Gleam, NIF, port, or runtime JavaScript dependency is needed.

Public entry points are:

- `Skir` — dense/readable JSON and framed Skir binary serialization;
- `Skir.RPC.Service` — transport-neutral SkirRPC dispatcher;
- `Skir.RPC.ServiceClient` — typed RPC client used by generated helpers;
- `Skir.RPC.Plug` — optional Phoenix/Plug adapter with no production Plug dependency;
- `Skir.RPC.TypeDescriptor` — Studio/list reflection descriptors;
- `Skir.RPC.HTTPClient` — behaviour for custom HTTP transports.

The built-in client transport uses OTP `:httpc`. Plug is only a test dependency of
this runtime; applications mounting `Skir.RPC.Plug` provide Plug/Phoenix themselves.

See the parent `README.md` and `docs/SKIRRPC.md` for type mappings, APIs, limits,
unknown-field policy, service/client examples, and compatibility boundaries.
Modules under `Skir.Codec`, `Skir.Primitive`, `Skir.Binary` and `Skir.Limits` are
internal. `Skir.Unknown` values are opaque metadata even though they have a struct
shape.

```sh
mix deps.get
mix test
```

The parent `npm run test:all` gate compiles and tests the native runtime on
Elixir 1.20.4 / OTP 27, 28 and 29, with a 90% minimum line coverage check.
It also installs the actual Hex archive in a fresh generated-code application.
See the parent `VERIFICATION.md` for interoperability evidence and limitations.
