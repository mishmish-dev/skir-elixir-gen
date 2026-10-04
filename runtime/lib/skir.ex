defmodule Skir do
  @moduledoc """
  Native Elixir serialization for generated Skir schemas.

  Non-bang functions return `{:ok, value}` or `{:error, %Skir.Error{}}`.
  Bang functions raise `Skir.Error`. `encode/3` produces framed Skir binary;
  `encode_json/3` produces a UTF-8 JSON string. `to_json/3` returns a JSON term.

  Unknown fields are discarded by default. With `unknown_fields: :preserve`, they
  round-trip in their original format; changing formats then returns an error.
  Enable preservation only for trusted data.
  No atom is created from untrusted input. SkirRPC lives under `Skir.RPC`.
  """
  alias Skir.{Binary, Codec, Error, Limits}

  @type primitive ::
          :bool | :int32 | :int64 | :hash64 | :float32 | :float64 | :timestamp | :string | :bytes
  @type type ::
          primitive()
          | {:optional, type()}
          | {:array, type()}
          | {:array, type(), String.t()}
          | {:record, module()}
  @type float_value :: float() | integer() | :nan | :infinity | :neg_infinity
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec default(type()) :: term()
  def default(type), do: Codec.default(type)

  @spec to_json(type(), term(), keyword()) :: result(term())
  def to_json(type, value, opts \\ []) do
    capture(fn ->
      ctx = Limits.context(opts, :dense, :encode)
      Limits.native_term(value, ctx)
      {result, _} = Codec.encode(type, value, ctx)
      Limits.json_term(result, ctx)
    end)
  end

  @spec from_json(type(), term(), keyword()) :: result(term())
  def from_json(type, value, opts \\ []) do
    capture(fn ->
      ctx = Limits.context(opts, :dense)
      Limits.json_term(value, ctx)
      Codec.decode(type, value, ctx)
    end)
  end

  @spec encode_json(type(), term(), keyword()) :: result(binary())
  def encode_json(type, value, opts \\ []) do
    capture(fn ->
      ctx = Limits.context(opts, :dense, :encode)
      Limits.native_term(value, ctx)
      {term, _} = Codec.encode(type, value, ctx)
      Limits.json_term(term, ctx)

      case Jason.encode(term) do
        {:ok, code} -> Limits.bytes(code, ctx)
        {:error, _} -> Error.fail(ctx, :invalid_json)
      end
    end)
  end

  @spec decode_json(type(), binary(), keyword()) :: result(term())
  def decode_json(type, code, opts \\ []) do
    capture(fn -> json_decode(type, code, Limits.context(opts, :dense)) end)
  end

  @spec encode(type(), term(), keyword()) :: result(binary())
  def encode(type, value, opts \\ []) do
    capture(fn ->
      ctx = Limits.context(opts, :binary, :encode)
      Limits.native_term(value, ctx)
      {node, _} = Codec.encode(type, value, ctx)
      body = Binary.encode_value(node, ctx)
      Limits.size(byte_size(body) + 4, ctx)
      "skir" <> body
    end)
  end

  @spec decode(type(), binary(), keyword()) :: result(term())
  def decode(type, bytes, opts \\ []) do
    capture(fn ->
      ctx = Limits.context(opts, :binary)
      Limits.bytes(bytes, ctx)

      case bytes do
        <<"skir", body::binary>> -> Codec.decode(type, Binary.decode_value(body, ctx), ctx)
        _ -> json_decode(type, bytes, %{ctx | format: :dense})
      end
    end)
  end

  for name <- [:to_json, :from_json, :encode_json, :decode_json, :encode, :decode] do
    bang = String.to_atom("#{name}!")
    @spec unquote(bang)(type(), term(), keyword()) :: term()
    def unquote(bang)(type, value, opts \\ []) do
      case unquote(name)(type, value, opts) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end
  end

  @doc "Build an index for a keyed array. Duplicate keys raise rather than silently overwriting."
  @spec index_by(list(), [atom()]) :: map()
  def index_by(values, path) when is_list(values) and is_list(path) do
    Enum.reduce(values, %{}, fn value, acc ->
      key =
        Enum.reduce(path, value, fn field, item ->
          case {field, item} do
            {:kind, {tag, _}} when is_atom(tag) -> tag
            {:kind, tag} when is_atom(tag) -> tag
            {field, map} when is_map(map) -> Map.fetch!(map, field)
            _ -> raise ArgumentError, "invalid keyed-array path"
          end
        end)

      if Map.has_key?(acc, key), do: raise(ArgumentError, "duplicate keyed-array key")
      Map.put(acc, key, value)
    end)
  end

  defp json_decode(type, code, ctx) do
    Limits.json_code(code, ctx)

    case Jason.decode(code) do
      {:ok, term} ->
        Limits.json_term(term, ctx)
        Codec.decode(type, term, ctx)

      {:error, _} ->
        Error.fail(ctx, :invalid_json)
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  rescue
    error in Error -> {:error, error}
  end
end
