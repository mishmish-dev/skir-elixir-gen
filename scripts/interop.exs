defmodule Skir.Interop do
  # This script consumes vectors produced by the actual upstream Skir runtime.
  # Never use String.to_atom on the test vector's arbitrary JSON strings.
  @primitive_names ~w(bool int32 int64 hash64 float32 float64 timestamp string bytes)
  @primitive_atoms [
    :bool,
    :int32,
    :int64,
    :hash64,
    :float32,
    :float64,
    :timestamp,
    :string,
    :bytes
  ]
  @primitives Map.new(Enum.zip(@primitive_names, @primitive_atoms))
  @records %{
    "User" => Example.Protocol.UserSkir.User,
    "Event" => Example.Protocol.UserSkir.Event,
    "Node" => Example.Protocol.TreeSkir.Node,
    "Loop" => Example.Protocol.TreeSkir.Loop
  }
  def type(["array", other]), do: {:array, type(other)}
  def type(["optional", other]), do: {:optional, type(other)}

  def type(name) when is_binary(name) do
    case Map.fetch(@records, name) do
      {:ok, mod} -> {:record, mod}
      :error -> Map.fetch!(@primitives, name)
    end
  end

  def run(input, output) do
    vectors = input |> File.read!() |> Jason.decode!()

    results =
      Enum.map(vectors, fn row ->
        t = type(row["type"])
        label = row["name"]
        opts = [unknown_fields: :preserve]

        case row["mode"] do
          "dense_only" ->
            value = Skir.from_json!(t, row["dense"], opts)
            dense = Skir.to_json!(t, value)
            equal!(dense, row["dense"], label <> " unknown dense preservation")
            %{"name" => label, "dense" => dense}

          "binary_only" ->
            bytes = Base.decode64!(row["binary"])
            value = Skir.decode!(t, bytes, opts)
            encoded = Skir.encode!(t, value)
            equal!(encoded, bytes, label <> " unknown binary preservation")
            %{"name" => label, "binary" => Base.encode64(encoded)}

          "all" ->
            bytes = Base.decode64!(row["binary"])
            from_json = Skir.from_json!(t, row["dense"])
            from_binary = Skir.decode!(t, bytes)
            from_readable = Skir.from_json!(t, row["readable"])
            equal!(Skir.to_json!(t, from_binary), row["dense"], label <> " binary -> dense")
            equal!(Skir.to_json!(t, from_readable), row["dense"], label <> " readable -> dense")
            encoded = Skir.encode!(t, from_json)
            equal!(encoded, bytes, label <> " dense -> canonical binary")

            %{
              "name" => label,
              "dense" => Skir.to_json!(t, from_json),
              "readable" => Skir.to_json!(t, from_json, format: :readable),
              "binary" => Base.encode64(encoded)
            }
        end
      end)

    File.write!(output, Jason.encode!(results))
    IO.puts("Elixir validated #{length(results)} upstream reference vectors.")
  end

  defp equal!(actual, expected, label) do
    unless actual == expected,
      do:
        raise(
          "Interop mismatch: #{label}\nactual: #{inspect(actual)}\nexpected: #{inspect(expected)}"
        )
  end
end

case System.argv() do
  [input, output] -> Skir.Interop.run(input, output)
  _ -> raise "usage: mix run ../scripts/interop.exs <input.json> <output.json>"
end
