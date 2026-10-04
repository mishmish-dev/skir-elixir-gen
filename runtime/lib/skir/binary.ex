defmodule Skir.Binary do
  @moduledoc false
  import Bitwise
  alias Skir.{Error, Limits}

  # This layer handles one value, without the public four-byte "skir" prefix.
  # Parsed nodes retain their original byte slice so unknown fields round-trip
  # without changing noncanonical-but-valid encodings or NaN payload bits.
  def decode_value(bytes, ctx) do
    Limits.bytes(bytes, ctx)
    {node, rest, _remaining} = read(bytes, ctx, ctx.max_nodes)
    if rest != <<>>, do: Error.fail(ctx, :trailing_bytes)
    node
  end

  def encode_value(node, ctx) do
    tree = write(node, ctx)
    Limits.size(IO.iodata_length(tree), ctx)
    IO.iodata_to_binary(tree)
  end

  def semantic({:raw, _, value}), do: value
  def semantic(value), do: value
  def raw({:raw, bytes, _}), do: :binary.copy(bytes)

  defp read(_bytes, ctx, remaining) when remaining <= 0, do: Error.fail(ctx, :node_limit)
  defp read(<<>>, ctx, _), do: Error.fail(ctx, :truncated)

  defp read(bytes, ctx, remaining) do
    <<marker, rest::binary>> = bytes
    {value, tail, remaining} = read_marker(marker, rest, ctx, remaining - 1)
    consumed = byte_size(bytes) - byte_size(tail)
    {{:raw, binary_part(bytes, 0, consumed), value}, tail, remaining}
  end

  defp read_marker(n, rest, _ctx, remaining) when n <= 231, do: {{:number, n}, rest, remaining}

  defp read_marker(0xE8, <<n::little-unsigned-16, rest::binary>>, _, remaining),
    do: {{:number, n}, rest, remaining}

  defp read_marker(0xE9, <<n::little-unsigned-32, rest::binary>>, _, remaining),
    do: {{:number, n}, rest, remaining}

  defp read_marker(0xEA, <<n::little-unsigned-64, rest::binary>>, _, remaining),
    do: {{:hash64, n}, rest, remaining}

  defp read_marker(0xEB, <<n, rest::binary>>, _, remaining),
    do: {{:number, n - 256}, rest, remaining}

  defp read_marker(0xEC, <<n::little-unsigned-16, rest::binary>>, _, remaining),
    do: {{:number, n - 65536}, rest, remaining}

  defp read_marker(0xED, <<n::little-signed-32, rest::binary>>, _, remaining),
    do: {{:number, n}, rest, remaining}

  defp read_marker(0xEE, <<n::little-signed-64, rest::binary>>, _, remaining),
    do: {{:int64, n}, rest, remaining}

  defp read_marker(0xEF, <<n::little-signed-64, rest::binary>>, _, remaining),
    do: {{:timestamp, n}, rest, remaining}

  defp read_marker(0xF0, <<bytes::binary-size(4), rest::binary>>, _, remaining),
    do: {{:float32, float_from_bits(bytes, 32)}, rest, remaining}

  defp read_marker(0xF1, <<bytes::binary-size(8), rest::binary>>, _, remaining),
    do: {{:float64, float_from_bits(bytes, 64)}, rest, remaining}

  defp read_marker(0xF2, rest, _, remaining), do: {{:string, ""}, rest, remaining}
  defp read_marker(0xF4, rest, _, remaining), do: {{:bytes, <<>>}, rest, remaining}

  defp read_marker(marker, rest, ctx, remaining) when marker in [0xF3, 0xF5] do
    {n, rest} = read_length(rest, ctx)
    Limits.size(n, ctx)
    if n > byte_size(rest), do: Error.fail(ctx, :truncated)
    {value, tail} = :erlang.split_binary(rest, n)
    if marker == 0xF3 and not String.valid?(value), do: Error.fail(ctx, :invalid_utf8)
    kind = if marker == 0xF3, do: :string, else: :bytes
    {{kind, value}, tail, remaining}
  end

  defp read_marker(marker, rest, ctx, remaining) when marker in 0xF6..0xFA do
    {n, rest} = if marker == 0xFA, do: read_length(rest, ctx), else: {marker - 0xF6, rest}
    Limits.collection(n, ctx)
    if n > byte_size(rest), do: Error.fail(ctx, :truncated)
    {items, tail, remaining} = read_items(n, rest, ctx, remaining, [], 0)
    {{:array, items}, tail, remaining}
  end

  defp read_marker(marker, rest, ctx, remaining) when marker in 0xFB..0xFE do
    {value, tail, remaining} = read(rest, Limits.child(ctx, :value), remaining)
    {{:variant, marker - 0xFA, value}, tail, remaining}
  end

  defp read_marker(0xFF, rest, _, remaining), do: {:null, rest, remaining}
  defp read_marker(_, _, ctx, _), do: Error.fail(ctx, :truncated)

  defp read_length(<<n, rest::binary>>, _) when n <= 231, do: {n, rest}
  defp read_length(<<0xE8, n::little-unsigned-16, rest::binary>>, _), do: {n, rest}
  defp read_length(<<0xE9, n::little-unsigned-32, rest::binary>>, _), do: {n, rest}
  defp read_length(_, ctx), do: Error.fail(ctx, :invalid_length)
  defp read_items(0, rest, _, remaining, acc, _), do: {Enum.reverse(acc), rest, remaining}

  defp read_items(n, rest, ctx, remaining, acc, i) do
    {value, tail, remaining} = read(rest, Limits.child(ctx, i), remaining)
    read_items(n - 1, tail, ctx, remaining, [value | acc], i + 1)
  end

  defp write({:raw, bytes, _}, ctx) do
    # Unknown structs are constructible by application code, so validate before
    # emitting preserved bytes instead of blindly trusting their provenance.
    decode_value(bytes, ctx)
    bytes
  end

  defp write({:number, n}, ctx), do: integer(n, ctx)

  defp write({:int64, n}, ctx)
       when is_integer(n) and n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807 do
    if n >= -2_147_483_648 and n <= 2_147_483_647,
      do: integer(n, ctx),
      else: <<0xEE, n::little-signed-64>>
  end

  defp write({:hash64, n}, ctx)
       when is_integer(n) and n >= 0 and n <= 18_446_744_073_709_551_615 do
    if n <= 4_294_967_295, do: integer(n, ctx), else: <<0xEA, n::little-unsigned-64>>
  end

  defp write({:timestamp, n}, _)
       when is_integer(n) and n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807 do
    if n == 0, do: <<0>>, else: <<0xEF, n::little-signed-64>>
  end

  defp write({kind, n}, ctx) when kind in [:float32, :float64] do
    cond do
      n == 0 -> <<0>>
      kind == :float32 -> [<<0xF0>>, float_bits(n, 32, ctx)]
      true -> [<<0xF1>>, float_bits(n, 64, ctx)]
    end
  end

  defp write({kind, bytes}, ctx) when kind in [:string, :bytes] and is_binary(bytes) do
    Limits.bytes(bytes, ctx)
    if kind == :string and not String.valid?(bytes), do: Error.fail(ctx, :invalid_utf8)
    base = if kind == :string, do: 0xF2, else: 0xF4
    if bytes == <<>>, do: <<base>>, else: [<<base + 1>>, integer(byte_size(bytes), ctx), bytes]
  end

  defp write({:array, values}, ctx) when is_list(values) do
    n = Limits.list_length(values, ctx)
    header = if n <= 3, do: <<0xF6 + n>>, else: [<<0xFA>>, integer(n, ctx)]

    items =
      values |> Enum.with_index() |> Enum.map(fn {v, i} -> write(v, Limits.child(ctx, i)) end)

    [header | items]
  end

  defp write({:variant, number, value}, ctx)
       when is_integer(number) and number > 0 and number <= 2_147_483_647 do
    header = if number <= 4, do: <<0xFA + number>>, else: [<<0xF8>>, integer(number, ctx)]
    [header, write(value, Limits.child(ctx, :value))]
  end

  defp write(:null, _), do: <<0xFF>>
  defp write(_, ctx), do: Error.fail(ctx, :invalid_wire_value)

  defp integer(n, _) when is_integer(n) and n >= 0 and n <= 231, do: <<n>>

  defp integer(n, _) when is_integer(n) and n >= 232 and n <= 65535,
    do: <<0xE8, n::little-unsigned-16>>

  defp integer(n, _) when is_integer(n) and n >= 65536 and n <= 4_294_967_295,
    do: <<0xE9, n::little-unsigned-32>>

  defp integer(n, _) when is_integer(n) and n >= -256 and n < 0, do: <<0xEB, n + 256>>

  defp integer(n, _) when is_integer(n) and n >= -65536 and n < -256,
    do: <<0xEC, n + 65536::little-unsigned-16>>

  defp integer(n, _) when is_integer(n) and n >= -2_147_483_648 and n < -65536,
    do: <<0xED, n::little-signed-32>>

  defp integer(_, ctx), do: Error.fail(ctx, :integer_range)

  defp float_bits(:nan, 32, _), do: <<0x7FC00000::little-unsigned-32>>
  defp float_bits(:infinity, 32, _), do: <<0x7F800000::little-unsigned-32>>
  defp float_bits(:neg_infinity, 32, _), do: <<0xFF800000::little-unsigned-32>>
  defp float_bits(:nan, 64, _), do: <<0x7FF8000000000000::little-unsigned-64>>
  defp float_bits(:infinity, 64, _), do: <<0x7FF0000000000000::little-unsigned-64>>
  defp float_bits(:neg_infinity, 64, _), do: <<0xFFF0000000000000::little-unsigned-64>>

  defp float_bits(value, bits, ctx) when is_number(value) do
    try do
      <<value::little-float-size(bits)>>
    rescue
      _ in [ArgumentError, ArithmeticError] -> Error.fail(ctx, :float_range)
    end
  end

  defp float_bits(_, _, ctx), do: Error.fail(ctx, :invalid_type, "expected float")

  defp float_from_bits(bytes, size) do
    bits = :binary.decode_unsigned(bytes, :little)

    {exponent, fraction, sign} =
      if size == 32 do
        {bits &&& 0x7F800000, bits &&& 0x007FFFFF, bits &&& 0x80000000}
      else
        {bits &&& 0x7FF0000000000000, bits &&& 0x000FFFFFFFFFFFFF, bits &&& 0x8000000000000000}
      end

    max_exponent = if size == 32, do: 0x7F800000, else: 0x7FF0000000000000

    cond do
      exponent == max_exponent and fraction != 0 ->
        :nan

      exponent == max_exponent and sign != 0 ->
        :neg_infinity

      exponent == max_exponent ->
        :infinity

      true ->
        case bytes do
          <<value::little-float-32>> -> value
          <<value::little-float-64>> -> value
        end
    end
  end
end
