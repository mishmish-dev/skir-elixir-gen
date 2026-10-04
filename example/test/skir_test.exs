defmodule SkirTest do
  use ExUnit.Case, async: true
  alias Example.Protocol.UserSkir.{User, Event}
  alias Example.Protocol.TreeSkir.Loop

  test "generated result and raising codecs share the same wire contract" do
    user = User.new(id: 42, name: "Alice")

    for {encode, decode, expected} <- [
          {:to_json, :from_json, [42, 0, "Alice"]},
          {:encode_json, :decode_json, ~s([42,0,"Alice"])},
          {:encode, :decode, <<"skir", 0xF9, 42, 0, 0xF3, 5, "Alice">>}
        ] do
      assert apply(User, encode, [user]) == {:ok, expected}
      assert apply(User, decode, [expected]) == {:ok, user}
      bang_encode = String.to_existing_atom("#{encode}!")
      bang_decode = String.to_existing_atom("#{decode}!")
      assert apply(User, bang_encode, [user]) == expected
      assert apply(User, bang_decode, [expected]) == user
      assert {:error, %Skir.Error{path: [:name]}} = apply(User, encode, [User.new(name: 3)])
      assert_raise Skir.Error, fn -> apply(User, bang_encode, [User.new(name: 3)]) end
      assert {:error, %Skir.Error{}} = apply(User, decode, [true])
      assert_raise Skir.Error, fn -> apply(User, bang_decode, [true]) end
    end

    assert User.decode!(~s([42,0,"Alice"])) == user
    assert Loop.default().next == :skir_default
    assert Loop.encode!(Loop.default()) == <<"skir", 0xF6>>
  end

  test "preserved fields survive edits only in their original format" do
    for {format, future, expected} <- [
          {:dense, [42, 0, "Alice", 0, nil, [], [], "", 0, 0, "future"],
           [42, 0, "Bob", 0, nil, [], [], "", 0, 0, "future"]},
          {:readable, %{"id" => 42, "name" => "Alice", "future" => [1]},
           %{"id" => 42, "name" => "Bob", "future" => [1]}}
        ] do
      value = User.from_json!(future, unknown_fields: :preserve)
      assert User.to_json!(%{value | name: "Bob"}, format: format) == expected
      assert {:error, %Skir.Error{reason: :unknown_format}} = User.encode(value)
      assert User.to_json!(value, unknown_fields: :discard) == [42, 0, "Alice"]
      assert User.from_json!(future).__skir_unknown_fields__ == %{}
    end

    # Preserve a noncanonical uint16 in an unknown binary slot exactly.
    bytes =
      <<"skir", 0xFA, 11, 42, 0, 0xF3, 5, "Alice", 0, 0xFF, 0xF6, 0xF6, 0xF4, 0, 0, 0xE8, 1, 0>>

    value = User.decode!(bytes, unknown_fields: :preserve)
    assert User.encode!(value) == bytes
    assert {:error, %Skir.Error{reason: :unknown_format}} = User.to_json(value)
    assert User.decode!(User.encode!(value, unknown_fields: :discard)).id == 42
    unknown = Event.from_json!([77, [1]], unknown_fields: :preserve)
    assert Event.to_json!(unknown) == [77, [1]]
    assert Event.to_json!(unknown, unknown_fields: :discard) == 0
    name = "future_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    User.from_json!(%{name => 1}, unknown_fields: :preserve)
    Event.from_json!(%{"kind" => name, "value" => 1}, unknown_fields: :preserve)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "invalid structs, enums and unknown metadata return structured errors" do
    for {type, value, reason} <- [
          {User.type(), Map.delete(User.default(), :name), :missing_field},
          {User.type(), :unknown, :invalid_type},
          {User.type(), %{}, :invalid_type},
          {User.type(), %{User.default() | __skir_unknown_fields__: []}, :invalid_unknown_fields},
          {User.type(), %{User.default() | __skir_unknown_fields__: %{10 => :invalid}},
           :invalid_unknown_fields},
          {User.type(),
           %{
             User.default()
             | __skir_unknown_fields__: %{0 => %Skir.Unknown{format: :dense, value: 1}}
           }, :unknown_format},
          {Event.type(), [1], :invalid_type},
          {Event.type(), :missing, :invalid_enum},
          {Event.type(), {:connected, 1}, :invalid_enum},
          {Event.type(), :message, :invalid_enum},
          {{:array, :int32}, :bad, :invalid_type},
          {:bogus, 1, :invalid_type}
        ] do
      assert {:error, %Skir.Error{reason: ^reason}} = Skir.to_json(type, value)
    end

    for {type, value} <- [
          {User.type(), nil},
          {Event.type(), [-1, 0]},
          {{:array, :int32}, "bad"},
          {:bogus, 1}
        ] do
      assert {:error, %Skir.Error{}} = Skir.from_json(type, value)
    end

    for bytes <- [<<"skir", 0xF2>>, <<"skir", 0xF8, 0, 1>>, <<"skir", 0xFF>>] do
      assert {:error, %Skir.Error{reason: :invalid_enum}} = Event.decode(bytes)
    end

    for value <- [
          %{"name" => %Skir.Unknown{format: :dense, value: 1}},
          %{"pets" => [%{"name" => true}]}
        ] do
      assert {:error, %Skir.Error{}} = User.from_json(value)
    end

    assert {:error, %Skir.Error{path: [:pets, 0, :name]}} =
             User.from_json(%{"pets" => [%{"name" => true}]})
  end

  test "readable unknown fields cannot overwrite known fields or inject malformed wire" do
    for unknown <- [
          %{"name" => %Skir.Unknown{format: :readable, value: "spoof"}},
          %{10 => %Skir.Unknown{format: :readable, value: 1}}
        ] do
      assert {:error, %Skir.Error{reason: :unknown_format}} =
               User.to_json(%{User.default() | __skir_unknown_fields__: unknown},
                 format: :readable
               )
    end

    for raw <- [<<0xE8>>, <<0, 1>>, <<0xF3, 1, 255>>] do
      value = {:unknown, %Skir.Unknown{format: :binary, value: raw}}
      assert {:error, %Skir.Error{}} = Event.encode(value)
    end
  end

  test "public defaults and descriptors cover optional, array, keyed and recursive types" do
    for {type, expected} <- [
          {{:optional, :bool}, nil},
          {{:array, :int32}, []},
          {{:array, User.type(), "id"}, []},
          {User.type(), User.default()},
          {:bool, false}
        ] do
      assert Skir.default(type) == expected
    end

    descriptor = Skir.RPC.TypeDescriptor.to_json({:optional, User.type()}) |> JSON.decode!()

    assert descriptor["type"] == %{
             "kind" => "optional",
             "value" => %{"kind" => "record", "value" => "user.skir:User"}
           }

    for type <- [:bogus, {:array, :int32, nil}] do
      assert_raise ArgumentError, fn -> Skir.RPC.TypeDescriptor.to_map(type) end
    end

    assert_raise ArgumentError, fn -> Skir.index_by([1], [:id]) end
  end
end
