defmodule Skir.RPCTest.User do
  defstruct id: 0, name: "", __skir_unknown_fields__: %{}
  def default, do: %__MODULE__{}
  def schema do
    %{
      kind: :struct,
      module: __MODULE__,
      key: "rpc_test.skir:User",
      doc: "A user.",
      slots: 3,
      removed: [1],
      fields: [
        %{name: :id, json_name: "id", number: 0, doc: "Identifier.", type: :int64, key_path: []},
        %{name: :name, json_name: "name", number: 2, doc: "", type: :string, key_path: []}
      ]
    }
  end
end

defmodule Skir.RPCTest.Event do
  def default, do: :unknown
  def schema do
    %{
      kind: :enum,
      module: __MODULE__,
      key: "rpc_test.skir:Event",
      doc: "",
      slots: 0,
      removed: [3],
      fields: [
        %{name: :connected, json_name: "connected", number: 1, doc: "", type: nil, key_path: []},
        %{name: :user, json_name: "user", number: 2, doc: "", type: {:record, Skir.RPCTest.User}, key_path: []}
      ]
    }
  end
end

defmodule Skir.RPCTest do
  use ExUnit.Case, async: true

  alias Skir.RPC.{RpcError, Service, ServiceClient, TypeDescriptor}
  alias Skir.RPCTest.User

  defp method do
    %Skir.Method{name: "GetUser", number: 12_345, doc: "Load one user.", request: :int64, response: {:record, User}}
  end

  defp service(handler \\ nil) do
    handler = handler || fn id, _metadata -> {:ok, %User{id: id, name: "Alice"}} end
    Service.new() |> Service.add_method(method(), handler)
  end

  test "colon requests route by stable method number and return dense JSON" do
    raw = Service.handle_request(service(), "RenamedClientMethod:12345::42", %{token: "x"})
    assert raw.status_code == 200
    assert raw.content_type == "application/json"
    assert Jason.decode!(raw.data) == [42, 0, "Alice"]
  end

  test "colon requests use method name only when the number field is empty" do
    raw = Service.handle_request(service(), "GetUser:::7")
    assert raw.status_code == 200
    assert Jason.decode!(raw.data) == [7, 0, "Alice"]

    assert %{status_code: 400, data: "bad request: method not found: GetUser; number: 0"} =
             Service.handle_request(service(), "GetUser:0::7")

    assert %{status_code: 400, data: "bad request: can't parse method number"} =
             Service.handle_request(service(), "GetUser:not-a-number::7")
  end

  test "JSON request form uses readable JSON responses" do
    raw = Service.handle_request(service(), Jason.encode!(%{"method" => "GetUser", "request" => 42}))
    assert raw.status_code == 200
    assert Jason.decode!(raw.data) == %{"id" => 42, "name" => "Alice"}
  end

  test "malformed and unknown requests have TypeScript/Dart-compatible statuses" do
    assert %{status_code: 400, data: "bad request: invalid request format"} =
             Service.handle_request(service(), "broken")

    assert %{status_code: 400, data: data} =
             Service.handle_request(service(), "GetUser:12345::{")
    assert data =~ "bad request: can't parse JSON:"

    assert %{status_code: 400, data: "bad request: missing 'request' field in JSON"} =
             Service.handle_request(service(), ~s({"method":"GetUser"}))

    assert %{status_code: 400, data: "bad request: 'method' field must be a string or an integer"} =
             Service.handle_request(service(), ~s({"method":true,"request":1}))

    assert %{status_code: 400, data: "bad request: method not found: Missing; number: 99999"} =
             Service.handle_request(service(), "Missing:99999::0")
  end

  test "method lookup precedes request JSON parsing" do
    assert %{status_code: 400, data: "bad request: method not found: Missing; number: 99999"} =
             Service.handle_request(service(), "Missing:99999::{")
  end

  test "method names may collide and ambiguous name-only calls are rejected" do
    other = %Skir.Method{name: "GetUser", number: 12_346, doc: "", request: :int64, response: {:record, User}}

    svc =
      service()
      |> Service.add_method(other, fn id, _ -> {:ok, %User{id: id, name: "Other"}} end)

    assert %{status_code: 400, data: "bad request: method name 'GetUser' is ambiguous; use method number instead"} =
             Service.handle_request(svc, "GetUser:::1")

    assert %{status_code: 200, data: data} = Service.handle_request(svc, "GetUser:12346::1")
    assert Jason.decode!(data) == [1, 0, "Other"]
  end

  test "endpoint keywords are exact and are not whitespace-trimmed" do
    assert %{status_code: 400, data: "bad request: invalid JSON"} =
             Service.handle_request(service(), " list ")

    assert %{status_code: 400, data: "bad request: invalid request format"} =
             Service.handle_request(service(), "list ")
  end

  test "controlled service errors preserve status and use standard reason phrases by default" do
    svc = service(fn _, _ -> {:error, Skir.RPC.error(409, "already exists")} end)
    assert %{status_code: 409, content_type: "text/plain; charset=utf-8", data: "already exists"} =
             Service.handle_request(svc, "GetUser:12345::1")

    svc = service(fn _, _ -> {:error, Skir.RPC.error(404)} end)
    assert %{status_code: 404, data: "Not Found"} = Service.handle_request(svc, "GetUser:12345::1")
  end

  test "explicit unknown handler errors are hidden by default and selectively exposable" do
    svc = service(fn _, _ -> {:error, Skir.RPC.unknown_error("database unavailable")} end)
    assert %{status_code: 500, data: "server error"} = Service.handle_request(svc, "GetUser:12345::1")

    svc = Service.set_can_send_unknown_error_message(svc, fn _ -> true end)
    assert %{status_code: 500, data: "server error: database unavailable"} =
             Service.handle_request(svc, "GetUser:12345::1")
  end

  test "unknown error disclosure accepts booleans or a predicate" do
    svc = service(fn _, _ -> {:error, Skir.RPC.unknown_error("database unavailable")} end)

    assert %{status_code: 500, data: "server error: database unavailable"} =
             svc
             |> Service.set_can_send_unknown_error_message(true)
             |> Service.handle_request("GetUser:12345::1")

    assert %{status_code: 500, data: "server error"} =
             svc
             |> Service.set_can_send_unknown_error_message(false)
             |> Service.handle_request("GetUser:12345::1")

    assert %{status_code: 500, data: "server error: database unavailable"} =
             svc
             |> Service.set_can_send_unknown_error_message(fn info -> info.method_name == "GetUser" end)
             |> Service.handle_request("GetUser:12345::1")
  end

  test "unknown exceptions are hidden by default and can be selectively exposed" do
    svc = service(fn _, _ -> raise "secret database failure" end)
    assert %{status_code: 500, data: "server error"} = Service.handle_request(svc, "GetUser:12345::1")

    svc = Service.set_can_send_unknown_error_message(svc, fn info -> info.method_name == "GetUser" end)
    assert %{status_code: 500, data: "server error: secret database failure"} =
             Service.handle_request(svc, "GetUser:12345::1")
  end

  test "error logger receives controlled and unknown errors" do
    parent = self()
    logger = fn info -> send(parent, {:logged, info.kind, info.method_name}) end

    svc =
      Service.new(error_logger: logger)
      |> Service.add_method(method(), fn _, _ -> {:error, Skir.RPC.error(404, "gone")} end)

    Service.handle_request(svc, "GetUser:12345::1")
    assert_receive {:logged, :controlled, "GetUser"}
  end

  test "request metadata reaches handlers" do
    parent = self()
    svc = service(fn id, meta -> send(parent, {:meta, meta}); {:ok, %User{id: id}} end)
    Service.handle_request(svc, "GetUser:12345::3", %{authorization: "Bearer t"})
    assert_receive {:meta, %{authorization: "Bearer t"}}
  end

  test "list endpoint exposes method docs and compatible type descriptors" do
    raw = Service.handle_request(service(), "list")
    assert raw.status_code == 200
    body = Jason.decode!(raw.data)
    [entry] = body["methods"]
    assert entry["method"] == "GetUser"
    assert entry["number"] == 12_345
    assert entry["doc"] == "Load one user."
    assert entry["request"]["type"] == %{"kind" => "primitive", "value" => "int64"}
    assert entry["response"]["type"] == %{"kind" => "record", "value" => "rpc_test.skir:User"}
    [record] = entry["response"]["records"]
    assert record["kind"] == "struct"
    assert record["removed_numbers"] == [1]
  end

  test "type descriptors include enum wrappers and keyed-array extractor metadata" do
    descriptor = TypeDescriptor.to_map({:array, {:record, Skir.RPCTest.Event}, "user.id"})
    assert descriptor["type"]["value"]["key_extractor"] == "user.id"
    enum = Enum.find(descriptor["records"], &(&1["id"] == "rpc_test.skir:Event"))
    wrapper = Enum.find(enum["variants"], &(&1["name"] == "user"))
    assert wrapper["type"] == %{"kind" => "record", "value" => "rpc_test.skir:User"}
  end

  test "empty and studio endpoints return Skir Studio HTML" do
    for payload <- ["", "studio"] do
      raw = Service.handle_request(service(), payload)
      assert raw.status_code == 200
      assert raw.content_type == "text/html; charset=utf-8"
      assert String.starts_with?(raw.data, "<!DOCTYPE html>\n\n<html>\n")
      assert raw.data =~ "<skir-studio-app>"
      assert raw.data =~ "skir-studio-standalone.js"
    end
  end

  test "JSON nesting is bounded before Jason allocates the request tree" do
    nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
    assert %{status_code: 400, data: data} =
             Service.handle_request(service(), "GetUser:12345::" <> nested)
    assert data =~ "bad request: can't parse JSON:"
  end

  test "non UTF-8 request bodies are rejected without invoking String parsing" do
    assert %{status_code: 400, data: "invalid request body"} =
             Service.handle_request(service(), <<0xFF, 0xFE>>)
  end

  test "request size is bounded before JSON parsing" do
    svc = Service.new(max_request_bytes: 5)
    assert %{status_code: 413} = Service.handle_request(svc, "123456")
  end

  test "client emits the official dense colon body and decodes a response" do
    parent = self()
    transport = fn :post, url, headers, body, _opts ->
      send(parent, {:request, url, headers, body})
      {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: ~s([42,0,"Alice"])}}
    end

    client = ServiceClient.new!("https://example.test/rpc", transport: transport, headers: [{"authorization", "Bearer token"}])
    assert {:ok, %User{id: 42, name: "Alice"}} = ServiceClient.invoke(client, method(), 42)
    assert_receive {:request, "https://example.test/rpc", headers, "GetUser:12345::42"}
    assert {"authorization", "Bearer token"} in headers
    assert Enum.any?(headers, fn {k, v} -> String.downcase(k) == "content-type" and v == "text/plain; charset=utf-8" end)
  end

  test "client uses response text only for text/plain RPC errors" do
    text_transport = fn _, _, _, _, _ -> {:ok, %{status: 404, headers: [{"Content-Type", "text/plain; charset=utf-8"}], body: "missing"}} end
    json_transport = fn _, _, _, _, _ -> {:ok, %{status: 500, headers: [{"Content-Type", "application/json"}], body: ~s({"secret":true})}} end

    c1 = ServiceClient.new!("https://example.test/rpc", transport: text_transport)
    assert {:error, %RpcError{status_code: 404, message: "HTTP status 404: missing"}} = ServiceClient.invoke(c1, method(), 1)

    c2 = ServiceClient.new!("https://example.test/rpc", transport: json_transport)
    assert {:error, %RpcError{status_code: 500, message: "HTTP status 500"}} = ServiceClient.invoke(c2, method(), 1)
  end

  test "client maps network and response-decoding failures to status zero" do
    network = fn _, _, _, _, _ -> {:error, :econnrefused} end
    client = ServiceClient.new!("https://example.test/rpc", transport: network)
    assert {:error, %RpcError{status_code: 0, message: message}} = ServiceClient.invoke(client, method(), 1)
    assert message =~ "Request failed:"

    invalid = fn _, _, _, _, _ -> {:ok, %{status: 200, headers: [], body: "not-json"}} end
    client = ServiceClient.new!("https://example.test/rpc", transport: invalid)
    assert {:error, %RpcError{status_code: 0, message: message}} = ServiceClient.invoke(client, method(), 1)
    assert message =~ "failed to decode response"
  end

  test "client validates service URL and supports overriding default headers per call" do
    assert {:error, "service URL must not contain a query string"} = ServiceClient.new("https://example.test/rpc?x=1")
    assert {:error, _} = ServiceClient.new("not a url")

    parent = self()
    transport = fn _, _, headers, _, _ -> send(parent, {:headers, headers}); {:ok, %{status: 200, headers: [], body: ~s([1])}} end
    client = ServiceClient.new!("http://example.test/rpc", transport: transport, headers: %{"x-mode" => "original"}) |> ServiceClient.with_default_header("X-Mode", "default")
    _ = ServiceClient.invoke(client, %Skir.Method{name: "N", number: 1, doc: "", request: :int32, response: {:array, :int32}}, 1, headers: [{"X-Mode", "call"}])
    assert_receive {:headers, headers}
    assert Enum.count(headers, fn {k, _} -> String.downcase(k) == "x-mode" end) == 1
    assert Enum.any?(headers, fn {k, v} -> String.downcase(k) == "x-mode" and v == "call" end)
  end

  test "response serialization failures are always visible like TypeScript and Dart" do
    svc = service(fn _, _ -> {:ok, %User{id: "not-an-int"}} end)
    assert %{status_code: 500, content_type: "text/plain; charset=utf-8", data: data} =
             Service.handle_request(svc, "GetUser:12345::1")
    assert data =~ "server error: can't serialize response to JSON:"
  end


  test "client GET transport matches TypeScript URL.search escaping" do
    parent = self()
    string_method = %Skir.Method{name: "Echo", number: 1, doc: "", request: :string, response: :string}

    transport = fn :get, url, _headers, "", _opts ->
      send(parent, {:url, url})
      {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: ~s("ok")}}
    end

    client = ServiceClient.new!("https://example.test/rpc", transport: transport)
    assert {:ok, "ok"} = ServiceClient.invoke(client, string_method, "a b%?&#$=+/@'", http_method: :get)
    assert_receive {:url, "https://example.test/rpc?Echo:1::%22a%20b%25?&%23$=+/@%27%22"}
  end

  test "client only exposes an error body when content type matches text/plain as a MIME token" do
    transport = fn _, _, _, _, _ ->
      {:ok, %{status: 500, headers: [{"content-type", "application/text/plainfoo"}], body: "secret"}}
    end

    client = ServiceClient.new!("https://example.test/rpc", transport: transport)
    assert {:error, %RpcError{status_code: 500, message: "HTTP status 500"}} =
             ServiceClient.invoke(client, method(), 1)
  end

  test "client supports the TypeScript GET transport while POST remains default" do
    parent = self()

    transport = fn method, url, headers, body, _opts ->
      send(parent, {:request, method, url, headers, body})
      {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: ~s([42,0,"Alice"])}}
    end

    client = ServiceClient.new!("https://example.test/rpc", transport: transport)
    assert {:ok, %User{id: 42}} = ServiceClient.invoke(client, method(), 42, http_method: :get)
    assert_receive {:request, :get, url, _headers, ""}
    assert String.starts_with?(url, "https://example.test/rpc?GetUser:12345::42")
  end

  test "service options change forwarding and escape Studio script URLs" do
    echo = %{method() | request: {:record, User}}
    for keep <- [false, true] do
      svc = Service.new(keep_unrecognized_values: keep, can_send_unknown_error_message: true)
        |> Service.add_method(echo, fn request, _ -> {:ok, request} end)
      raw = Service.handle_request(svc, "GetUser:12345::[1,0,\"A\",\"future\"]")
      assert Jason.decode!(raw.data) == if(keep, do: [1, 0, "A", "future"], else: [1, 0, "A"])
    end
    html = Service.new(studio_app_js_url: "https://example.test/a?x=\"<>&") |> Service.handle_request("studio")
    assert html.data =~ "https://example.test/a?x=&quot;&lt;&gt;&amp;"
    assert_raise ArgumentError, fn -> Service.new(unknown: true) end
    assert_raise ArgumentError, fn -> Service.add_method(service(), method(), fn _, _ -> {:ok, 1} end) end
    for invalid <- [%{method() | name: ""}, %{method() | number: -1}, %{method() | number: 0x100000000}, %{method() | doc: true}] do
      assert_raise ArgumentError, fn -> Service.add_method(Service.new(), invalid, fn _, _ -> {:ok, 1} end) end
    end
    assert_raise ArgumentError, fn -> Skir.RPC.error(200) end
  end

  test "JSON dispatch rejects missing fields and invalid values while supporting readable colon responses" do
    for {body, expected} <- [
      {nil, "invalid request body"}, {" []", "bad request: expected JSON object"},
      {~s({"request":1}), "bad request: missing 'method' field in JSON"},
      {"Missing:::1", "bad request: method not found: Missing"}
    ] do
      assert %{status_code: 400, data: ^expected} = Service.handle_request(service(), body)
    end
    for body <- [~s({"method":12345,"request":7}), "GetUser:12345:readable:7"] do
      assert %{status_code: 200, data: json} = Service.handle_request(service(), body)
      assert Jason.decode!(json) == %{"id" => 7, "name" => "Alice"}
    end
    nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
    for body <- [~s({"method":12345,"request":"bad"}), "{\"method\":12345,\"request\":" <> nested <> "}"] do
      assert %{status_code: 400} = Service.handle_request(service(), body)
    end
  end

  test "handler errors and failing callbacks cannot expose secrets or crash dispatch" do
    for handler <- [fn _, _ -> raise Skir.RPC.ServiceError, status_code: 418 end,
      fn _, _ -> throw(:secret) end, fn _, _ -> exit(:secret) end,
      fn _, _ -> :invalid_return end, fn _, _ -> {:error, %Skir.RPC.ServiceError{status_code: 200, message: "secret"}} end] do
      raw = Service.handle_request(service(handler), "GetUser:12345::1")
      assert raw.status_code in [418, 500]
      assert raw.data in ["I'm a teapot", "server error"]
    end
    assert_raise Skir.RPC.ServiceError, "I'm a teapot", fn -> raise Skir.RPC.ServiceError, status_code: 418 end
    parent = self()
    for callback <- [fn _ -> raise "secret" end, fn _ -> throw(:secret) end, fn _ -> exit(:secret) end] do
      svc = service(fn _, _ -> raise "database secret" end)
        |> Service.set_can_send_unknown_error_message(callback)
        |> Service.set_error_logger(fn info -> send(parent, {:logged_unknown, info}); callback.(info) end)
      assert %{status_code: 500, data: "server error"} = Service.handle_request(svc, "GetUser:12345::1", :metadata)
      assert_receive {:logged_unknown, %{kind: :unknown, request_metadata: :metadata, method_name: "GetUser"}}
    end
  end

  test "invalid client options, requests and transports return errors instead of success" do
    for {url, opts} <- [{nil, []}, {"http://example.test", [headers: [1]]}, {"http://example.test", [headers: 1]}] do
      assert {:error, _} = ServiceClient.new(url, opts)
    end
    assert_raise ArgumentError, fn -> ServiceClient.new!("invalid") end
    transport = fn _, _, _, _, _ -> {:ok, %{status: 200, headers: [], body: "[]"}} end
    client = ServiceClient.new!("http://example.test", transport: transport)
    for {request, opts} <- [{"bad", []}, {1, [headers: [1]]}, {1, [http_method: :delete]}] do
      assert {:error, %RpcError{status_code: 0}} = ServiceClient.invoke(client, method(), request, opts)
    end
    for transport <- [1, fn _, _, _, _, _ -> :malformed end, fn _, _, _, _, _ -> raise "failed" end,
      fn _, _, _, _, _ -> throw(:failed) end, fn _, _, _, _, _ -> exit(:failed) end,
      fn _, _, _, _, _ -> {:error, "network failed"} end] do
      client = ServiceClient.new!("http://example.test", transport: transport)
      assert {:error, %RpcError{status_code: 0, message: message}} = ServiceClient.invoke(client, method(), 1)
      assert message =~ "Request failed:"
      assert_raise RpcError, fn -> ServiceClient.invoke!(client, method(), 1) end
    end
    errors = fn _, _, _, _, _ -> {:ok, %{status: 500, headers: [nil, {"x-other", "x"}], body: "secret"}} end
    client = ServiceClient.new!("http://example.test", transport: errors)
    assert {:error, %RpcError{message: "HTTP status 500"}} = ServiceClient.invoke(client, method(), 1)
  end

end
