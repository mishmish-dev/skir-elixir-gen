defmodule Skir.RPC.ServiceClient do
  @moduledoc "HTTP client for unary SkirRPC methods."

  alias Skir.RPC.RpcError

  @enforce_keys [:service_url, :headers, :transport]
  defstruct [:service_url, :headers, :transport, :transport_opts]

  @type header :: {String.t(), String.t()}
  @type http_method :: :get | :post
  @type t :: %__MODULE__{
          service_url: String.t(),
          headers: [header()],
          transport: module() | function(),
          transport_opts: keyword()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(service_url, opts \\ [])

  def new(service_url, opts) when is_binary(service_url) and is_list(opts) do
    cond do
      String.contains?(service_url, "?") ->
        {:error, "service URL must not contain a query string"}

      true ->
        uri = URI.parse(service_url)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
          headers = normalize_headers(Keyword.get(opts, :headers, []))
          transport = Keyword.get(opts, :transport, Skir.RPC.HTTPClient.Httpc)
          transport_opts = Keyword.get(opts, :transport_opts, [])

          {:ok,
           %__MODULE__{
             service_url: service_url,
             headers: headers,
             transport: transport,
             transport_opts: transport_opts
           }}
        else
          {:error, "service URL is not a valid URL: #{service_url}"}
        end
    end
  rescue
    ArgumentError -> {:error, "invalid ServiceClient options"}
  end

  def new(_service_url, _opts), do: {:error, "service URL is not a valid URL"}

  @spec new!(String.t(), keyword()) :: t()
  def new!(service_url, opts \\ []) do
    case new(service_url, opts) do
      {:ok, client} -> client
      {:error, message} -> raise ArgumentError, message
    end
  end

  @spec with_default_header(t(), String.t(), String.t()) :: t()
  def with_default_header(%__MODULE__{} = client, key, value)
      when is_binary(key) and is_binary(value) do
    %{client | headers: put_header(client.headers, key, value)}
  end

  @spec invoke(t(), Skir.Method.t(), term(), keyword()) :: {:ok, term()} | {:error, RpcError.t()}
  def invoke(%__MODULE__{} = client, %Skir.Method{} = method, request, opts \\ [])
      when is_list(opts) do
    with {:ok, request_json} <- encode_request(method, request),
         headers <- merged_headers(client.headers, Keyword.get(opts, :headers, [])),
         body = method.name <> ":" <> Integer.to_string(method.number) <> "::" <> request_json,
         {:ok, response} <- send_request(client, headers, body, opts) do
      handle_response(method, response)
    end
  rescue
    error in ArgumentError -> {:error, rpc_error(0, Exception.message(error))}
  end

  @spec invoke!(t(), Skir.Method.t(), term(), keyword()) :: term()
  def invoke!(client, method, request, opts \\ []) do
    case invoke(client, method, request, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  defp encode_request(method, request) do
    case Skir.encode_json(method.request, request) do
      {:ok, json} ->
        {:ok, json}

      {:error, error} ->
        {:error, rpc_error(0, "failed to encode request: " <> Exception.message(error))}
    end
  end

  defp send_request(client, headers, body, opts) do
    http_method = Keyword.get(opts, :http_method, :post)

    unless http_method in [:get, :post],
      do: raise(ArgumentError, "http_method must be :get or :post")

    transport_opts =
      Keyword.merge(client.transport_opts, Keyword.drop(opts, [:headers, :http_method]))

    {url, request_headers, request_body} =
      case http_method do
        :post ->
          {client.service_url, put_header(headers, "content-type", "text/plain; charset=utf-8"),
           body}

        :get ->
          # TypeScript protects existing percent escapes before assigning URL.search.
          escaped = String.replace(body, "%", "%25")
          query = URI.encode(escaped, &get_query_char?/1)
          {client.service_url <> "?" <> query, headers, ""}
      end

    result =
      cond do
        is_function(client.transport, 5) ->
          client.transport.(http_method, url, request_headers, request_body, transport_opts)

        is_atom(client.transport) ->
          client.transport.request(
            http_method,
            url,
            request_headers,
            request_body,
            transport_opts
          )

        true ->
          {:error, :invalid_transport}
      end

    case result do
      {:ok, %{status: status, headers: response_headers, body: response_body}}
      when is_integer(status) and is_list(response_headers) and is_binary(response_body) ->
        {:ok, %{status: status, headers: response_headers, body: response_body}}

      {:error, reason} ->
        {:error, rpc_error(0, "Request failed: #{format_reason(reason)}")}

      other ->
        {:error, rpc_error(0, "Request failed: #{format_reason(other)}")}
    end
  rescue
    error -> {:error, rpc_error(0, "Request failed: #{Exception.message(error)}")}
  catch
    kind, value -> {:error, rpc_error(0, "Request failed: #{kind}: #{inspect(value)}")}
  end

  defp handle_response(method, %{status: status, headers: _headers, body: body})
       when status >= 200 and status < 300 do
    case Skir.decode_json(method.response, body, unknown_fields: :preserve) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        {:error, rpc_error(0, "failed to decode response: " <> Exception.message(error))}
    end
  end

  defp handle_response(_method, %{status: status, headers: headers, body: body}) do
    suffix = if text_plain?(headers), do: ": " <> body, else: ""
    {:error, rpc_error(status, "HTTP status #{status}" <> suffix)}
  end

  defp text_plain?(headers) do
    headers
    |> Enum.find_value(false, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type",
          do: Regex.match?(~r/text\/plain\b/, String.downcase(value)),
          else: false

      _ ->
        false
    end)
  end

  # Match WHATWG's special-query percent-encode set used by TypeScript's
  # `URL.search = ...`: encode controls/non-ASCII plus space, double quote,
  # hash, single quote, less-than and greater-than. Percent is intentionally
  # preserved because it has already been doubled above.
  defp get_query_char?(char)
       when char >= 0x21 and char <= 0x7E and char not in [?", ?#, ?', ?<, ?>],
       do: true

  defp get_query_char?(_char), do: false

  defp merged_headers(defaults, additions) do
    Enum.reduce(normalize_headers(additions), defaults, fn {key, value}, acc ->
      put_header(acc, key, value)
    end)
  end

  defp put_header(headers, key, value) do
    down = String.downcase(key)
    filtered = Enum.reject(headers, fn {existing, _} -> String.downcase(existing) == down end)
    filtered ++ [{key, value}]
  end

  defp normalize_headers(headers) when is_map(headers),
    do: normalize_headers(Map.to_list(headers))

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {key, value} when is_binary(key) and is_binary(value) -> {key, value}
      other -> raise ArgumentError, "invalid HTTP header: #{inspect(other)}"
    end)
  end

  defp normalize_headers(other),
    do: raise(ArgumentError, "invalid HTTP headers: #{inspect(other)}")

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
  defp rpc_error(status, message), do: %RpcError{status_code: status, message: message}
end
