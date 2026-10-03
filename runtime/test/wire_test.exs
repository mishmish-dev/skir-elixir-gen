defmodule Skir.WireTest do
  use ExUnit.Case, async: true
  @vectors [
    {:int32, 0, <<0>>}, {:int32, 231, <<231>>}, {:int32, 232, <<0xE8,232,0>>},
    {:int32, 65535, <<0xE8,255,255>>}, {:int32, 65536, <<0xE9,0,0,1,0>>},
    {:int32, -1, <<0xEB,255>>}, {:int32, -256, <<0xEB,0>>},
    {:int32, -257, <<0xEC,255,254>>}, {:int32, -65536, <<0xEC,0,0>>},
    {:int32, -65537, <<0xED,255,255,254,255>>},
    {:int64, 2_147_483_648, <<0xEE,0,0,0,128,0,0,0,0>>},
    {:hash64, 4_294_967_296, <<0xEA,0,0,0,0,1,0,0,0>>},
    {:float32, 1.5, <<0xF0,0,0,192,63>>},
    {:float64, 1.5, <<0xF1,0,0,0,0,0,0,248,63>>},
    {:timestamp, 1, <<0xEF,1,0,0,0,0,0,0,0>>},
    {:string, "", <<0xF2>>}, {:string, "Hi", <<0xF3,2,"Hi">>},
    {:bytes, <<>>, <<0xF4>>}, {:bytes, <<0,255>>, <<0xF5,2,0,255>>},
    {:bool, true, <<1>>}, {:bool, false, <<0>>},
    {{:optional,:string}, nil, <<0xFF>>},
    {{:array,:int32}, [1,2,3,4], <<0xFA,4,1,2,3,4>>}
  ]
  for {{type, value, bytes}, index} <- Enum.with_index(@vectors) do
    test "documented wire vector #{index}" do
      type = unquote(Macro.escape(type))
      value = unquote(Macro.escape(value))
      bytes = unquote(Macro.escape(bytes))
      assert Skir.encode!(type, value) == "skir" <> bytes
      assert Skir.decode!(type, "skir" <> bytes) == value
    end
  end

  test "every truncation of a framed string is rejected" do
    value = Skir.encode!(:string, "hello 🌍")
    for n <- 0..(byte_size(value)-1) do
      assert {:error, %Skir.Error{}} = Skir.decode(:string, binary_part(value, 0, n))
    end
  end
end
