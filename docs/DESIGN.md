> Historical implementation notes from before the client repository split.
> For current ownership and commands, see README.md and docs/RELEASING.md.

# Native Skir Elixir design

Build a standalone Skir compiler plugin, not a Gleam wrapper. The generator consumes the upstream resolved Module/RecordLocation/ResolvedType contract and returns Elixir source files. Runtime code is an independent Mix project. No repository or application was supplied, so no existing project is modified.

## Public API

One namespace per source file (user.skir -> Skir.Generated.UserSkir) and a native Elixir module per record (UserSkir.User). Structs use defstruct, enums use atoms and tagged tuples, optionals use nil, arrays use lists, bytes use binaries, timestamps use integer Unix milliseconds. Include typespecs, constructors, defaults, schema metadata, constants, and method metadata. RPC transport/framework integration is not part of this version.

Decoding discards future fields by default; explicit trusted-source preservation retains them in __skir_unknown_fields__. Encoding preserves already-retained data unless discard is explicit. Unknown enum values have an explicit tagged representation. Do not create atoms from untrusted wire data. Non-finite floats use :nan, :infinity, :neg_infinity. Hard recursive defaults terminate using :skir_default.

Support dense JSON, readable JSON, and the documented binary value encoding. Dense and binary encoders omit trailing default fields, but never infer field numbers from list order. Removed slots are zero. Cross-format serialization of preserved unknown data must error rather than guess its type. Explicit unknown_fields: :discard permits dropping it.

The runtime centralizes validation, codecs and resource limits. Generated code has no compile-time dependency on another generated struct definition; embedded default values use literal maps with __struct__ keys. Errors carry a path without echoing entire input payloads.

## Validation

Dependency-free Node tests exercise generator behavior using the actual shape of the upstream resolved IR. ExUnit tests exercise runtime and generated output. A separate integration command invokes the real Skir compiler and TypeScript reference serializer. Do not conflate these three validation layers.

## Environment

Node 22 is present. Erlang/Elixir are absent. DNS/package downloads fail in this sandbox. Consequently, runtime compilation and official compiler/reference interoperability cannot be claimed unless the environment changes. Include commands and CI to run those checks on a normal development machine.
