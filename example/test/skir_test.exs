defmodule SkirTest do
  use ExUnit.Case, async: true
  alias Example.Protocol.UserSkir.{User, Event}
  alias Example.Protocol.CommonSkir.Address
  alias Example.Protocol.TreeSkir.{Node, Loop}

  test "native struct, nested default, and dense JSON round trip" do
    user = User.new(id: 42, name: "Alice")
    assert %User{address: %Address{city: ""}} = user
    assert User.to_json!(user) == [42, 0, "Alice"]
    assert User.encode_json!(user) == ~s([42,0,"Alice"])
    assert User.decode_json!(User.encode_json!(user)) == user
  end

  test "binary has public Skir framing and canonical field numbers" do
    user = User.new(id: 42, name: "Alice")
    expected = <<"skir", 0xF9, 42, 0, 0xF3, 5, "Alice">>
    assert User.encode!(user) == expected
    assert User.decode!(expected) == user
    assert User.decode!(User.encode_json!(user)) == user
  end

  test "readable output uses original schema field names" do
    user = User.new(id: 42, name: "Alice")
    assert User.to_json!(user, format: :readable) == %{"id" => 42, "name" => "Alice"}
    assert User.from_json!(%{"id" => 42, "name" => "Alice"}) == user
  end

  test "trailing defaults, removed fields and optional zero" do
    assert User.to_json!(User.default()) == []
    assert User.from_json!([42, "ignored removed data", "Alice"]) == User.new(id: 42, name: "Alice")
    assert Skir.from_json!({:optional, :string}, 0) == ""
    assert Skir.from_json!({:optional, :string}, nil) == nil
    assert User.from_json!([0, 0, 0, 0, 0]).nickname == ""
    assert User.from_json!([]).nickname == nil
  end

  test "plain and payload enums are idiomatic tagged values" do
    assert Event.to_json!(:connected) == 1
    assert Event.from_json!("connected") == :connected
    event = {:user_created, User.new(id: 42, name: "Alice")}
    assert Event.to_json!(event) == [2, [42, 0, "Alice"]]
    assert Event.decode!(Event.encode!(event)) == event
    assert Event.encode!({:message, "hi"}) == <<"skir", 0xF8, 5, 0xF3, 2, "hi">>
    assert Event.encode!({:user_created, User.default()}) == <<"skir", 0xFC, 0xF6>>
  end

  test "future dense fields survive old-reader edits" do
    future = [42, 0, "Alice", 0, nil, [], [], "", 0, 0, ["future", 123]]
    old = User.from_json!(future, unknown_fields: :preserve)
    assert User.to_json!(%{old | name: "Bob"}, unknown_fields: :preserve) == List.replace_at(future, 2, "Bob")
    assert {:error, %Skir.Error{reason: :unknown_format}} = User.encode(old, unknown_fields: :preserve)
    assert User.decode!(User.encode!(old, unknown_fields: :discard)).name == "Alice"
  end

  test "future enum variants preserve their payload without creating atoms" do
    unknown = Event.from_json!([19, ["new", 123]], unknown_fields: :preserve)
    assert {:unknown, %Skir.Unknown{format: :dense}} = unknown
    assert Event.to_json!(unknown, unknown_fields: :preserve) == [19, ["new", 123]]
    assert Event.from_json!(3) == :unknown
  end

  test "binary unknown fields preserve their exact bytes" do
    # Ten known slots, then an unknown byte-string slot. A noncanonical uint16 1
    # is retained exactly, rather than reconstructed as a one-byte integer.
    bytes = <<"skir", 0xFA, 11, 42, 0, 0xF3, 5, "Alice", 0, 0xFF, 0xF6, 0xF6,
              0xF4, 0, 0, 0xF5, 0xE8, 1, 0, 0xFE>>
    old = User.decode!(bytes, unknown_fields: :preserve)
    assert User.encode!(old, unknown_fields: :preserve) == bytes
    assert {:error, %Skir.Error{reason: :unknown_format}} = User.to_json(old, unknown_fields: :preserve)
  end

  test "recursive optional/list and hard-default types terminate" do
    tree = Node.new(value: "root", children: [Node.new(value: "leaf")])
    assert Node.decode!(Node.encode!(tree)) == tree
    assert Loop.default().next == :skir_default
    assert Loop.encode!(Loop.default()) == <<"skir", 0xF6>>
    assert Loop.decode!(<<"skir", 0xF6>>) == Loop.default()
  end

  test "constants and method descriptors are executable" do
    assert Example.Protocol.UserSkir.alice_const() == User.new(id: 42, name: "Alice")
    assert %Skir.Method{number: 12345, request: :int64, response: {:record, User}} =
      Example.Protocol.UserSkir.get_user_method()
  end

  test "validation errors identify the field path" do
    assert {:error, %Skir.Error{path: [:name]}} = User.encode_json(User.new(name: 3))
    assert {:error, %Skir.Error{path: [:pets, 0, :name]}} = User.from_json(%{"pets" => [%{"name" => true}]})
    assert_raise KeyError, fn -> User.new(not_a_field: 1) end
  end

  test "invalid inputs do not silently become default values" do
    for value <- [nil, true, "wrong", 123] do
      assert {:error, %Skir.Error{}} = User.from_json(value)
    end
    assert Event.from_json!([1, "payload added by a newer schema"]) == :connected
    assert {:error, %Skir.Error{}} = Skir.from_json(:bytes, "not base64!")
    assert {:error, %Skir.Error{}} = Skir.to_json(:string, <<0xFF>>)
  end

  test "resource limits and trailing binary data are rejected" do
    assert {:error, %Skir.Error{}} = User.decode(<<"skir", 0xFA, 0xE9, 255,255,255,127>>)
    assert {:error, %Skir.Error{reason: :trailing_bytes}} = User.decode(<<"skir", 0xF6, 0>>)
    assert {:error, %Skir.Error{}} = Skir.decode(:string, <<"skir", 0xF3, 2, "A">>)
    assert {:error, %Skir.Error{reason: :byte_limit}} = User.decode_json("[]", max_bytes: 1)
    assert {:error, %Skir.Error{reason: :depth_limit}} = User.decode_json("[[[[]]]]", max_depth: 2)
    assert {:error, %Skir.Error{reason: :collection_limit}} = Skir.from_json({:array, :int32}, [1,2,3], max_collection_length: 2)
  end

  test "non-finite float values remain explicit on the BEAM" do
    for {value, json} <- [{:nan, "NaN"}, {:infinity, "Infinity"}, {:neg_infinity, "-Infinity"}] do
      for type <- [:float32, :float64] do
        assert Skir.to_json!(type, value) == json
        assert Skir.from_json!(type, json) == value
        assert Skir.decode!(type, Skir.encode!(type, value)) == value
      end
    end
  end

  test "64-bit integer ranges do not lose precision" do
    for {type, values} <- [{:int64, [-9_223_372_036_854_775_808, -9_007_199_254_740_992, 9_007_199_254_740_991, 9_223_372_036_854_775_807]},
                            {:hash64, [0, 4_294_967_295, 9_007_199_254_740_992, 18_446_744_073_709_551_615]}] do
      for value <- values do
        assert Skir.from_json!(type, Skir.to_json!(type, value)) == value
        assert Skir.decode!(type, Skir.encode!(type, value)) == value
      end
    end
    assert Skir.to_json!(:int64, 9_007_199_254_740_992) == "9007199254740992"
    assert {:error, %Skir.Error{}} = Skir.to_json(:hash64, -1)
    assert {:error, %Skir.Error{}} = Skir.from_json(:int64, "9223372036854775808")
  end

  test "key index uses atoms from schema, not input, and rejects duplicates" do
    a = User.new(id: 1); b = User.new(id: 2)
    assert Skir.index_by([a,b], [:id]) == %{1 => a, 2 => b}
    assert_raise ArgumentError, fn -> Skir.index_by([a,a], [:id]) end
  end

  test "constant to payload variant evolution works in both directions" do
    assert Event.from_json!(5) == {:message, ""}
    assert Event.decode!(<<"skir", 5>>) == {:message, ""}
    assert Event.from_json!("message") == {:message, ""}
    assert Event.from_json!([1, "new payload"]) == :connected
    assert Event.decode!(<<"skir", 0xFB, 0xF2>>) == :connected
  end

  test "readable enums use the schema name and accept case-insensitive names" do
    assert Event.to_json!(:unknown, format: :readable) == "unknown"
    assert Event.from_json!("unknown") == :unknown
    assert Event.from_json!("CONNECTED") == :connected
  end

  test "timestamp bounds match the portable Skir range" do
    for t <- [-8_640_000_000_000_000, 8_640_000_000_000_000] do
      assert Skir.decode!(:timestamp, Skir.encode!(:timestamp, t)) == t
    end
    assert {:error, %Skir.Error{reason: :integer_range}} = Skir.encode(:timestamp, 8_640_000_000_000_001)
  end

  test "unknown data is discarded by default and preservation is opt-in" do
    assert Event.from_json!([77, [1]]) == :unknown
    old = User.from_json!([42,0,"Alice",0,nil,[],[],"",0,0,"future"])
    assert old.__skir_unknown_fields__ == %{}
    assert User.to_json!(old) == [42,0,"Alice"]
  end

  test "boolean readers accept the compatible integer representation" do
    assert Skir.from_json!(:bool, 2)
    refute Skir.from_json!(:bool, 0)
    assert Skir.decode!(:bool, <<"skir", 255 - 24>>)
    assert Skir.from_json!(:int32, true) == 1
  end

  test "preserved data remains preserved on encode without repeating the option" do
    future = [42,0,"Alice",0,nil,[],[],"",0,0,"future"]
    old = User.from_json!(future, unknown_fields: :preserve)
    assert User.to_json!(old) == future
    assert {:error, %Skir.Error{reason: :unknown_format}} = User.encode(old)
    assert User.to_json!(old, unknown_fields: :discard) == [42,0,"Alice"]
  end

end
