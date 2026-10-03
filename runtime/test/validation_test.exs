defmodule Skir.ValidationTest do
  use ExUnit.Case, async: true

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
end
