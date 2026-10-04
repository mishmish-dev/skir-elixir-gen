# Run each scenario in a new BEAM so prior access cannot hide initialization bugs.
alias Example.Protocol.ApiSkir.{RecA, RecB, Field, Value}

check = fn ->
  value = RecA.new(name: "root", b: RecB.new(links: [RecA.new(name: "leaf")]))
  expected = [[[], [[[], "leaf"]]], "root"]

  unless RecA.to_json!(RecA.decode!(RecA.encode!(value))) == expected,
    do: raise("mutually recursive codec mismatch")

  nested = {:object, [Field.new(name: "leaf", value: {:text, "hello"})]}

  unless Value.decode!(Value.encode!(nested)) == nested,
    do: raise("recursive enum/struct codec mismatch")

  ids =
    Skir.RPC.TypeDescriptor.to_map(RecA.type())["records"] |> Enum.map(& &1["id"]) |> Enum.sort()

  unless ids == ["api.skir:RecA", "api.skir:RecB"], do: raise("recursive descriptor mismatch")
  :ok
end

case System.argv() do
  ["defaults"] ->
    # Touch the opposite member first, before any serializer or reflection call.
    unless RecB.to_json!(RecB.default()) == [] and RecA.to_json!(RecA.default()) == [],
      do: raise("recursive defaults mismatch")

  ["codecs"] ->
    check.()

  ["descriptors"] ->
    Skir.RPC.TypeDescriptor.to_map(Value.type())
    check.()

  ["concurrent"] ->
    results = Task.async_stream(1..32, fn _ -> check.() end, max_concurrency: 8, timeout: 5_000)
    unless Enum.all?(results, &(&1 == {:ok, :ok})), do: raise("concurrent initialization failed")

  _ ->
    raise("expected cold-start scenario")
end

IO.puts("PASS: cold start #{hd(System.argv())}")
