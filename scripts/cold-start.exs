# Run each scenario in a new BEAM so prior access cannot hide initialization bugs.
alias Example.Protocol.ApiSkir.{RecA, RecB, Field, Value, Status}

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
    parent = self()
    operations = [check,
      fn -> unless RecA.to_json!(RecA.default()) == [], do: raise("RecA default") end,
      fn -> unless RecB.to_json!(RecB.default()) == [], do: raise("RecB default") end,
      fn -> unless Field.decode!(Field.encode!(Field.new(name: "leaf"))).name == "leaf", do: raise("Field codec") end,
      fn -> unless Status.to_json!(Status.default()) == 0, do: raise("enum default") end,
      fn -> unless Skir.RPC.TypeDescriptor.to_map(Value.type())["records"] |> length() == 2, do: raise("enum reflection") end]
    tasks = for _ <- 1..4, operation <- operations do
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do :go -> operation.() after 5_000 -> raise("start barrier timeout") end
      end)
    end
    for %{pid: pid} <- tasks do
      receive do {:ready, ^pid} -> :ok after 5_000 -> raise("worker readiness timeout") end
    end
    for %{pid: pid} <- tasks, do: send(pid, :go)
    for task <- tasks, do: Task.await(task, 5_000)

  _ ->
    raise("expected cold-start scenario")
end

IO.puts("PASS: cold start #{hd(System.argv())}")
