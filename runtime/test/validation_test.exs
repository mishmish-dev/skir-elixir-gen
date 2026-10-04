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
      Skir.from_json({:array, {:array, :int32}}, [[1,2],[3,4]], max_nodes: 4)
  end

  test "JSON object keys must be UTF-8 and cannot create atoms" do
    assert {:error, %Skir.Error{reason: :invalid_utf8}} = Skir.from_json(:int32, %{<<255>> => 1})
    assert {:error, %Skir.Error{reason: :invalid_json}} = Skir.from_json(:int32, %{arbitrary_atom: 1})
  end

  test "unknown options and invalid limits are rejected" do
    for opts <- [[max_depth: 0], [max_bytes: -1], [unknown_fields: :invent], [surprise: 1]] do
      assert {:error, %Skir.Error{reason: :invalid_options}} = Skir.encode(:int32, 1, opts)
    end
  end

  test "numeric reader compatibility retains strict ranges and complete string parsing" do
    assert {:error, %Skir.Error{reason: :integer_range}} = Skir.from_json(:int32, "2147483648")
    assert {:error, %Skir.Error{reason: :integer_range}} = Skir.from_json(:timestamp, "8640000000000001")
    assert {:error, %Skir.Error{reason: :integer_range}} = Skir.from_json(:hash64, -1.5)
    for value <- ["2x", " 2", "02", "1.5", String.duplicate("9", 100)] do
      assert {:error, %Skir.Error{}} = Skir.from_json(:int32, value)
    end
    assert {:error, %Skir.Error{reason: :invalid_type}} = Skir.to_json(:int32, 2.0)
    assert {:error, %Skir.Error{reason: :invalid_type}} = Skir.decode(:int32, <<"skir", 0xf0, 0, 0, 0xc0, 0x7f>>)
  end
end
