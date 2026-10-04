> Historical implementation notes from before the client repository split.
> For current ownership and commands, see README.md and docs/RELEASING.md.

# Native Skir Elixir Implementation Plan

**Goal:** Deliver a native code generator, pure-Elixir runtime, and reproducible tests.
**Architecture:** Pure generator core plus Zod plugin entrypoint; descriptor-driven runtime; separate integration harness.
**Tech stack:** Node >=20, Skir 1.2.22 / skir-internal 0.2.21, Elixir >=1.14, Jason 1.4.
**Spec:** DESIGN.md

## Review focus

Naming collisions and code injection; non-contiguous field numbers; recursive defaults; unknown data crossing wire formats; malicious binary lengths/depth.

## Task 1 — generator
- [x] Write failing Node tests against resolved compiler IR.
- [x] Implement src/naming.js, src/generator.js, src/index.js and declarations.
- [x] Verify core tests, deterministic output, and syntax checks.

## Task 2 — runtime
- [x] Write ExUnit tests and documented wire vectors.
- [x] Implement Skir API, typed codecs, binary framing, errors, limits and unknown representation.
- [x] Run ExUnit when available; explicitly record any unavailable checks.

## Task 3 — integration and delivery
- [x] Include runnable example and actual Skir/TypeScript interoperability harness.
- [x] Add CI, README, compatibility caveats, release checklist and verification report.
- [x] Self-review code, run all executable checks, package source without dependencies/build artifacts.

## Completion boundary

The implementation files, fixtures, harness, CI definition and documentation
exist. Checked boxes for unavailable-tool tasks mean that the limitation was
recorded, not that those tests passed. Native compilation and full interoperability
remain release gates. See ../VERIFICATION.md for executed evidence.

## Review / decisions

Self-review only; no independent reviewer was available. The final generator
review found an unchecked upper bound on removed field numbers. A new Node test
failed before the fix and passed afterwards. Runtime review added proper-list
checks, bounded error rendering, portable timestamp bounds, and enum evolution
cases; the corresponding ExUnit tests have not been executed.

Decisions: deliver a standalone project because no repository was supplied;
separate the npm plugin from the Mix runtime; use finite hard-recursive default
sentinels; default decode to discard unknowns and require explicit trust to keep
them; reject cross-format preservation rather than silently lose unknown data;
leave RPC transport and GitHub-path imports out of this version. These costs and
limitations are documented in the README rather than presented as solved features.
