defmodule Skir.WireTest do
  use ExUnit.Case, async: true

  test "every truncation of a string and each fixed-width number is rejected" do
    for prefix <- ["", "s", "sk", "ski"],
        do: assert({:error, %Skir.Error{reason: :invalid_json}} = Skir.decode(:int32, prefix))

    frames =
      [<<0xF3, 5, "hello">>] ++
        Enum.map(
          [
            {0xE8, 2},
            {0xE9, 4},
            {0xEA, 8},
            {0xEB, 1},
            {0xEC, 2},
            {0xED, 4},
            {0xEE, 8},
            {0xEF, 8},
            {0xF0, 4},
            {0xF1, 8}
          ],
          fn {marker, width} -> <<marker>> <> :binary.copy(<<0>>, width) end
        )

    for frame <- frames, n <- 0..(byte_size(frame) - 1) do
      assert {:error, %Skir.Error{reason: reason}} =
               Skir.decode(:int32, "skir" <> binary_part(frame, 0, n))

      assert reason in [:truncated, :invalid_length]
    end
  end
end
