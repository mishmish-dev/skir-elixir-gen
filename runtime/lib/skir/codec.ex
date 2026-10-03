defmodule Skir.Codec do
  @moduledoc false
  alias Skir.{Binary, Error, Limits, Primitive, Unknown}
  @primitives [:bool, :int32, :int64, :hash64, :float32, :float64, :timestamp, :string, :bytes]

  def default({:optional, _}), do: nil
  def default({:array, _}), do: []
  def default({:array, _, _}), do: []
  def default({:record, mod}), do: mod.default()
  def default(type) when type in @primitives, do: Primitive.default(type)

  # Return both the representation and default-ness in a single traversal.
  def encode({:optional, _}, nil, ctx), do: {null(ctx), true}
  def encode({:optional, type}, value, ctx) do
    {encoded, _} = encode(type, value, ctx)
    {encoded, false}
  end
  def encode({:array, type, _key_extractor}, values, ctx), do: encode({:array, type}, values, ctx)
  def encode({:array, type}, values, ctx) when is_list(values) do
    Limits.list_length(values, ctx)
    items = values |> Enum.with_index() |> Enum.map(fn {v, i} -> elem(encode(type, v, Limits.child(ctx, i)), 0) end)
    {array(items, ctx), values == []}
  end
  def encode({:record, mod}, value, ctx) do
    schema = mod.schema()
    case schema.kind do
      :struct -> encode_struct(schema, value, ctx)
      :enum -> encode_enum(schema, value, ctx)
    end
  end
  def encode(type, value, ctx) when type in @primitives, do: Primitive.encode(type, value, ctx)
  def encode(_, _, ctx), do: Error.fail(ctx, :invalid_type)

  def decode({:optional, type}, input, ctx) do
    if null?(input, ctx), do: nil, else: decode(type, input, ctx)
  end
  def decode({:array, type, _key_extractor}, input, ctx), do: decode({:array, type}, input, ctx)
  def decode({:array, type}, input, ctx) do
    if zero?(input, ctx) do
      []
    else
      items = array_items(input, ctx)
      Limits.list_length(items, ctx)
      items |> Enum.with_index() |> Enum.map(fn {v, i} -> decode(type, v, Limits.child(ctx, i)) end)
    end
  end
  def decode({:record, mod}, input, ctx) do
    schema = mod.schema()
    if zero?(input, ctx) do
      mod.default()
    else
      case schema.kind do
        :struct -> decode_struct(schema, input, ctx)
        :enum -> decode_enum(schema, input, ctx)
      end
    end
  end
  def decode(type, input, ctx) when type in @primitives, do: Primitive.decode(type, input, ctx)
  def decode(_, _, ctx), do: Error.fail(ctx, :invalid_type)

  defp encode_struct(_schema, :skir_default, ctx), do: {empty_struct(ctx), true}
  defp encode_struct(schema, value, ctx) when is_map(value) do
    unless Map.get(value, :__struct__) == schema.module, do: Error.fail(ctx, :invalid_type, "expected generated struct")
    unknown = Map.get(value, :__skir_unknown_fields__, %{})
    unless is_map(unknown) and not is_struct(unknown), do: Error.fail(ctx, :invalid_unknown_fields)
    unknown = if ctx.unknown_fields == :discard, do: %{}, else: unknown
    encoded = Enum.map(schema.fields, fn field ->
      c = Limits.child(ctx, field.name)
      v = case Map.fetch(value, field.name) do
        {:ok, v} -> v
        :error -> Error.fail(c, :missing_field)
      end
      {wire, is_default} = encode(field.type, v, c)
      {field, wire, is_default}
    end)
    known_default = Enum.all?(encoded, fn {_, _, d} -> d end)
    result = if ctx.format == :readable do
      known = Map.new(for {f, w, false} <- encoded, do: {f.json_name, w})
      known_names = MapSet.new(schema.fields, & &1.json_name)
      Enum.reduce(unknown, known, fn {key, preserved}, acc ->
        unless is_binary(key) and not MapSet.member?(known_names, key), do: Error.fail(ctx, :unknown_format)
        Map.put(acc, key, encode_unknown(preserved, Limits.child(ctx, key)))
      end)
    else
      unknown = Enum.reduce(unknown, %{}, fn {key, preserved}, acc ->
        unless is_integer(key) and key >= schema.slots, do: Error.fail(ctx, :unknown_format)
        Limits.collection(key + 1, ctx)
        Map.put(acc, key, encode_unknown(preserved, Limits.child(ctx, key)))
      end)
      last = Enum.reduce(encoded, -1, fn {f, _, d}, n -> if d, do: n, else: max(n, f.number) end)
      last = Enum.reduce(Map.keys(unknown), last, &max/2)
      Limits.collection(last + 1, ctx)
      values = Map.new(encoded, fn {f, w, _} -> {f.number, w} end) |> Map.merge(unknown)
      items = if last < 0, do: [], else: Enum.map(0..last, &Map.get(values, &1, zero(ctx)))
      array(items, ctx)
    end
    {result, known_default and map_size(unknown) == 0}
  end
  defp encode_struct(_, _, ctx), do: Error.fail(ctx, :invalid_type, "expected generated struct")

  defp decode_struct(schema, input, %{format: :binary} = ctx), do: decode_slots(schema, array_items(input, ctx), ctx)
  defp decode_struct(schema, input, ctx) when is_list(input), do: decode_slots(schema, input, %{ctx | format: :dense})
  defp decode_struct(schema, input, ctx) when is_map(input) and not is_struct(input) do
    Limits.collection(map_size(input), ctx)
    ctx = %{ctx | format: :readable}
    known = Map.new(schema.fields, &{&1.json_name, &1})
    # Start with the generated default, not recursive codec calls. Hard-recursive
    # defaults use a finite :skir_default sentinel instead of an infinite struct.
    mod = schema.module
    Enum.reduce(input, mod.default(), fn {key, value}, acc ->
      case Map.fetch(known, key) do
        {:ok, field} -> Map.put(acc, field.name, decode(field.type, value, Limits.child(ctx, field.name)))
        :error -> preserve_field(acc, key, value, ctx)
      end
    end)
  end
  defp decode_struct(_, _, ctx), do: Error.fail(ctx, :invalid_type, "expected struct array or object")

  defp decode_slots(schema, items, ctx) do
    Limits.list_length(items, ctx)
    fields = Map.new(schema.fields, &{&1.number, &1})
    mod = schema.module
    items |> Enum.with_index() |> Enum.reduce(mod.default(), fn {value, number}, acc ->
      case Map.fetch(fields, number) do
        {:ok, field} -> Map.put(acc, field.name, decode(field.type, value, Limits.child(ctx, field.name)))
        :error when number < schema.slots -> acc
        :error -> preserve_field(acc, number, value, ctx)
      end
    end)
  end

  defp preserve_field(acc, _, _, %{unknown_fields: :discard}), do: acc
  defp preserve_field(acc, key, input, ctx) do
    preserved = unknown(input, ctx)
    Map.update!(acc, :__skir_unknown_fields__, &Map.put(&1, key, preserved))
  end

  defp encode_enum(_schema, :unknown, ctx) do
    {if(ctx.format == :readable, do: "unknown", else: zero(ctx)), true}
  end
  defp encode_enum(schema, {:unknown, %Unknown{} = preserved}, ctx) do
    if ctx.unknown_fields == :discard, do: encode_enum(schema, :unknown, ctx), else: {encode_unknown(preserved, ctx), false}
  end
  defp encode_enum(schema, value, ctx) do
    {name, payload, has_payload} = case value do
      {name, payload} when is_atom(name) -> {name, payload, true}
      name when is_atom(name) -> {name, nil, false}
      _ -> Error.fail(ctx, :invalid_type, "expected enum atom or tagged tuple")
    end
    field = Enum.find(schema.fields, &(&1.name == name)) || Error.fail(ctx, :invalid_enum)
    case {field.type, has_payload} do
      {nil, false} -> {if(ctx.format == :readable, do: field.json_name, else: number(field.number, ctx)), false}
      {nil, true} -> Error.fail(ctx, :invalid_enum, "constant variant cannot carry a payload")
      {_, false} -> Error.fail(ctx, :invalid_enum, "variant requires a payload")
      {type, true} ->
        {wire, _} = encode(type, payload, Limits.child(ctx, :value))
        result = case ctx.format do
          :binary -> {:variant, field.number, wire}
          :dense -> [field.number, wire]
          :readable -> %{"kind" => field.json_name, "value" => wire}
        end
        {result, false}
    end
  end

  defp decode_enum(schema, input, ctx) do
    {tag, payload, has_payload, actual_format} = enum_parts(input, ctx)
    ctx = %{ctx | format: actual_format}
    cond do
      tag in [0, "unknown", "UNKNOWN"] and not has_payload -> :unknown
      is_integer(tag) and tag in schema.removed -> :unknown
      true ->
        field = Enum.find(schema.fields, fn f -> f.number == tag or (is_binary(tag) and String.downcase(f.json_name) == String.downcase(tag)) end)
        case {field, has_payload} do
          {nil, _} -> if(ctx.unknown_fields == :discard, do: :unknown, else: {:unknown, unknown(input, ctx)})
          {%{type: nil, name: name}, false} -> name
          {%{type: nil, name: name}, true} -> name
          {%{type: type, name: name}, false} -> {name, default(type)}
          {%{type: type, name: name}, true} -> {name, decode(type, payload, Limits.child(ctx, :value))}
        end
    end
  end

  defp enum_parts(input, %{format: :binary} = ctx) do
    case Binary.semantic(input) do
      {:number, n} when is_integer(n) and n >= 0 and n <= 2_147_483_647 -> {n, nil, false, :binary}
      {:variant, n, value} -> {n, value, true, :binary}
      {:array, [ordinal, value]} ->
        case Binary.semantic(ordinal) do
          {:number, n} when is_integer(n) and n > 0 and n <= 2_147_483_647 -> {n, value, true, :binary}
          _ -> Error.fail(ctx, :invalid_enum)
        end
      _ -> Error.fail(ctx, :invalid_enum)
    end
  end
  defp enum_parts(n, _) when is_integer(n) and n >= 0 and n <= 2_147_483_647, do: {n, nil, false, :dense}
  defp enum_parts(n, _) when is_binary(n), do: {n, nil, false, :readable}
  defp enum_parts([n, v], _) when is_integer(n) and n > 0 and n <= 2_147_483_647, do: {n, v, true, :dense}
  defp enum_parts(%{"kind" => n, "value" => v}, _) when is_binary(n), do: {n, v, true, :readable}
  defp enum_parts(_, ctx), do: Error.fail(ctx, :invalid_enum)

  defp unknown(input, %{format: :binary}), do: %Unknown{format: :binary, value: Binary.raw(input)}
  defp unknown(input, ctx), do: %Unknown{format: ctx.format, value: input}
  defp encode_unknown(%Unknown{format: format, value: value}, ctx) do
    unless format == ctx.format, do: Error.fail(ctx, :unknown_format, "unknown data can only be preserved in its original format; use unknown_fields: :discard to opt out")
    if format == :binary do
      Limits.bytes(value, ctx)
      {:raw, value, nil}
    else
      Limits.json_term(value, ctx)
    end
  end
  defp encode_unknown(_, ctx), do: Error.fail(ctx, :invalid_unknown_fields)

  defp zero(%{format: :binary}), do: {:number, 0}
  defp zero(_), do: 0
  defp number(n, %{format: :binary}), do: {:number, n}
  defp number(n, _), do: n
  defp zero?(input, %{format: :binary}), do: Binary.semantic(input) == {:number, 0}
  defp zero?(input, _), do: input === 0
  defp null(%{format: :binary}), do: :null
  defp null(_), do: nil
  defp null?(input, %{format: :binary}), do: Binary.semantic(input) == :null
  defp null?(input, _), do: is_nil(input)
  defp array(items, %{format: :binary}), do: {:array, items}
  defp array(items, _), do: items
  defp array_items(input, %{format: :binary} = ctx) do
    case Binary.semantic(input) do
      {:array, items} -> items
      _ -> Error.fail(ctx, :invalid_type, "expected array")
    end
  end
  defp array_items(input, _) when is_list(input), do: input
  defp array_items(_, ctx), do: Error.fail(ctx, :invalid_type, "expected array")
  defp empty_struct(%{format: :readable}), do: %{}
  defp empty_struct(ctx), do: array([], ctx)
end
