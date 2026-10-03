defmodule Skir.Limits do
  @moduledoc false
  alias Skir.Error
  @defaults %{max_bytes: 4_194_304, max_depth: 64, max_collection_length: 100_000, max_nodes: 200_000,
              unknown_fields: :discard}
  @keys [:format | Map.keys(@defaults)]

  def context(opts, mode, direction \\ :decode) do
    policy = if direction == :encode, do: :preserve, else: :discard
    ctx = Map.merge(@defaults, %{format: mode, path: [], depth: 0, unknown_fields: policy})
    unless Keyword.keyword?(opts), do: Error.fail(ctx, :invalid_options, "expected keyword options")
    Enum.each(opts, fn {key, _} ->
      unless key in @keys, do: Error.fail(ctx, :invalid_options, "unknown option #{inspect(key)}")
    end)
    ctx = Map.merge(ctx, Map.new(opts))
    allowed = if mode == :binary, do: [:binary], else: [:dense, :readable]
    unless ctx.format in allowed, do: Error.fail(ctx, :invalid_options, "invalid format")
    unless ctx.unknown_fields in [:preserve, :discard], do: Error.fail(ctx, :invalid_options, "invalid unknown_fields policy")
    for key <- [:max_bytes, :max_depth, :max_collection_length, :max_nodes] do
      value = Map.fetch!(ctx, key)
      unless is_integer(value) and value > 0, do: Error.fail(ctx, :invalid_options, "limits must be positive integers")
    end
    ctx
  end

  def child(ctx, segment) do
    next = %{ctx | path: ctx.path ++ [segment], depth: ctx.depth + 1}
    if next.depth > ctx.max_depth, do: Error.fail(next, :depth_limit)
    next
  end
  def list_length(list, ctx), do: count_list(list, 0, ctx)
  defp count_list([], n, _), do: n
  defp count_list([_ | rest], n, ctx) when n < ctx.max_collection_length, do: count_list(rest, n + 1, ctx)
  defp count_list([_ | _], _, ctx), do: Error.fail(ctx, :collection_limit)
  defp count_list(_, _, ctx), do: Error.fail(ctx, :invalid_type, "expected proper list")

  def collection(n, ctx) do
    unless is_integer(n) and n >= 0 and n <= ctx.max_collection_length,
      do: Error.fail(ctx, :collection_limit)
    n
  end
  def bytes(value, ctx) do
    unless is_binary(value), do: Error.fail(ctx, :invalid_type, "expected binary")
    size(byte_size(value), ctx)
    value
  end
  def size(n, ctx) do
    if n > ctx.max_bytes, do: Error.fail(ctx, :byte_limit)
    n
  end

  # Bound nesting before asking the JSON library to allocate its decoded tree.
  # This is not a JSON parser: Jason still validates the complete syntax.
  def json_code(code, ctx) do
    bytes(code, ctx)
    scan(code, :normal, 0, ctx)
    :ok
  end
  defp scan(<<>>, _, _, _), do: :ok
  defp scan(<<_char, rest::binary>>, :escape, depth, ctx), do: scan(rest, :string, depth, ctx)
  defp scan(<<92, rest::binary>>, :string, depth, ctx), do: scan(rest, :escape, depth, ctx)
  defp scan(<<34, rest::binary>>, :string, depth, ctx), do: scan(rest, :normal, depth, ctx)
  defp scan(<<_char, rest::binary>>, :string, depth, ctx), do: scan(rest, :string, depth, ctx)
  defp scan(<<34, rest::binary>>, :normal, depth, ctx), do: scan(rest, :string, depth, ctx)
  defp scan(<<char, rest::binary>>, :normal, depth, ctx) when char in [91, 123] do
    if depth + 1 > ctx.max_depth, do: Error.fail(ctx, :depth_limit)
    scan(rest, :normal, depth + 1, ctx)
  end
  defp scan(<<char, rest::binary>>, :normal, depth, ctx) when char in [93, 125],
    do: scan(rest, :normal, depth - 1, ctx)
  defp scan(<<_, rest::binary>>, :normal, depth, ctx), do: scan(rest, :normal, depth, ctx)

  # Bound application-supplied trees before creating their wire representation.
  # Struct/module metadata is ignored; schema field validation happens in Codec.
  def native_term(term, ctx) do
    native_walk(term, ctx, ctx.max_nodes)
    term
  end
  defp native_walk(_, ctx, remaining) when remaining <= 0, do: Error.fail(ctx, :node_limit)
  defp native_walk(term, ctx, remaining) when is_list(term) do
    list_length(term, ctx)
    term |> Enum.with_index() |> Enum.reduce(remaining - 1, fn {v, i}, n -> native_walk(v, child(ctx, i), n) end)
  end
  defp native_walk(term, ctx, remaining) when is_map(term) do
    collection(map_size(term), ctx)
    Enum.reduce(term, remaining - 1, fn
      {:__struct__, _}, n -> n
      {key, value}, n -> native_walk(value, child(ctx, key), n)
    end)
  end
  defp native_walk(term, ctx, remaining) when is_tuple(term) do
    native_walk(Tuple.to_list(term), ctx, remaining)
  end
  defp native_walk(term, ctx, remaining) when is_binary(term) do
    bytes(term, ctx)
    remaining - 1
  end
  defp native_walk(_, _, remaining), do: remaining - 1

  def json_term(term, ctx) do
    walk(term, ctx, ctx.max_nodes)
    term
  end
  defp walk(_term, ctx, remaining) when remaining <= 0, do: Error.fail(ctx, :node_limit)
  defp walk(term, ctx, remaining) when is_list(term) do
    list_length(term, ctx)
    term |> Enum.with_index() |> Enum.reduce(remaining - 1, fn {v, i}, n -> walk(v, child(ctx, i), n) end)
  end
  defp walk(term, ctx, remaining) when is_map(term) and not is_struct(term) do
    collection(map_size(term), ctx)
    Enum.reduce(term, remaining - 1, fn {k, v}, n ->
      unless is_binary(k), do: Error.fail(ctx, :invalid_json, "JSON object keys must be strings")
      bytes(k, ctx)
      unless String.valid?(k), do: Error.fail(ctx, :invalid_utf8)
      walk(v, child(ctx, k), n)
    end)
  end
  defp walk(term, ctx, remaining) when is_binary(term) do
    bytes(term, ctx)
    unless String.valid?(term), do: Error.fail(ctx, :invalid_utf8)
    remaining - 1
  end
  defp walk(term, _ctx, remaining) when is_number(term) or is_boolean(term) or is_nil(term), do: remaining - 1
  defp walk(_, ctx, _), do: Error.fail(ctx, :invalid_json)
end
