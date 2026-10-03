defmodule Skir.RPC.TypeDescriptor do
  @moduledoc "Builds the self-describing type JSON used by SkirRPC's `list` endpoint and Studio."

  @primitive_types [:bool, :int32, :int64, :hash64, :float32, :float64, :timestamp, :string, :bytes]

  @spec to_map(Skir.type()) :: map()
  def to_map(type) do
    records = collect(type, %{})
    root_id = case type do
      {:record, mod} -> mod.schema().key
      _ -> nil
    end

    sorted_records =
      records
      |> Map.values()
      |> Enum.sort_by(fn record -> {if(record["id"] == root_id, do: 0, else: 1), record["id"]} end)

    %{"type" => signature(type), "records" => sorted_records}
  end

  @spec to_json(Skir.type()) :: binary()
  def to_json(type), do: Jason.encode!(to_map(type), pretty: true)

  defp collect(type, acc) when type in @primitive_types, do: acc
  defp collect({:optional, inner}, acc), do: collect(inner, acc)
  defp collect({:array, inner}, acc), do: collect(inner, acc)
  defp collect({:array, inner, _key_extractor}, acc), do: collect(inner, acc)

  defp collect({:record, mod}, acc) when is_atom(mod) do
    schema = mod.schema()
    id = schema.key

    if Map.has_key?(acc, id) do
      acc
    else
      # Mark the record before descending so recursive schemas terminate.
      acc = Map.put(acc, id, nil)

      acc =
        Enum.reduce(schema.fields, acc, fn field, nested ->
          if field.type, do: collect(field.type, nested), else: nested
        end)

      Map.put(acc, id, record_descriptor(schema))
    end
  end

  defp collect(type, _acc), do: raise(ArgumentError, "invalid Skir type: #{inspect(type)}")

  defp record_descriptor(%{kind: :struct} = schema) do
    fields =
      schema.fields
      |> Enum.sort_by(& &1.number)
      |> Enum.map(fn field ->
        %{
          "name" => field.json_name,
          "number" => field.number,
          "type" => signature(field.type)
        }
        |> maybe_put_doc(Map.get(field, :doc, ""))
      end)

    %{"kind" => "struct", "id" => schema.key, "fields" => fields}
    |> maybe_put_doc(Map.get(schema, :doc, ""))
    |> maybe_put_removed(schema.removed)
  end

  defp record_descriptor(%{kind: :enum} = schema) do
    variants =
      schema.fields
      |> Enum.sort_by(& &1.number)
      |> Enum.map(fn field ->
        base = %{"name" => field.json_name, "number" => field.number}
        base = if field.type, do: Map.put(base, "type", signature(field.type)), else: base
        maybe_put_doc(base, Map.get(field, :doc, ""))
      end)

    %{"kind" => "enum", "id" => schema.key, "variants" => variants}
    |> maybe_put_doc(Map.get(schema, :doc, ""))
    |> maybe_put_removed(schema.removed)
  end

  defp signature(type) when type in @primitive_types,
    do: %{"kind" => "primitive", "value" => Atom.to_string(type)}

  defp signature({:optional, inner}), do: %{"kind" => "optional", "value" => signature(inner)}

  defp signature({:array, inner}),
    do: %{"kind" => "array", "value" => %{"item" => signature(inner)}}

  defp signature({:array, inner, key_extractor}) when is_binary(key_extractor) do
    value = %{"item" => signature(inner)}
    value = if key_extractor == "", do: value, else: Map.put(value, "key_extractor", key_extractor)
    %{"kind" => "array", "value" => value}
  end

  defp signature({:record, mod}) when is_atom(mod),
    do: %{"kind" => "record", "value" => mod.schema().key}

  defp signature(type), do: raise(ArgumentError, "invalid Skir type: #{inspect(type)}")

  defp maybe_put_doc(map, doc) when is_binary(doc) and doc != "", do: Map.put(map, "doc", doc)
  defp maybe_put_doc(map, _), do: map

  defp maybe_put_removed(map, removed) when is_list(removed) and removed != [],
    do: Map.put(map, "removed_numbers", Enum.sort(removed))

  defp maybe_put_removed(map, _), do: map
end
