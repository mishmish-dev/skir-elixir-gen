# Native SkirRPC for Elixir

This package implements SkirRPC directly on the BEAM. Generated Elixir code and
runtime request handling do not call Gleam or JavaScript.

The implementation follows the current SkirRPC model: schema methods carry stable
numeric IDs, an application registers implementations on a transport-neutral
service, HTTP POST carries the compact RPC wire form, GET/POST may expose Studio
and method reflection, and a generated client serializes through the same schema
types.

## Generated method API

Given:

```skir
// Load one user.
method GetUser(int64): User = 12345;
```

the Elixir generator emits functions equivalent to:

```elixir
@spec get_user_method() :: Skir.Method.t()
def get_user_method()

@type get_user_handler ::
  (integer(), term() ->
    {:ok, User.t() | :skir_default} |
    {:error, Skir.RPC.ServiceError.t() | Skir.RPC.UnknownError.t()})

@spec add_get_user(Skir.RPC.Service.t(), get_user_handler()) :: Skir.RPC.Service.t()
def add_get_user(service, handler)

@spec get_user(Skir.RPC.ServiceClient.t(), integer(), keyword()) ::
  {:ok, User.t() | :skir_default} | {:error, Skir.RPC.RpcError.t()}
def get_user(client, request, opts \\ [])

@spec get_user!(Skir.RPC.ServiceClient.t(), integer(), keyword()) ::
  User.t() | :skir_default
def get_user!(client, request, opts \\ [])
```

`methods/0` returns every method declared by the source `.skir` module.

## Service

```elixir
alias MyApp.Protocol.AccountsSkir
alias MyApp.Protocol.AccountsSkir.User
alias Skir.RPC.Service

service =
  Service.new()
  |> AccountsSkir.add_get_user(fn id, metadata ->
    case MyApp.Accounts.fetch_user(id, metadata) do
      {:ok, user} -> {:ok, user}
      :missing -> {:error, Skir.RPC.error(404, "user not found")}
      {:error, reason} -> {:error, Skir.RPC.unknown_error(inspect(reason))}
    end
  end)
```

A handler receives the decoded request and an application-defined metadata value.
It returns `{:ok, response}`, a controlled `ServiceError`, or an `UnknownError`.
Controlled errors support the HTTP status codes accepted by SkirRPC and return
their text to the client. Unknown errors are HTTP 500 and hide their details by
default.

Service options:

```elixir
Service.new(
  keep_unrecognized_values: false,
  can_send_unknown_error_message: fn error_info -> false end,
  error_logger: fn error_info -> Logger.error(inspect(error_info)) end,
  studio_app_js_url: "https://cdn.jsdelivr.net/npm/skir-studio/dist/skir-studio-standalone.js",
  max_request_bytes: 4_194_304
)
```

`keep_unrecognized_values: true` is intended only for trusted forwarding
boundaries. It can preserve future fields through an older service.

`Service.handle_request/3` is independent of any web framework:

```elixir
raw = Service.handle_request(service, request_body, request_metadata)
raw.status_code
raw.content_type
raw.data
```

It supports:

- compact RPC bodies: `GetUser:12345::<dense-json>`;
- `readable` RPC bodies: `GetUser:12345:readable:<readable-json>`;
- manual JSON calls: `{"method":"GetUser","request":42}`;
- `list` reflection for RPC Studio and tooling;
- empty or `studio` payloads for RPC Studio HTML.

When the compact request contains a method number, dispatch is by that number
even if the value is `0`; name lookup is used only when the numeric slot is empty.
This matches the current TypeScript and Dart SkirRPC implementations and makes a
renamed method safe when callers continue sending its stable numeric ID.

## Phoenix and Plug

The runtime has no production dependency on Plug. If the host application uses
Phoenix/Plug, mount `Skir.RPC.Plug`:

```elixir
# router.ex
forward "/rpc", Skir.RPC.Plug,
  service: &MyApp.RPC.service/0,
  metadata: &MyApp.RPC.metadata/1
```

A service can also be supplied directly or as an MFA tuple.

A metadata function can use the full `Plug.Conn`:

```elixir
def metadata(conn) do
  %{
    authorization: Plug.Conn.get_req_header(conn, "authorization"),
    remote_ip: conn.remote_ip
  }
end
```

Without a custom function the adapter supplies request headers, HTTP method,
request path, and `remote_ip`.

The adapter accepts GET and POST. POST bodies are bounded before accumulation;
GET passes the percent-decoded query string to `Service.handle_request/3`.

## Client

```elixir
client =
  Skir.RPC.ServiceClient.new!("https://api.example.com/rpc",
    headers: [{"authorization", "Bearer ..."}],
    transport_opts: [timeout: 15_000, connect_timeout: 5_000]
  )

{:ok, user} = AccountsSkir.get_user(client, 42)
user = AccountsSkir.get_user!(client, 42)
```

The built-in transport uses OTP `:httpc` with peer verification for HTTPS. For
Req, Finch, Tesla, Mint, or application-specific instrumentation, implement
`Skir.RPC.HTTPClient.request/5` and pass the module as `transport:`. An arity-5
function is also accepted, which makes client tests inexpensive.

The TypeScript client also supports GET RPCs. The Elixir client exposes the same
optional transport form with `http_method: :get`; POST remains the default:

```elixir
AccountsSkir.get_user(client, 42, http_method: :get)
```

Per-call headers override defaults case-insensitively:

```elixir
AccountsSkir.get_user(client, 42,
  headers: [{"authorization", "Bearer replacement"}],
  timeout: 5_000
)
```

Client RPC errors are `%Skir.RPC.RpcError{status_code: code, message: message}`.
Status `0` means the HTTP request failed or a successful HTTP response could not
be decoded. For non-2xx HTTP responses, the client exposes the response body only
when its content type is `text/plain`, matching SkirRPC's error-surface rule.

## Studio and reflection

Open `/rpc?studio` in a browser when using the Plug adapter. The returned Studio
page loads the configured Skir Studio standalone script.

`/rpc?list` returns each method's name, numeric ID, documentation, request type,
and response type. Type descriptors include nested records, enum payloads,
removed field numbers, documentation, and keyed-array extractors. The reflection
format is generated from the same schema metadata used by serialization.

## Resource limits and errors

The service bounds the raw request body before parsing and runs JSON through
Skir's nesting/size scanner before passing it to Jason. Decoded request values
then go through the normal Skir collection/node/type limits. Handler exceptions, throws, and invalid handler returns become unknown HTTP 500
errors and are hidden unless the service explicitly permits disclosure. Response
serialization failures are returned as visible server errors, matching the
current TypeScript and Dart implementations.

`error_logger` receives `%Skir.RPC.ErrorInfo{}` for controlled and unknown handler
failures. Logger and disclosure callbacks are isolated so a callback failure does
not replace the RPC result.

## Protocol scope

SkirRPC is unary request/response RPC over HTTP. Streaming, bidirectional
sessions, and a protocol-level cancellation frame are not part of this wire
protocol. In Elixir, concurrency and cancellation are supplied by the web server
request process or by whatever HTTP transport is used by the caller. Transport
timeouts are forwarded through `ServiceClient`.

## Verification

The repository includes:

- generator tests for method metadata and typed client/server helpers;
- ExUnit service tests for dense/readable calls, errors, metadata, Studio,
  reflection, limits, and client behavior;
- Plug adapter tests;
- an in-process generated client/server round trip in the example project;
- the existing real-Skir-compiler and upstream TypeScript serialization harness.

In the authoring sandbox only the Node/source-level tests can execute because
Elixir/Erlang are unavailable. See `SKIRRPC_PARITY.md` for the official-runtime behavior matrix and
`VERIFICATION.md` for the exact evidence and remaining release gate.
