defmodule Skir.RPC.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Skir.RPC.Service

  @method %Skir.Method{
    name: "Add",
    number: 7001,
    doc: "Add metadata to a number.",
    request: :int32,
    response: :int32
  }

  def service(opts \\ []) do
    Service.new(opts)
    |> Service.add_method(@method, fn value, metadata ->
      {:ok, value + Map.get(metadata || %{}, :add, 0)}
    end)
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

    assert get_resp_header(conn, "content-type") in [
             ["application/json"],
             ["application/json; charset=utf-8"]
           ]

    assert conn.resp_body == "7"
  end

  test "GET exposes Studio and list endpoints" do
    for resolver <- [service(), fn -> service() end, {__MODULE__, :service, []}] do
      list_conn = conn(:get, "/rpc?list") |> Skir.RPC.Plug.call(service: resolver)
      assert list_conn.status == 200
      [method] = Jason.decode!(list_conn.resp_body)["methods"]
      assert method["method"] == "Add"
    end

    assert_raise ArgumentError, fn ->
      conn(:get, "/rpc?list") |> Skir.RPC.Plug.call(service: :invalid)
    end

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

  defmodule ScriptedRead do
    def read_req_body({_state, :error}, _), do: {:error, :timeout}

    def read_req_body({state, [chunk | rest]}, _) do
      {:more, chunk, {state, rest}}
    end

    def read_req_body({state, []}, _), do: {:ok, "", {state, []}}

    def send_resp({state, _}, status, headers, body),
      do: Plug.Adapters.Test.Conn.send_resp(state, status, headers, body)
  end

  test "chunked body reads obey limits and transport failures become HTTP 400" do
    for {chunks, limit, status, body} <- [
          {["Add:", "7001::4"], 100, 200, "4"},
          {["1234", "56"], 5, 413, "request body too large"},
          {["12345", "6"], 5, 413, "request body too large"},
          {:error, 100, 400, "invalid request body"}
        ] do
      connection = conn(:post, "/rpc", "")
      {_, state} = connection.adapter

      response =
        Skir.RPC.Plug.call(%{connection | adapter: {ScriptedRead, {state, chunks}}},
          service: service(max_request_bytes: limit)
        )

      assert response.status == status
      assert response.resp_body == body
    end
  end
end
