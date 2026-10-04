defmodule Skir.WireTest do
  use ExUnit.Case, async: true

  test "every truncation of a string and each fixed-width number is rejected" do
    for prefix <- ["", "s", "sk", "ski"],
      do: assert({:error, %Skir.Error{reason: :invalid_json}} = Skir.decode(:int32, prefix))
    frames = [<<0xf3, 5, "hello">>] ++ Enum.map([
      {0xe8, 2}, {0xe9, 4}, {0xea, 8}, {0xeb, 1}, {0xec, 2}, {0xed, 4}, {0xee, 8},
      {0xef, 8}, {0xf0, 4}, {0xf1, 8}
    ], fn {marker, width} -> <<marker>> <> :binary.copy(<<0>>, width) end)
    for frame <- frames, n <- 0..(byte_size(frame) - 1) do
      assert {:error, %Skir.Error{reason: reason}} = Skir.decode(:int32, "skir" <> binary_part(frame, 0, n))
      assert reason in [:truncated, :invalid_length]
    end
  end
end
