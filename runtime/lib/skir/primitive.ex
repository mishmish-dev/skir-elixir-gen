defmodule Skir.Primitive do
  @moduledoc false
  alias Skir.{Binary, Error, Limits}
  @safe 9_007_199_254_740_991
  @signed_min -9_223_372_036_854_775_808
  @signed_max 9_223_372_036_854_775_807
  @unsigned_max 18_446_744_073_709_551_615

  def default(:bool), do: false
  def default(type) when type in [:string, :bytes], do: ""
  def default(type) when type in [:float32, :float64], do: 0.0
  def default(type) when type in [:int32, :int64, :hash64, :timestamp], do: 0

  def encode(type, value, ctx) do
    value = validate(type, value, ctx)
    encoded = if ctx.format == :binary, do: binary_value(type, value), else: json_value(type, value, ctx)
    {encoded, value == default(type)}
  end

  def decode(type, input, %{format: :binary} = ctx) do
    node = Binary.semantic(input)
    # Zero is the universal default-value abbreviation, including strings/bytes.
    case node do
      {:number, 0} -> default(type)
      _ -> validate(type, from_binary(type, node, ctx), ctx)
    end
  end
  def decode(type, 0, _ctx), do: default(type)
  def decode(type, input, ctx), do: validate(type, from_json(type, input, ctx), ctx)

  defp validate(:bool, v, _) when is_boolean(v), do: v
  defp validate(:int32, v, ctx), do: integer(v, -2_147_483_648, 2_147_483_647, ctx)
  defp validate(:int64, v, ctx), do: integer(v, @signed_min, @signed_max, ctx)
  defp validate(:timestamp, v, ctx), do: integer(v, -8_640_000_000_000_000, 8_640_000_000_000_000, ctx)
  defp validate(:hash64, v, ctx), do: integer(v, 0, @unsigned_max, ctx)
  defp validate(type, v, _ctx) when type in [:float32, :float64] and v in [:nan, :infinity, :neg_infinity], do: v
  defp validate(type, v, ctx) when type in [:float32, :float64] and is_number(v) do
    try do
      v * 1.0
    rescue
      ArithmeticError -> Error.fail(ctx, :float_range)
    end
  end
  defp validate(:string, v, ctx) when is_binary(v) do
    Limits.bytes(v, ctx)
    unless String.valid?(v), do: Error.fail(ctx, :invalid_utf8)
    v
  end
  defp validate(:bytes, v, ctx) when is_binary(v), do: Limits.bytes(v, ctx)
  defp validate(_, _, ctx), do: Error.fail(ctx, :invalid_type)

  defp integer(v, lo, hi, ctx) do
    unless is_integer(v), do: Error.fail(ctx, :invalid_type, "expected integer")
    unless v >= lo and v <= hi, do: Error.fail(ctx, :integer_range)
    v
  end

  defp binary_value(:bool, v), do: {:number, if(v, do: 1, else: 0)}
  defp binary_value(:int32, v), do: {:number, v}
  defp binary_value(type, v), do: {type, v}

  defp json_value(:bool, v, %{format: :dense}), do: if(v, do: 1, else: 0)
  defp json_value(type, v, _) when type in [:int64, :hash64] and (v > @safe or v < -@safe), do: Integer.to_string(v)
  defp json_value(:bytes, v, %{format: :readable}), do: "hex:" <> Base.encode16(v, case: :lower)
  defp json_value(:bytes, v, _), do: Base.encode64(v)
  defp json_value(type, :nan, _) when type in [:float32, :float64], do: "NaN"
  defp json_value(type, :infinity, _) when type in [:float32, :float64], do: "Infinity"
  defp json_value(type, :neg_infinity, _) when type in [:float32, :float64], do: "-Infinity"
  defp json_value(:timestamp, v, %{format: :readable}) do
    case DateTime.from_unix(v, :millisecond) do
      {:ok, dt} -> %{"unix_millis" => v, "formatted" => DateTime.to_iso8601(dt)}
      {:error, _} -> %{"unix_millis" => v}
    end
  end
  defp json_value(_, v, _), do: v

  defp from_json(:bool, v, _) when is_boolean(v), do: v
  defp from_json(:bool, v, _) when is_number(v), do: v != 0
  defp from_json(:bool, v, ctx) when is_binary(v), do: parse_integer(v, ctx) != 0
  defp from_json(type, v, _) when type in [:int32, :int64, :hash64] and is_boolean(v), do: if(v, do: 1, else: 0)
  defp from_json(type, v, _) when type in [:int32, :int64, :hash64, :timestamp] and is_float(v), do: trunc(v)
  defp from_json(type, v, ctx) when type in [:int32, :int64, :hash64, :timestamp] and is_binary(v), do: parse_integer(v, ctx)

  defp from_json(type, "NaN", _) when type in [:float32, :float64], do: :nan
  defp from_json(type, "Infinity", _) when type in [:float32, :float64], do: :infinity
  defp from_json(type, "-Infinity", _) when type in [:float32, :float64], do: :neg_infinity
  defp from_json(:bytes, "hex:" <> hex, ctx) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, v} -> v
      :error -> Error.fail(ctx, :invalid_bytes)
    end
  end
  defp from_json(:bytes, v, ctx) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, bytes} -> bytes
      :error -> Error.fail(ctx, :invalid_bytes)
    end
  end
  defp from_json(:timestamp, %{"unix_millis" => v}, _), do: v
  defp from_json(_, v, _), do: v

  defp parse_integer(v, ctx) do
    # Bound parsing before Integer.parse/1, which otherwise accepts arbitrarily
    # long strings and trailing characters when its remainder is ignored.
    if byte_size(v) > 21, do: Error.fail(ctx, :integer_range)
    unless Regex.match?(~r/^-?(0|[1-9][0-9]*)$/, v), do: Error.fail(ctx, :invalid_integer)
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> Error.fail(ctx, :invalid_integer)
    end
  end

  defp from_binary(:bool, {kind, n}, _) when kind in [:number, :int64, :hash64, :float32, :float64] and is_number(n), do: n != 0
  defp from_binary(type, {kind, v}, _) when type in [:int32, :int64, :hash64, :timestamp] and kind in [:number, :int64, :hash64, :timestamp], do: v
  defp from_binary(type, {kind, v}, _) when type in [:int32, :int64, :hash64, :timestamp] and kind in [:float32, :float64] and is_number(v), do: trunc(v)
  defp from_binary(type, {kind, v}, _) when type in [:float32, :float64] and kind in [:number, :int64, :hash64, :float32, :float64], do: v
  defp from_binary(type, {type, v}, _) when type in [:string, :bytes], do: v
  defp from_binary(_, _, ctx), do: Error.fail(ctx, :invalid_type)
end
