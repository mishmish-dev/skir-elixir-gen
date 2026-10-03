defmodule Skir.RPC.Service do
  @moduledoc """
  In-process SkirRPC dispatcher.

  `handle_request/3` accepts the raw SkirRPC payload used by both POST bodies and
  decoded GET query strings, and returns a transport-neutral `RawResponse`.
  """

  alias Skir.RPC.{ErrorInfo, RawResponse, ServiceError, TypeDescriptor, UnknownError}

  @default_studio_url "https://cdn.jsdelivr.net/npm/skir-studio/dist/skir-studio-standalone.js"
  @default_max_request_bytes 4_194_304

  defstruct keep_unrecognized_values: false,
            can_send_unknown_error_message: nil,
            error_logger: nil,
            studio_app_js_url: @default_studio_url,
            max_request_bytes: @default_max_request_bytes,
            by_number: %{}

  @type handler :: (term(), term() -> {:ok, term()} | {:error, ServiceError.t() | UnknownError.t()})
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    service = %__MODULE__{
      can_send_unknown_error_message: fn _ -> false end,
      error_logger: fn _ -> :ok end
    }

    Enum.reduce(opts, service, fn
      {:keep_unrecognized_values, value}, acc -> set_keep_unrecognized_values(acc, value)
      {:can_send_unknown_error_message, value}, acc -> set_can_send_unknown_error_message(acc, value)
      {:error_logger, value}, acc -> set_error_logger(acc, value)
      {:studio_app_js_url, value}, acc -> set_studio_app_js_url(acc, value)
      {:max_request_bytes, value}, acc -> set_max_request_bytes(acc, value)
      {key, _value}, _acc -> raise ArgumentError, "unknown SkirRPC service option: #{inspect(key)}"
    end)
  end

  @spec add_method(t(), Skir.Method.t(), handler()) :: t()
  def add_method(%__MODULE__{} = service, %Skir.Method{} = method, handler) when is_function(handler, 2) do
    validate_method!(method)

    if Map.has_key?(service.by_number, method.number) do
      raise ArgumentError, "duplicate SkirRPC method number: #{method.number}"
    end

    entry = %{method: method, handler: handler}
    %{service | by_number: Map.put(service.by_number, method.number, entry)}
  end

  @spec set_keep_unrecognized_values(t(), boolean()) :: t()
  def set_keep_unrecognized_values(%__MODULE__{} = service, value) when is_boolean(value),
    do: %{service | keep_unrecognized_values: value}

  @spec set_can_send_unknown_error_message(t(), boolean() | (ErrorInfo.t() -> boolean())) :: t()
  def set_can_send_unknown_error_message(%__MODULE__{} = service, value) when is_boolean(value),
    do: %{service | can_send_unknown_error_message: fn _ -> value end}

  def set_can_send_unknown_error_message(%__MODULE__{} = service, fun) when is_function(fun, 1),
    do: %{service | can_send_unknown_error_message: fun}

  @spec set_error_logger(t(), (ErrorInfo.t() -> term())) :: t()
  def set_error_logger(%__MODULE__{} = service, fun) when is_function(fun, 1),
    do: %{service | error_logger: fun}

  @spec set_studio_app_js_url(t(), String.t()) :: t()
  def set_studio_app_js_url(%__MODULE__{} = service, url) when is_binary(url) and url != "",
    do: %{service | studio_app_js_url: url}

  @spec set_max_request_bytes(t(), pos_integer()) :: t()
  def set_max_request_bytes(%__MODULE__{} = service, value) when is_integer(value) and value > 0,
    do: %{service | max_request_bytes: value}

  @spec handle_request(t(), binary(), term()) :: RawResponse.t()
  def handle_request(%__MODULE__{} = service, body, request_metadata \\ nil) when is_binary(body) do
    cond do
      byte_size(body) > service.max_request_bytes ->
        text(413, "request body too large")

      not String.valid?(body) ->
        text(400, "invalid request body")

      body == "list" ->
        serve_list(service)

      body in ["", "studio"] ->
        serve_studio(service)

      json_request?(body) ->
        handle_json_request(service, body, request_metadata)

      true ->
        handle_colon_request(service, body, request_metadata)
    end
  end

  def handle_request(%__MODULE__{}, _body, _metadata), do: text(400, "invalid request body")

  defp json_request?(body), do: String.starts_with?(body, "{") or Regex.match?(~r/^\s/u, body)

  defp handle_json_request(service, body, metadata) do
    case decode_json_term(service, body) do
      {:error, _} ->
        text(400, "bad request: invalid JSON")

      {:ok, value} when not is_map(value) ->
        text(400, "bad request: expected JSON object")

      {:ok, value} ->
        with {:ok, method_value} <- fetch_json_field(value, "method"),
             {:ok, {name, number}} <- parse_json_method(method_value),
             {:ok, request_value} <- fetch_json_field(value, "request"),
             {:ok, entry} <- lookup_method(service, name, number) do
          invoke_entry_from_term(service, entry, request_value, :readable, metadata)
        else
          {:error, %RawResponse{} = response} -> response
        end
    end
  end

  defp fetch_json_field(value, "method") do
    case Map.fetch(value, "method") do
      {:ok, field} -> {:ok, field}
      :error -> {:error, text(400, "bad request: missing 'method' field in JSON")}
    end
  end

  defp fetch_json_field(value, "request") do
    case Map.fetch(value, "request") do
      {:ok, field} -> {:ok, field}
      :error -> {:error, text(400, "bad request: missing 'request' field in JSON")}
    end
  end

  defp parse_json_method(value) when is_binary(value), do: {:ok, {value, nil}}
  defp parse_json_method(value) when is_integer(value), do: {:ok, {"?", value}}
  defp parse_json_method(_), do: {:error, text(400, "bad request: 'method' field must be a string or an integer")}

  defp handle_colon_request(service, body, metadata) do
    case String.split(body, ":", parts: 4) do
      [name, number_string, format, request_json] ->
        with {:ok, number} <- parse_method_number(number_string),
             {:ok, entry} <- lookup_method(service, name, number),
             {:ok, request} <- decode_request_json(service, entry.method, request_json, format) do
          invoke_handler(service, entry, request, response_mode(format), metadata)
        else
          {:error, %RawResponse{} = response} -> response
        end

      _ ->
        text(400, "bad request: invalid request format")
    end
  end

  defp parse_method_number(""), do: {:ok, nil}
  defp parse_method_number(value) do
    if Regex.match?(~r/^-?[0-9]+$/, value) do
      {:ok, String.to_integer(value)}
    else
      {:error, text(400, "bad request: can't parse method number")}
    end
  end

  defp lookup_method(service, name, nil) do
    matches =
      service.by_number
      |> Map.values()
      |> Enum.filter(fn %{method: method} -> method.name == name end)

    case matches do
      [] -> {:error, text(400, "bad request: method not found: #{name}")}
      [entry] -> {:ok, entry}
      _ -> {:error, text(400, "bad request: method name '#{name}' is ambiguous; use method number instead")}
    end
  end

  defp lookup_method(service, name, number) do
    case Map.fetch(service.by_number, number) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, text(400, "bad request: method not found: #{name}; number: #{number}")}
    end
  end

  defp decode_request_json(service, method, request_json, format) do
    unknown_fields = if service.keep_unrecognized_values, do: :preserve, else: :discard

    case Skir.decode_json(method.request, request_json,
           format: response_mode(format),
           unknown_fields: unknown_fields,
           max_bytes: service.max_request_bytes
         ) do
      {:ok, request} -> {:ok, request}
      {:error, error} -> {:error, text(400, "bad request: can't parse JSON: " <> Exception.message(error))}
    end
  end

  defp decode_json_term(service, code) do
    try do
      ctx = Skir.Limits.context([max_bytes: service.max_request_bytes], :readable)
      Skir.Limits.json_code(code, ctx)

      case Jason.decode(code) do
        {:ok, value} ->
          Skir.Limits.json_term(value, ctx)
          {:ok, value}

        {:error, _} ->
          {:error, :invalid_json}
      end
    rescue
      _error in Skir.Error -> {:error, :invalid_json}
    end
  end

  defp invoke_entry_from_term(service, entry, request_value, mode, metadata) do
    unknown_fields = if service.keep_unrecognized_values, do: :preserve, else: :discard

    case Skir.from_json(entry.method.request, request_value,
           format: mode,
           unknown_fields: unknown_fields,
           max_bytes: service.max_request_bytes
         ) do
      {:ok, request} -> invoke_handler(service, entry, request, mode, metadata)
      {:error, error} -> text(400, "bad request: can't parse JSON: " <> Exception.message(error))
    end
  end

  defp invoke_handler(service, %{method: method, handler: handler}, request, mode, metadata) do
    try do
      case handler.(request, metadata) do
        {:ok, response} -> encode_success(method, response, mode)
        {:error, %ServiceError{} = error} -> controlled_error(service, method, error, metadata)
        {:error, %UnknownError{} = error} -> unknown_error(service, method, error.message, metadata, error, nil)
        other -> unknown_error(service, method, "invalid handler return: #{inspect(other)}", metadata, other, nil)
      end
    rescue
      error in ServiceError -> controlled_error(service, method, error, metadata)
      error -> unknown_error(service, method, Exception.message(error), metadata, error, __STACKTRACE__)
    catch
      kind, value -> unknown_error(service, method, "#{kind}: #{inspect(value)}", metadata, {kind, value}, __STACKTRACE__)
    end
  end

  defp encode_success(method, response, mode) do
    case Skir.encode_json(method.response, response, format: mode) do
      {:ok, json} -> %RawResponse{status_code: 200, content_type: "application/json", data: json}
      {:error, error} -> text(500, "server error: can't serialize response to JSON: " <> Exception.message(error))
    end
  end

  defp controlled_error(service, method, %ServiceError{} = error, metadata) do
    if Skir.RPC.http_error_code?(error.status_code) do
      info = %ErrorInfo{kind: :controlled, message: error.message, method_name: method.name,
                        request_metadata: metadata, error: error, stacktrace: nil}
      safe_log(service, info)
      text(error.status_code, error.message)
    else
      unknown_error(service, method, "invalid service error status: #{inspect(error.status_code)}", metadata, error, nil)
    end
  end

  defp unknown_error(service, method, message, metadata, error, stacktrace) do
    info = %ErrorInfo{kind: :unknown, message: message, method_name: method.name,
                      request_metadata: metadata, error: error, stacktrace: stacktrace}
    safe_log(service, info)

    exposed =
      try do
        service.can_send_unknown_error_message.(info) == true
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    if exposed, do: text(500, "server error: " <> message), else: text(500, "server error")
  end

  defp safe_log(service, info) do
    try do
      service.error_logger.(info)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp response_mode("readable"), do: :readable
  defp response_mode(_), do: :dense

  defp serve_list(service) do
    methods =
      service.by_number
      |> Map.values()
      |> Enum.map(& &1.method)
      |> Enum.sort_by(& &1.number)
      |> Enum.map(fn method ->
        %{
          "method" => method.name,
          "number" => method.number,
          "request" => TypeDescriptor.to_map(method.request),
          "response" => TypeDescriptor.to_map(method.response)
        }
        |> maybe_put_doc(method.doc || "")
      end)

    %RawResponse{status_code: 200, content_type: "application/json", data: Jason.encode!(%{"methods" => methods}, pretty: true)}
  end

  defp serve_studio(service) do
    url = html_escape(service.studio_app_js_url)

    html = """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <title>RPC Studio</title>
        <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🐙</text></svg>">
        <script src="#{url}"></script>
      </head>
      <body style="margin: 0; padding: 0;">
        <skir-studio-app></skir-studio-app>
      </body>
    </html>
    """
    |> String.trim_leading()

    %RawResponse{status_code: 200, content_type: "text/html; charset=utf-8", data: html}
  end

  defp text(status, message),
    do: %RawResponse{status_code: status, content_type: "text/plain; charset=utf-8", data: message}

  defp maybe_put_doc(map, doc) when is_binary(doc) and doc != "", do: Map.put(map, "doc", doc)
  defp maybe_put_doc(map, _), do: map

  defp validate_method!(%Skir.Method{name: name, number: number, doc: doc}) do
    unless is_binary(name) and name != "", do: raise(ArgumentError, "SkirRPC method name must be non-empty")
    unless is_integer(number) and number >= 0 and number <= 0xFFFFFFFF, do: raise(ArgumentError, "invalid SkirRPC method number")
    unless is_binary(doc || ""), do: raise(ArgumentError, "SkirRPC method doc must be a string")
    :ok
  end

  defp html_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
