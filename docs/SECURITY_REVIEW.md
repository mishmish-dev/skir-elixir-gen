# Independent agent security review

Reviewed 2026-10-04. This is an independent agent source review with targeted
executable probes, not third-party security certification or a penetration test.
It does not establish that production deployment is safe.

## Scope and baseline

Reviewed `src/{index,naming,generator}.js` and every runtime source file under
`example/deps/skir_elixir_client/lib`, including binary/JSON codecs, limits,
unknown-field handling, RPC dispatch, Plug, HTTP transport and reflection.
The example's dependency and lockfile both pin Hex **0.2.0**; the loaded runtime
also reported `0.2.0`. Generator baseline: commit
`078b5103cb50169e28ff7b70acfe4a149d42e738` plus the current workspace.

The review distinguishes untrusted wire input from application-owned schemas,
generator configuration, type descriptors, callbacks and transport URLs. No
schema-driven path traversal or source injection was found for valid compiler
output. Runtime wire names are matched to existing atoms; they do not create
atoms. Binary parsing bounds bytes, depth, collection length and aggregate nodes.
JSON depth is checked before tree allocation; its collection/node checks happen
after the JSON library allocates the parsed tree, so these limits do not cap peak
parser allocation independently of `max_bytes`.

Probes ran on Elixir 1.19.6 / OTP 28.5.0.7 using the existing compiled example
dependencies. Malformed percent escapes through Plug returned 400. Truncated
binary, invalid UTF-8, trailing binary data and oversized declared collections
returned structured `Skir.Error` results. These probes supplement source review;
they are not exhaustive fuzzing.

## Findings

### S1 — High: oversized RPC method numbers cause expensive integer rendering

**Open in runtime 0.2.0.** Runtime `lib/skir/rpc/service.ex:184–186` converts
arbitrarily long decimal method numbers, and `:214` interpolates the resulting
big integer into an error. The JSON envelope route also accepts any integer at
`:161`, reaching the same rendering operation. An unauthenticated request can
consume seconds of CPU while remaining well below the default 4 MiB request
limit. Concurrent requests amplify the cost. No handler is required.

Reproduce in the example, loading its built dependency beams:

```elixir
service = Skir.RPC.Service.new()
for digits <- [100_000, 200_000, 400_000] do
  body = "Unknown:" <> String.duplicate("9", digits) <> "::0"
  {micros, response} = :timer.tc(fn ->
    Skir.RPC.Service.handle_request(service, body)
  end)
  IO.inspect({digits, micros, response.status_code, byte_size(response.data)})
end
```

Observed approximately **174 ms, 688 ms and 2,743 ms**, respectively, returning
400 with the full giant number echoed in the response. JSON bodies shaped as
`{"method":<the same digits>,"request":0}` showed the same scaling.

Bound decimal method-number length before conversion, range-check both request
routes against the registered uint32 method-ID range, and avoid rendering invalid
big integers into errors. This fix belongs in the separate runtime package;
generator-only changes cannot repair the pinned release.

### S2 — Medium: default RPC transport has no response-body allocation limit

**Open in runtime 0.2.0.** Runtime `lib/skir/rpc/httpc.ex:51–57` obtains a complete
response from synchronous `:httpc.request`, then converts its body. Codec
`max_bytes` checks occur only afterward for successful responses. For non-2xx
responses, `lib/skir/rpc/service_client.ex:169–171` copies an unrestricted
`text/plain` body into the error message. A compromised or untrusted configured
server can therefore make the client allocate a response substantially larger
than the advertised codec limit. The timeout bounds duration, not response size.

A transport probe returning an 8,388,608-byte `text/plain` body with status 500
produced an **8,388,625-byte error message** from `ServiceClient.invoke/4`, without
a size error. This confirms the client behavior; the absence of a default HTTP
transport allocation limit follows from source review. A live oversized HTTP
response was not exercised during this review.

Provide an explicit response-size limit enforced while receiving HTTP data,
including chunked bodies and error responses; truncate error-body disclosure.
Until a runtime release includes that, deployments need a custom bounded
transport or trusted server plus independently enforced response limits.

### S3 — Low: malformed enum compiler IR can inject executable source

**Fixed and independently reprobed in the current workspace.** The generator
baseline checked slot metadata only for structs at `src/generator.js:208–212`,
but `:258` interpolated the same metadata into enum source.
Direct callers supplying hostile resolved compiler IR can inject an Elixir
expression into `schema/0`. This requires control of compiler IR; no valid Skir
schema exploit was identified, and a compromised compiler already has build-time
authority.

```javascript
import { generateCode } from './src/generator.js';
import { input, record } from './fixtures/schema.mjs';
const loc = record('injected.skir', ['E'], 'enum', []);
loc.record.numSlotsInclRemovedNumbers = 'raise("injected")';
console.log(generateCode(input([loc])).files[0].code);
// Before validation: slots: raise("injected"), removed: []
```

The current generator requires enum slot metadata to equal the compiler's enum
contract value `0` before interpolating it. Rerunning the hostile IR above now
throws `Invalid slot count for injected.skir:E`, preventing source emission.

## Deployment trust assumptions

RPC registration and Plug mounting do not implement application authentication
or authorization. Studio and `list` share the service route; hosting applications
must apply their intended route access policy. Studio's default script comes
from an unversioned external CDN URL and runs in the service origin. Treat that
script source as trusted code, pin/self-host it when deployment policy requires,
and apply HTTP body, URL, timeout and concurrency limits outside the codecs.
Unknown request preservation remains opt-in and should be limited to trusted
forwarding boundaries.

## Locked HTTP test dependency advisories

The example locks `cowlib` 2.20.0 through the test-only `plug_cowboy` dependency.
It falls within the published affected ranges for
[CVE-2026-43966](https://cna.erlef.org/cves/CVE-2026-43966.html), a structured-header
encoder permitting response splitting, and
[CVE-2026-43969](https://cna.erlef.org/cves/CVE-2026-43969.html), a client cookie
encoder permitting cookie/header injection. These advisories require hostile
values to reach their respective encoder functions; they are not demonstrated
exploits of the Skir adapter.

Source inspection found no calls to those encoders in this generator, its example
application, or its tests. Skir's HTTP client uses OTP `:httpc`. The locked server
is Cowboy 2.19.0, which includes the outgoing CR/LF header rejection mitigation
described by the 43966 advisory for Cowboy 2.16.0 onward. Its source defaults
`invalid_response_headers` to `error_terminate`; retain that protection in
deployments. Do not treat this configuration-specific assessment as a general
clearance of cowlib. Recheck the advisories and adopt an upstream fixed release
when available; the review did not modify the reproducible lockfile.

## Remaining limits

This review did not inspect Hex/npm supply-chain provenance, all dependency
vulnerabilities, deployment configuration, side channels, cross-origin browser
behavior, TLS integration, live response streaming or all adversarial inputs.
No finding above should be described as fixed solely because a regression test
or fuzz harness was added. The runtime findings remain relevant to the exact
0.2.0 dependency until a fixed runtime is released and adopted.
