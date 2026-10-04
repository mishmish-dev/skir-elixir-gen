defmodule Skir.ValidationTest do
  use ExUnit.Case, async: true

  test "invalid struct values return structured errors and honor byte limits" do
    value = %Skir.Unknown{format: :dense, value: "payload"}
    assert {:error, %Skir.Error{reason: :invalid_type}} = Skir.to_json(:int32, value)
    assert {:error, %Skir.Error{reason: :byte_limit}} = Skir.to_json(:int32, value, max_bytes: 2)
  end

  test "improper lists return structured errors, not ArgumentError" do
    assert {:error, %Skir.Error{}} = Skir.to_json({:array, :int32}, [1 | 2])
    assert {:error, %Skir.Error{}} = Skir.from_json({:array, :int32}, [1 | 2])
  end

  test "nested collections have a shared node budget" do
    assert {:error, %Skir.Error{reason: :node_limit}} =
             Skir.from_json({:array, {:array, :int32}}, [[1, 2], [3, 4]], max_nodes: 4)
  end

  test "JSON object keys must be UTF-8 and cannot create atoms" do
    assert {:error, %Skir.Error{reason: :invalid_utf8}} = Skir.from_json(:int32, %{<<255>> => 1})

    assert {:error, %Skir.Error{reason: :invalid_json}} =
             Skir.from_json(:int32, %{arbitrary_atom: 1})
  end

  test "unknown options and invalid limits are rejected" do
    for opts <- [
          [max_depth: 0],
          [max_bytes: -1],
          [max_nodes: 0],
          [max_collection_length: 0],
          [format: :dense],
          [unknown_fields: :invent],
          [surprise: 1],
          %{},
          [1]
        ] do
      assert {:error, %Skir.Error{reason: :invalid_options}} = Skir.encode(:int32, 1, opts)
    end
  end

  test "numeric reader compatibility retains strict ranges and complete string parsing" do
    assert {:error, %Skir.Error{reason: :integer_range}} = Skir.from_json(:int32, "2147483648")

    assert {:error, %Skir.Error{reason: :integer_range}} =
             Skir.from_json(:timestamp, "8640000000000001")

    assert {:error, %Skir.Error{reason: :integer_range}} = Skir.from_json(:hash64, -1.5)

    for value <- ["2x", " 2", "02", "1.5", "2\n", String.duplicate("9", 100)] do
      assert {:error, %Skir.Error{}} = Skir.from_json(:int32, value)
    end

    assert {:error, %Skir.Error{reason: :invalid_type}} = Skir.to_json(:int32, 2.0)

    assert {:error, %Skir.Error{reason: :invalid_type}} =
             Skir.decode(:int32, <<"skir", 0xF0, 0, 0, 0xC0, 0x7F>>)
  end

  test "malformed numeric and wire inputs retain bounded structured failures" do
    for {type, input, reason} <- [
          {:int32, "2147483648", :integer_range},
          {:int64, "-9223372036854775809", :integer_range},
          {:bytes, "hex:zz", :invalid_bytes},
          {:bytes, "not base64!", :invalid_bytes},
          {:string, <<255>>, :invalid_utf8},
          {:int32, :not_json, :invalid_json}
        ] do
      assert {:error, %Skir.Error{reason: ^reason}} = Skir.from_json(type, input)
    end

    huge = Integer.pow(2, 2048)
    assert {:error, %Skir.Error{reason: :float_range}} = Skir.encode(:float64, huge)

    assert Skir.to_json!(:timestamp, 8_640_000_000_000_000, format: :readable) == %{
             "unix_millis" => 8_640_000_000_000_000
           }

    for {call, reason} <- [
          {fn -> Skir.to_json({:array, :int32}, [1, 2], max_nodes: 2) end, :node_limit},
          {fn -> Skir.decode({:array, :int32}, <<"skir", 0xF8, 1, 2>>, max_nodes: 2) end,
           :node_limit},
          {fn -> Skir.decode(:string, <<"skir", 0xF3, 0xEE>>) end, :invalid_length},
          {fn -> Skir.decode(:string, <<"skir", 0xF3, 1, 255>>) end, :invalid_utf8},
          {fn -> Skir.decode(:int32, <<"skir", 1, 2>>) end, :trailing_bytes},
          {fn -> Skir.decode_json(:int32, "1", max_bytes: 1) end, nil},
          {fn -> Skir.decode_json({:array, :int32}, "[]", max_bytes: 1) end, :byte_limit},
          {fn -> Skir.decode_json(:string, ~s("[\\\"\\\\]"), max_depth: 1) end, nil},
          {fn -> Skir.decode_json(:int32, "[[[0]]]", max_depth: 2) end, :depth_limit},
          {fn -> Skir.from_json({:array, :int32}, [1, 2], max_collection_length: 1) end,
           :collection_limit},
          {fn -> Skir.from_json(:int32, %{"one" => 1, "two" => 2}, max_collection_length: 1) end,
           :collection_limit},
          {fn -> Skir.decode({:array, :int32}, <<"skir", 1>>) end, :invalid_type}
        ] do
      result = call.()

      if reason,
        do: assert(match?({:error, %Skir.Error{reason: ^reason}}, result)),
        else: assert(match?({:ok, _}, result))
    end

    assert {:error, %Skir.Error{reason: :byte_limit}} = Skir.encode(:int32, 1, max_bytes: 4)

    for type <- [:int32, :int64, :hash64], {input, want} <- [{false, 0}, {true, 1}] do
      assert Skir.from_json!(type, input) == want
    end
  end

  test "BEAM non-finite atoms map to canonical IEEE bits and JSON strings" do
    for {type, marker, patterns} <- [
          {:float32, 0xF0,
           [
             {:nan, "NaN", <<0x7FC00000::little-32>>},
             {:infinity, "Infinity", <<0x7F800000::little-32>>},
             {:neg_infinity, "-Infinity", <<0xFF800000::little-32>>}
           ]},
          {:float64, 0xF1,
           [
             {:nan, "NaN", <<0x7FF8000000000000::little-64>>},
             {:infinity, "Infinity", <<0x7FF0000000000000::little-64>>},
             {:neg_infinity, "-Infinity", <<0xFFF0000000000000::little-64>>}
           ]}
        ],
        {value, json, bits} <- patterns do
      expected = "skir" <> <<marker>> <> bits
      assert Skir.encode!(type, value) == expected
      assert Skir.decode!(type, expected) == value
      assert Skir.to_json!(type, value) == json
      assert Skir.from_json!(type, json) == value
    end
  end
end
