defmodule Skir.HTTPRPCTest do
  use ExUnit.Case, async: false
  alias Example.Protocol.ApiSkir
  alias Example.Protocol.UserSkir
  alias UserSkir.User
  alias Skir.RPC.{Service, ServiceClient, RpcError}

  setup do
    test_pid = self()

    service =
      Service.new()
      |> UserSkir.add_get_user(fn
        0, _ ->
          {:error, Skir.RPC.error(404, "user missing")}

        id, metadata ->
          send(test_pid, {:request_metadata, metadata})
          {:ok, User.new(id: id, name: "Ada 🌍")}
      end)

    service = service |> ApiSkir.add_echo(fn value, _ -> {:ok, value} end)
    ref = make_ref()

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {Skir.RPC.Plug, [service: service]},
        options: [ref: ref, ip: {127, 0, 0, 1}, port: 0]
      ) |> Map.put(:id, ref)
    )

    url = "http://127.0.0.1:#{:ranch.get_port(ref)}/rpc"
    {:ok, client: ServiceClient.new!(url), url: url, ref: ref}
  end

  test "generated clients use real HTTP POST and GET with request metadata", %{client: client} do
    for method <- [:post, :get] do
      assert {:ok, %User{id: 42, name: "Ada 🌍"}} =
               UserSkir.get_user(client, 42,
                 http_method: method,
                 headers: [{"x-request-id", "round-trip"}],
                 timeout: 2_000
               )

      assert_receive {:request_metadata, metadata}
      assert metadata.method == if(method == :post, do: "POST", else: "GET")
      assert metadata.path == "/rpc"
      assert {"x-request-id", "round-trip"} in metadata.headers
    end
  end

  test "HTTP errors reach both result and raising generated client APIs", %{client: client} do
    assert {:error, %RpcError{status_code: 404, message: "HTTP status 404: user missing"}} =
             UserSkir.get_user(client, 0, timeout: 2_000)

    error = assert_raise RpcError, fn -> UserSkir.get_user!(client, 0, timeout: 2_000) end
    assert error.status_code == 404
  end

  test "HTTP reflection exposes stable generated record IDs", %{url: url} do
    assert {:ok, {{_, 200, _}, headers, body}} =
             :httpc.request(:get, {String.to_charlist(url <> "?list"), []}, [timeout: 2_000],
               body_format: :binary
             )

    assert {~c"content-type", ~c"application/json"} in headers
    methods = Jason.decode!(body)["methods"]
    assert Enum.map(methods, & &1["number"]) == [12345, 23456]
    method = Enum.find(methods, &(&1["number"] == 12345))
    assert method["number"] == 12345
    assert method["response"]["type"] == %{"kind" => "record", "value" => "user.skir:User"}
    ids = Enum.map(method["response"]["records"], & &1["id"])
    assert "user.skir:User.Pet" in ids
  end
  test "HTTP preserves escaped GET strings and preserves large POST bodies", %{client: client} do
    for method <- [:post, :get] do
      value = "a b%?&#$=+/@'\"<>[]{}^`|\n🌍"
      assert {:ok, ^value} = ApiSkir.echo(client, value, http_method: method, timeout: 2_000)
    end
    value = String.duplicate("a", 1_000_001)
    assert {:ok, ^value} = ApiSkir.echo(client, value, timeout: 5_000)
  end

  test "closed listeners produce controlled client errors for HTTP and HTTPS", %{client: client, url: url, ref: ref} do
    stop_supervised!(ref)
    assert {:error, %RpcError{status_code: 0}} = UserSkir.get_user(client, 1, timeout: 500, connect_timeout: 500)
    assert {:error, _} = Skir.RPC.HTTPClient.Httpc.request(:get, String.replace(url, "http:", "https:"), [], "", timeout: 500)
    assert {:error, {:unsupported_method, :put}} = Skir.RPC.HTTPClient.Httpc.request(:put, url, [], "", [])
    assert {:error, _} = Skir.RPC.HTTPClient.Httpc.request(:get, url, :bad_headers, "", [])
  end

end
