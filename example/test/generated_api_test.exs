defmodule Skir.GeneratedAPITest do
  use ExUnit.Case, async: true
  alias Example.Protocol.ApiSkir, as: API
  alias API.{Container, Directory, Entry, Field, RecA, RecB, Status, Value}
  alias Example.Protocol.UserSkir.User

  test "keyword and map construction, defaults and updates serialize independently" do
    original = Entry.new(user: User.new(%{id: 42, name: "Ada"}))
    updated = %{original | status: {:online, "available"}}
    assert Entry.to_json!(original) == [[42, 0, "Ada"]]
    assert Entry.to_json!(updated) == [[42, 0, "Ada"], [2, "available"]]
    assert Entry.decode!(Entry.encode!(updated)) == updated
    assert Entry.default().user == User.default()
    assert_raise KeyError, fn -> Entry.new(unknown: true) end
  end

  test "generated indexes follow nested fields and enum kinds" do
    offline = Entry.new(user: User.new(id: 1), status: :offline)
    online = Entry.new(user: User.new(id: 2), status: {:online, "here"})
    directory = Directory.new(by_user: [online, offline], by_status: [offline, online])
    decoded = Directory.decode!(Directory.encode!(directory))
    assert Directory.index_by_user(decoded) == %{1 => offline, 2 => online}
    assert Directory.index_by_status(decoded) == %{offline: offline, online: online}
    assert Directory.index_by_user(Directory.default()) == %{}
  end

  test "generated indexes reject duplicate nested keys and enum kinds" do
    first = Entry.new(user: User.new(id: 1), status: {:online, "first"})
    second = Entry.new(user: User.new(id: 1), status: {:online, "second"})

    assert_raise ArgumentError, fn ->
      Directory.index_by_user(Directory.new(by_user: [first, second]))
    end

    assert_raise ArgumentError, fn ->
      Directory.index_by_status(Directory.new(by_status: [first, second]))
    end
  end

  test "repeated nested record names resolve to the intended module" do
    value =
      Container.new(item: Container.Item.new(item: Container.Item.Item.new(value: "nested")))

    assert Container.to_json!(value) == [[["nested"]]]
    assert Container.decode!(Container.encode!(value)) == value
    assert Container.Item.Item.schema().key == "api.skir:Container.Item.Item"
  end

  test "recursive enum payloads and keyed fields round-trip" do
    value = {:object, [Field.new(name: "first", value: {:array, [{:text, "hello"}, :unknown]})]}
    assert Value.to_json!(value) == [3, [["first", [2, [[1, "hello"], 0]]]]]
    assert Value.decode!(Value.encode!(value)) == value
    assert Value.decode_json!(Value.encode_json!(value, format: :readable)) == value
    assert Status.from_json!(2) == {:online, ""}
  end

  test "mutually recursive defaults are finite and non-default children survive" do
    value = RecA.new(b: RecB.new(links: [nil, RecA.new(name: "leaf")]), name: "root")
    dense = [[[], [nil, [[], "leaf"]]], "root"]
    assert RecA.to_json!(value) == dense
    assert RecA.to_json!(RecA.decode!(RecA.encode!(value))) == dense
    assert RecA.to_json!(RecA.default()) == []
    assert RecB.to_json!(RecB.default()) == []
  end

  test "typed constants retain numeric precision, timestamp, bytes and enum payloads" do
    assert API.enabled_const() == true
    assert API.max_id_const() == 9_223_372_036_854_775_807
    assert API.max_hash_const() == 18_446_744_073_709_551_615
    assert API.pi_const() == 3.141592653589793
    assert API.start_const() == 1_703_984_028_000
    assert API.raw_bytes_const() == <<0, 1, 255>>
    assert API.nan_const() == :nan
    assert API.infinity_const() == :infinity
    assert Value.to_json!(API.greeting_const()) == [3, [["hello", [1, "world"]]]]
  end
end
