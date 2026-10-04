# Separate generator and client

Agreed ownership: generator owns JavaScript/IR tests, example/generated API
and golden integration tests, serialization oracle, npm archive and release.
Client owns the Elixir runtime, its 44 unit tests, primitive RPC oracle and
documentation, native Hex archive checks and release. No copied tests and no
cross-repository test-directory inclusion. Generator integration depends on a
pinned, separately checked-out private client repo through a read-only key.
Coverage reports count each repository's own handwritten source. The existing
90% example threshold stays; the standalone client unit suite runs separately.
No registry publication is authorized. Preserve all existing test cases.
