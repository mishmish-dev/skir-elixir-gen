defmodule Skir.Error do
  @moduledoc "A serialization error with a schema field/index path."
  defexception [:reason, :message, path: []]

  @type t :: %__MODULE__{
          reason: atom(),
          message: String.t(),
          path: [atom() | integer() | String.t()]
        }

  @doc false
  def fail(ctx, reason, detail \\ nil) do
    path = Map.get(ctx, :path, [])
    location = if path == [], do: "$", else: "$" <> Enum.map_join(path, "", &segment/1)
    message = location <> ": " <> (detail || Atom.to_string(reason))
    raise __MODULE__, reason: reason, path: path, message: message
  end

  defp segment(n) when is_integer(n), do: "[#{n}]"
  defp segment(n) when is_atom(n), do: "." <> Atom.to_string(n)
  defp segment(n), do: "[" <> inspect(n, limit: 5, printable_limit: 80) <> "]"
end
