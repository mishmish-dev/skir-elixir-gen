defmodule Skir.GoldenAssertions do
  import ExUnit.Assertions
  alias Example.Protocol.GoldensSkir, as: G
  @primitives [:bool, :int32, :int64, :hash64, :float32, :float64, :timestamp, :string, :bytes]
  @records %{
    point: G.Point,
    color: G.Color,
    my_enum: G.MyEnum,
    enum_a: G.EnumA,
    enum_b: G.EnumB,
    keyed_arrays: G.KeyedArrays,
    rec_struct: G.RecStruct,
    rec_enum: G.RecEnum
  }

  def value({type, v}) when type in @primitives, do: {type, v}
  def value({:bool_optional, v}), do: {{:optional, :bool}, v}
  def value({:ints, v}), do: {{:array, :int32}, v}

  def value({:round_trip_dense_json, tv}) do
    {t, v} = value(tv)
    {t, Skir.decode_json!(t, Skir.encode_json!(t, v))}
  end

  def value({:round_trip_readable_json, tv}) do
    {t, v} = value(tv)
    {t, Skir.decode_json!(t, Skir.encode_json!(t, v, format: :readable))}
  end

  def value({:round_trip_bytes, tv}) do
    {t, v} = value(tv)
    {t, Skir.decode!(t, Skir.encode!(t, v))}
  end

  def value({tag, expr}) do
    case Map.fetch(@records, tag) do
      {:ok, mod} -> {{:record, mod}, expr}
      :error -> decode_expression(tag, expr)
    end
  end

  defp decode_expression(tag, expr) do
    # All tags are generated from the trusted schema, never from wire input.
    [record, operation] = tag |> Atom.to_string() |> String.split("_from_", parts: 2)
    [format, policy] = String.split(operation, "_", parts: 2)
    mod = Map.fetch!(@records, String.to_existing_atom(record))
    t = {:record, mod}
    opts = [unknown_fields: if(policy == "keep_unrecognized", do: :preserve, else: :discard)]

    v =
      if format == "json",
        do: Skir.decode_json!(t, string(expr), opts),
        else: Skir.decode!(t, bytes(expr), opts)

    {t, v}
  end

  def string(expr, opts \\ [])
  def string({:literal, s}, _opts), do: s

  def string({:to_dense_json, tv}, opts) do
    {t, v} = value(tv)
    Skir.encode_json!(t, v, opts)
  end

  def string({:to_readable_json, tv}, opts) do
    {t, v} = value(tv)
    Skir.encode_json!(t, v, Keyword.put(opts, :format, :readable))
  end

  def bytes(expr, opts \\ [])
  def bytes({:literal, b}, _opts), do: b

  def bytes({:to_bytes, tv}, opts) do
    {t, v} = value(tv)
    Skir.encode!(t, v, opts)
  end

  def verify(assertion, opts \\ [])
  def verify({:bytes_equal, a}, opts), do: assert(bytes(a.actual, opts) == bytes(a.expected))
  def verify({:bytes_in, a}, opts), do: assert(bytes(a.actual, opts) in a.expected)
  def verify({:string_equal, a}, opts), do: assert(string(a.actual, opts) == string(a.expected))
  def verify({:string_in, a}, opts), do: assert(string(a.actual, opts) in a.expected)

  def verify({:reserialize_value, a}, _opts) do
    {t, v} = value(a.value)

    variants = [
      v,
      Skir.decode_json!(t, Skir.encode_json!(t, v)),
      Skir.decode_json!(t, Skir.encode_json!(t, v, format: :readable)),
      Skir.decode!(t, Skir.encode!(t, v))
    ]

    for v <- variants do
      assert Skir.to_json!(t, v) in Enum.map(a.expected_dense_json, &Jason.decode!/1)

      assert Skir.to_json!(t, v, format: :readable) in Enum.map(
               a.expected_readable_json,
               &Jason.decode!/1
             )

      assert Skir.encode!(t, v) in a.expected_bytes
    end

    for expr <- a.alternative_jsons do
      parsed = Skir.decode_json!(t, string(expr), unknown_fields: :preserve)
      assert Skir.to_json!(t, parsed) in Enum.map(a.expected_dense_json, &Jason.decode!/1)
    end

    for json <- a.expected_dense_json ++ a.expected_readable_json do
      parsed = Skir.decode_json!(t, json, unknown_fields: :preserve)
      assert Skir.to_json!(t, parsed) in Enum.map(a.expected_dense_json, &Jason.decode!/1)
    end
    for encoded <- a.expected_bytes ++ Enum.map(a.alternative_bytes, &bytes/1) do
      parsed = Skir.decode!(t, encoded)
      assert Skir.encode!(t, parsed) in a.expected_bytes
    end

    # An arbitrary encoded value in Point's removed field 0 must be skipped
    # without losing the byte offset of field 1.
    for <<"skir", payload::binary>> <- a.expected_bytes do
      point = G.Point.decode!(<<"skir", 0xF8, payload::binary, 1>>)
      assert point.x == 1
    end

    if a.expected_type_descriptor do
      expected =
        a.expected_type_descriptor
        |> String.replace("@gepheum/skir-golden-tests/", "")
        |> Jason.decode!()

      assert Skir.RPC.TypeDescriptor.to_map(t) == expected
    end
  end

  def verify({:reserialize_large_string, a}, _opts) do
    verify_large(:string, String.duplicate("a", a.num_chars), a.expected_byte_prefix)
  end

  def verify({:reserialize_large_array, a}, _opts) do
    verify_large({:array, :int32}, List.duplicate(1, a.num_items), a.expected_byte_prefix)
  end

  def verify({tag, a}, _opts)
      when tag in [
             :enum_a_from_json_is_constant,
             :enum_a_from_bytes_is_constant,
             :enum_b_from_json_is_wrapper_b,
             :enum_b_from_bytes_is_wrapper_b
           ] do
    is_a = tag in [:enum_a_from_json_is_constant, :enum_a_from_bytes_is_constant]
    t = {:record, if(is_a, do: G.EnumA, else: G.EnumB)}
    opts = [unknown_fields: if(a.keep_unrecognized, do: :preserve, else: :discard)]

    actual =
      if tag in [:enum_a_from_json_is_constant, :enum_b_from_json_is_wrapper_b],
        do: Skir.decode_json!(t, string(a.actual), opts),
        else: Skir.decode!(t, bytes(a.actual), opts)

    assert actual == if(is_a, do: :a, else: {:b, a.expected})
  end

  defp verify_large(t, v, prefix) do
    encoded = Skir.encode!(t, v)
    assert binary_part(encoded, 0, byte_size(prefix)) == prefix
    assert Skir.decode!(t, encoded) == v

    for format <- [:dense, :readable] do
      assert Skir.decode_json!(t, Skir.encode_json!(t, v, format: format)) == v
    end
  end
end

defmodule Skir.GoldensTest do
  use ExUnit.Case, async: true
  alias Example.Protocol.GoldensSkir, as: G
  @cases G.unit_tests_const()
  test "upstream corpus has all 101 consecutive cases" do
    assert Enum.map(@cases, & &1.test_number) == Enum.to_list(1000..1100)
  end

  for row <- @cases do
    @row row
    test "upstream golden #{row.test_number}" do
      if @row.test_number in 1067..1070 do
        # Upstream silently drops preserved unknowns across formats. Elixir
        # requires explicit permission to lose them; verify both contracts.
        error = assert_raise Skir.Error, fn -> Skir.GoldenAssertions.verify(@row.assertion) end
        assert error.reason == :unknown_format
        Skir.GoldenAssertions.verify(@row.assertion, unknown_fields: :discard)
      else
        Skir.GoldenAssertions.verify(@row.assertion)
      end
    end
  end
end
