# Executed by the release binary via eval, never by mix run.
defmodule Skir.ReleaseBenchmark do
  alias Example.Protocol.UserSkir.{User, Event}
  alias Example.Protocol.TreeSkir.Node
  alias Example.Protocol.ApiSkir.{RecA, RecB}

  @iterations 2_000
  @samples 5
  @warmup 200

  def run do
    unless System.get_env("RELEASE_NAME") == "skir_example",
      do: raise("benchmark must run through the skir_example OTP release executable")

    {:ok, _} = Application.ensure_all_started(:skir_example)
    user = User.new(id: 42, name: "Ada 🌍", active: true, avatar: <<0, 1, 255>>)

    workloads = [
      {"User", User, %{user | status: {:user_created, User.new(name: "nested")}}},
      {"Event", Event, {:user_created, user}},
      {"Node", Node, Node.new(value: "root", children: [Node.new(value: "leaf")])},
      {"RecA", RecA, RecA.new(name: "root", b: RecB.new(links: [RecA.new(name: "leaf")]))}
    ]

    results =
      for {name, module, value} <- workloads,
          {format, encode, decode} <- [
            {"binary", :encode!, :decode!},
            {"json", :encode_json!, :decode_json!}
          ] do
        bytes = apply(module, encode, [value])
        expected = module.to_json!(value)

        unless module.to_json!(apply(module, decode, [bytes])) == expected,
          do: raise("#{name} #{format} round-trip mismatch")

        %{
          schema: name,
          format: format,
          payload_bytes: byte_size(bytes),
          encode: measure(fn -> apply(module, encode, [value]) end, byte_size(bytes)),
          decode: measure(fn -> apply(module, decode, [bytes]) end, byte_size(bytes))
        }
      end

    summary = %{
      mode: "otp_release",
      release: System.fetch_env!("RELEASE_NAME"),
      release_version: System.fetch_env!("RELEASE_VSN"),
      runtime_version: Application.spec(:skir_elixir_client, :vsn) |> to_string(),
      elixir_version: System.version(),
      otp_release: :erlang.system_info(:otp_release) |> to_string(),
      erts_version: :erlang.system_info(:version) |> to_string(),
      architecture: :erlang.system_info(:system_architecture) |> to_string(),
      schedulers: :erlang.system_info(:schedulers_online),
      iterations_per_sample: @iterations,
      samples: @samples,
      warmup_iterations: @warmup,
      results: results
    }

    File.write!(System.fetch_env!("SKIR_BENCHMARK_OUTPUT"), JSON.encode!(summary))
    IO.puts("Measured #{length(results)} codec workloads inside OTP release.")
  end

  defp measure(operation, bytes) do
    repeat(operation, @warmup)

    times =
      for _ <- 1..@samples do
        :erlang.garbage_collect()
        {microseconds, :ok} = :timer.tc(fn -> repeat(operation, @iterations) end)
        max(microseconds, 1)
      end

    median = times |> Enum.sort() |> Enum.at(div(@samples, 2))

    %{
      sample_microseconds: times,
      median_microseconds: median,
      operations_per_second: Float.round(@iterations * 1_000_000 / median, 2),
      megabytes_per_second: Float.round(@iterations * bytes / median, 2)
    }
  end

  defp repeat(operation, count) do
    Enum.each(1..count, fn _ -> operation.() end)
    :ok
  end
end

Skir.ReleaseBenchmark.run()
