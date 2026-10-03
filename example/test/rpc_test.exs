defmodule Example.RPCTest do
  use ExUnit.Case, async: true

  alias Example.Protocol.UserSkir
  alias Example.Protocol.UserSkir.User
  alias Skir.RPC.{Service, ServiceClient}

  test "generated server and client helpers round-trip through SkirRPC" do
    service = Example.RPC.service()

    transport = fn :post, _url, _headers, body, _opts ->
      raw = Service.handle_request(service, body, %{source: :test})
      {:ok, %{status: raw.status_code, headers: [{"content-type", raw.content_type}], body: raw.data}}
    end

    client = ServiceClient.new!("http://example.invalid/rpc", transport: transport)
    assert {:ok, %User{id: 42, name: "Alice"}} = UserSkir.get_user(client, 42)
    assert %User{id: 7} = UserSkir.get_user!(client, 7)
  end

  test "service list endpoint exposes generated method schema" do
    response = Service.handle_request(Example.RPC.service(), "list")
    assert response.status_code == 200
    [method] = Jason.decode!(response.data)["methods"]
    assert method["method"] == "GetUser"
    assert method["number"] == 12_345
    assert method["request"]["type"] == %{"kind" => "primitive", "value" => "int64"}
  end
end
