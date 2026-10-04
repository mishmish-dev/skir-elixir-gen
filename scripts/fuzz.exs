# Deterministic, bounded mutation checks of the installed runtime and generated schemas.
# Valid mutations are allowed; only unstable results, unexpected failures or hangs fail.
defmodule Skir.MalformedInputChecks do
  alias Example.Protocol.UserSkir.{User, Event}
  alias Example.Protocol.TreeSkir.{Node, Loop}
  alias Example.Protocol.ApiSkir.{RecA, RecB, Value, Field}

  @seed 0x534B4952
  @mutations 128
  @timeout_ms 1_000
  @limits [max_bytes: 4_096, max_depth: 16, max_collection_length: 32, max_nodes: 256]

  def run do
    output = Path.expand("../.artifacts/malformed-input-checks.json", __DIR__)
    File.rm(output)
    :rand.seed(:exsss, {@seed, @seed + 1, @seed + 2})
    {:ok, supervisor} = Task.Supervisor.start_link()

    fixtures = [
      {User, User.new(id: 42, name: "Ada 🌍", status: {:user_created, User.new(name: "child")})},
      {Event, {:user_created, User.new(id: 1, name: "event")}},
      {Node, Node.new(value: "root", next: Node.new(value: "next"), children: [Node.new()])},
      {Loop, Loop.new(next: Loop.new())},
      {RecA, RecA.new(b: RecB.new(links: [RecA.new(name: "leaf")]))},
      {Value, {:object, [Field.new(name: "item", value: {:array, [{:text, "hello"}]})]}}
    ]

    corpus =
      Enum.flat_map(fixtures, fn {module, value} ->
        binary = module.encode!(value)
        json = module.encode_json!(value)
        term = module.to_json!(value)

        valid = [
          {module, :decode, binary, :valid},
          {module, :decode_json, json, :valid},
          {module, :from_json, term, :valid}
        ]

        truncations =
          for length <- 0..byte_size(binary),
              do: {module, :decode, binary_part(binary, 0, length), :mutation}

        mutations =
          for _ <- 1..@mutations,
              candidate <- [
                {module, :decode, mutate_bytes(binary), :mutation},
                {module, :decode_json, mutate_bytes(json), :mutation},
                {module, :from_json, mutate_term(term), :mutation}
              ],
              do: candidate

        valid ++ known_invalid(module) ++ truncations ++ mutations
      end)

    counts =
      for {module, decoder, input, expected} <- corpus,
          policy <- [:discard, :preserve],
          reduce: %{accepted: 0, rejected: 0, errors: %{}} do
        acc ->
          label =
            "#{inspect(module)}.#{decoder} policy=#{policy} input=#{inspect(input, limit: 8, printable_limit: 100)}"

          opts = [unknown_fields: policy] ++ @limits

          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              first = apply(module, decoder, [input, opts])
              second = apply(module, decoder, [input, opts])
              unless first === second, do: raise("unstable decoder result")
              first
            end)

          result = Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill)

          case result do
            {:ok, {:ok, _value}} when expected in [:valid, :mutation] ->
              %{acc | accepted: acc.accepted + 1}

            {:ok, {:error, %Skir.Error{reason: reason, message: message, path: path}}}
            when is_atom(reason) and is_binary(message) and is_list(path) ->
              unless expected == :mutation or expected == reason,
                do: raise("#{label}: expected #{inspect(expected)}, got #{reason}")

              %{
                acc
                | rejected: acc.rejected + 1,
                  errors: Map.update(acc.errors, Atom.to_string(reason), 1, &(&1 + 1))
              }

            nil ->
              raise("#{label}: decoder exceeded #{@timeout_ms}ms")

            unexpected ->
              raise("#{label}: unexpected worker result #{inspect(unexpected)}")
          end
      end

    Supervisor.stop(supervisor)

    summary = %{
      seed: @seed,
      random_algorithm: "exsss",
      mutations_per_schema_per_decoder: @mutations,
      schemas: Enum.map(fixtures, fn {module, _} -> inspect(module) end),
      decoders: ["decode", "decode_json", "from_json"],
      unknown_field_policies: ["discard", "preserve"],
      limits: Map.new(@limits),
      worker_timeout_ms: @timeout_ms,
      checks: counts.accepted + counts.rejected,
      repeated_decodes_per_check: 2,
      accepted: counts.accepted,
      rejected: counts.rejected,
      error_reasons: counts.errors,
      runtime_version: Application.spec(:skir_elixir_client, :vsn) |> to_string(),
      elixir_version: System.version(),
      otp_release: :erlang.system_info(:otp_release) |> to_string()
    }

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(summary))

    IO.puts(
      "PASS: #{summary.checks} bounded deterministic malformed-input checks; #{summary.accepted} accepted, #{summary.rejected} rejected. Summary: #{output}"
    )
  end

  defp known_invalid(module) do
    nested_term = Enum.reduce(1..20, [], fn _, acc -> [acc] end)
    many_nodes = List.duplicate(List.duplicate(0, 20), 20)

    [
      {module, :decode, "skir", :truncated},
      {module, :decode, <<"skir", 0xF3, 1, 0xFF>>, :invalid_utf8},
      {module, :decode, <<"skir", 0xF6, 0>>, :trailing_bytes},
      {module, :decode, "skir" <> :binary.copy(<<0xF7>>, 20) <> <<0xF6>>, :depth_limit},
      {module, :decode, <<"skir", 0xFA, 33>> <> :binary.copy(<<0>>, 33), :collection_limit},
      {module, :decode, :binary.copy(<<0>>, 4_097), :byte_limit},
      {module, :decode_json, "[", :invalid_json},
      {module, :decode_json, JSON.encode!(nested_term), :depth_limit},
      {module, :decode_json, JSON.encode!(List.duplicate(0, 33)), :collection_limit},
      {module, :decode_json, JSON.encode!(many_nodes), :node_limit},
      {module, :decode_json, :binary.copy(" ", 4_097), :byte_limit},
      {module, :from_json, <<0xFF>>, :invalid_utf8},
      {module, :from_json, nested_term, :depth_limit},
      {module, :from_json, List.duplicate(0, 33), :collection_limit},
      {module, :from_json, many_nodes, :node_limit}
    ]
  end

  defp mutate_bytes(bytes) do
    size = byte_size(bytes)
    offset = :rand.uniform(size) - 1
    <<prefix::binary-size(offset), _old, suffix::binary>> = bytes
    byte = <<:rand.uniform(256) - 1>>

    case :rand.uniform(5) do
      1 -> prefix <> byte <> suffix
      2 -> prefix <> suffix
      3 -> prefix <> byte <> binary_part(bytes, offset, size - offset)
      4 -> binary_part(bytes, 0, offset)
      5 -> bytes <> byte
    end
  end

  defp mutate_term(term) do
    replacement =
      Enum.at([nil, true, -1, 1.5, "invalid", [], %{}, [0], <<0xFF>>], :rand.uniform(9) - 1)

    case {:rand.uniform(4), term} do
      {1, [_ | _]} -> List.replace_at(term, :rand.uniform(length(term)) - 1, replacement)
      {2, list} when is_list(list) -> list ++ [replacement]
      {3, [_ | rest]} -> rest
      _ -> replacement
    end
  end
end

Skir.MalformedInputChecks.run()
