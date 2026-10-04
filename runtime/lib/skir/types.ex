defmodule Skir.Unknown do
  @moduledoc "Preserved data whose type is unknown to this schema version. Treat as opaque."
  @enforce_keys [:format, :value]
  defstruct [:format, :value]
  @type t :: %__MODULE__{format: :dense | :readable | :binary, value: term()}
end

defmodule Skir.Method do
  @moduledoc "Transport-independent Skir method metadata used by SkirRPC."
  @enforce_keys [:name, :number, :request, :response]
  defstruct [:name, :number, :doc, :request, :response]

  @type t :: %__MODULE__{
          name: String.t(),
          number: non_neg_integer(),
          doc: String.t() | nil,
          request: Skir.type(),
          response: Skir.type()
        }
end
