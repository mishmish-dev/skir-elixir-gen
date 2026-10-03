alias Skir.RPC.Service

[input_path, output_path] = System.argv()
cases = input_path |> File.read!() |> Jason.decode!()

string_method = %Skir.Method{
  name: "Echo",
  number: 12_345,
  doc: "",
  request: :string,
  response: :string
}

second_string_method = %Skir.Method{
  name: "Echo",
  number: 12_346,
  doc: "",
  request: :string,
  response: :string
}

conflict_method = %Skir.Method{
  name: "Conflict",
  number: 23_456,
  doc: "",
  request: :string,
  response: :string
}

single =
  Service.new()
  |> Service.add_method(string_method, fn request, _metadata -> {:ok, request} end)
  |> Service.add_method(conflict_method, fn _request, _metadata -> {:error, Skir.RPC.error(409)} end)

ambiguous =
  Service.new()
  |> Service.add_method(string_method, fn request, _metadata -> {:ok, request} end)
  |> Service.add_method(second_string_method, fn request, _metadata -> {:ok, request} end)

services = %{"single" => single, "ambiguous" => ambiguous}

results =
  Enum.map(cases, fn test_case ->
    service = Map.fetch!(services, test_case["service"])
    raw = Service.handle_request(service, test_case["body"], %{"source" => "parity-oracle"})

    %{
      "name" => test_case["name"],
      "response" => %{
        "status_code" => raw.status_code,
        "content_type" => raw.content_type,
        "data" => raw.data
      }
    }
  end)

parent = self()
client_method = %Skir.Method{name: "Echo", number: 12_345, doc: "", request: :string, response: :string}
client_request = "a b%?&#$=+/@'"

capture_client = fn http_method ->
  transport = fn method, url, _headers, body, _opts ->
    send(parent, {:client_wire, method, url, body})
    {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: ~s("ok")}}
  end

  client = Skir.RPC.ServiceClient.new!("https://example.test/rpc", transport: transport)
  {:ok, "ok"} = Skir.RPC.ServiceClient.invoke(client, client_method, client_request, http_method: http_method)

  receive do
    {:client_wire, method, url, body} ->
      %{"method" => method |> Atom.to_string() |> String.upcase(), "url" => url, "body" => body}
  after
    1_000 -> raise "client transport was not invoked"
  end
end

client_wire = %{
  "GET" => capture_client.(:get),
  "POST" => capture_client.(:post)
}

File.write!(output_path, Jason.encode!(%{"server" => results, "client_wire" => client_wire}))
