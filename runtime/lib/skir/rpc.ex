defmodule Skir.RPC do
  @moduledoc """
  Native SkirRPC support for Elixir.

  SkirRPC is a unary HTTP RPC protocol. Generated `Skir.Method` values can be
  registered with `Skir.RPC.Service` or invoked through `Skir.RPC.ServiceClient`.
  """

  @http_error_messages %{
    400 => "Bad Request", 401 => "Unauthorized", 402 => "Payment Required", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 406 => "Not Acceptable",
    407 => "Proxy Authentication Required", 408 => "Request Timeout", 409 => "Conflict",
    410 => "Gone", 411 => "Length Required", 412 => "Precondition Failed", 413 => "Content Too Large",
    414 => "URI Too Long", 415 => "Unsupported Media Type", 416 => "Range Not Satisfiable",
    417 => "Expectation Failed", 418 => "I'm a teapot", 421 => "Misdirected Request",
    422 => "Unprocessable Content", 423 => "Locked", 424 => "Failed Dependency", 425 => "Too Early",
    426 => "Upgrade Required", 428 => "Precondition Required", 429 => "Too Many Requests",
    431 => "Request Header Fields Too Large", 451 => "Unavailable For Legal Reasons",
    500 => "Internal Server Error", 501 => "Not Implemented", 502 => "Bad Gateway",
    503 => "Service Unavailable", 504 => "Gateway Timeout", 505 => "HTTP Version Not Supported",
    506 => "Variant Also Negotiates", 507 => "Insufficient Storage", 508 => "Loop Detected",
    510 => "Not Extended", 511 => "Network Authentication Required"
  }
  @http_error_codes Map.keys(@http_error_messages)


  @spec http_error_code?(integer()) :: boolean()
  def http_error_code?(code), do: code in @http_error_codes

  @doc "Creates a controlled SkirRPC error that is safe to return to the client."
  @spec error(integer(), String.t() | nil) :: Skir.RPC.ServiceError.t()
  def error(status_code, message \\ nil) when is_integer(status_code) and (is_binary(message) or is_nil(message)) do
    unless http_error_code?(status_code) do
      raise ArgumentError, "unsupported SkirRPC HTTP error code: #{inspect(status_code)}"
    end

    %Skir.RPC.ServiceError{status_code: status_code, message: message || Map.fetch!(@http_error_messages, status_code)}
  end

  @doc "Creates an internal SkirRPC error whose message is hidden unless the service explicitly permits exposure."
  @spec unknown_error(String.t()) :: Skir.RPC.UnknownError.t()
  def unknown_error(message) when is_binary(message), do: %Skir.RPC.UnknownError{message: message}
end

defmodule Skir.RPC.UnknownError do
  @moduledoc "An internal service error. Its message is hidden from callers by default."
  @enforce_keys [:message]
  defstruct [:message]

  @type t :: %__MODULE__{message: String.t()}
end

defmodule Skir.RPC.RawResponse do
  @moduledoc "Transport-neutral HTTP response returned by `Skir.RPC.Service`."
  @enforce_keys [:status_code, :content_type, :data]
  defstruct [:status_code, :content_type, :data]

  @type t :: %__MODULE__{
          status_code: non_neg_integer(),
          content_type: String.t(),
          data: binary()
        }
end

defmodule Skir.RPC.ServiceError do
  @moduledoc "A controlled RPC error whose status and message may be returned to callers."
  @enforce_keys [:status_code, :message]
  defexception [:status_code, :message]

  @type t :: %__MODULE__{status_code: integer(), message: String.t()}

  @impl Exception
  def exception(opts) do
    status_code = Keyword.fetch!(opts, :status_code)
    message = Keyword.get(opts, :message)
    Skir.RPC.error(status_code, message)
  end
end

defmodule Skir.RPC.RpcError do
  @moduledoc "SkirRPC client error. Status 0 denotes transport or response-decoding failure."
  @enforce_keys [:status_code, :message]
  defexception [:status_code, :message]

  @type t :: %__MODULE__{status_code: non_neg_integer(), message: String.t()}
end

defmodule Skir.RPC.ErrorInfo do
  @moduledoc "Context supplied to SkirRPC service error callbacks."
  @enforce_keys [:kind, :message, :method_name, :request_metadata]
  defstruct [:kind, :message, :method_name, :request_metadata, :error, :stacktrace]

  @type t :: %__MODULE__{
          kind: :controlled | :unknown,
          message: String.t(),
          method_name: String.t(),
          request_metadata: term(),
          error: term(),
          stacktrace: list() | nil
        }
end
