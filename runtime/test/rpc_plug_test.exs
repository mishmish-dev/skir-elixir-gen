defmodule Skir.RPC.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Skir.RPC.Service

  @method %Skir.Method{name: "Add", number: 7001, doc: "Add metadata to a number.", request: :int32, response: :int32}

  defp service(opts \\ []) do
    Service.new(opts)
    |> Service.add_method(@method, fn value, metadata -> {:ok, value + Map.get(metadata || %{}, :add, 0)} end)
  end

  test "POST delegates SkirRPC bodies and builds custom request metadata" do
    conn =
      conn(:post, "/rpc", "Add:7001::4")
      |> put_req_header("x-add", "3")
      |> Skir.RPC.Plug.call(
        service: service(),
        metadata: fn conn ->
          [value] = get_req_header(conn, "x-add")
          %{add: String.to_integer(value)}
        end
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") in [["application/json"], ["application/json; charset=utf-8"]]
    assert conn.resp_body == "7"
  end

  test "GET exposes Studio and list endpoints" do
    list_conn = conn(:get, "/rpc?list") |> Skir.RPC.Plug.call(service: service())
    assert list_conn.status == 200
    [method] = Jason.decode!(list_conn.resp_body)["methods"]
    assert method["method"] == "Add"

    studio_conn = conn(:get, "/rpc?studio") |> Skir.RPC.Plug.call(service: service())
    assert studio_conn.status == 200
    assert studio_conn.resp_body =~ "<skir-studio-app>"
  end

  test "adapter rejects unsupported verbs and oversized bodies" do
    delete_conn = conn(:delete, "/rpc") |> Skir.RPC.Plug.call(service: service())
    assert delete_conn.status == 405

    tiny = service(max_request_bytes: 3)
    large_conn = conn(:post, "/rpc", "1234") |> Skir.RPC.Plug.call(service: tiny)
    assert large_conn.status == 413
  end
end
