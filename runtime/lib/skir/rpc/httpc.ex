defmodule Skir.RPC.HTTPClient.Httpc do
  @moduledoc false
  @behaviour Skir.RPC.HTTPClient

  @spec request(:get | :post, String.t(), [{String.t(), String.t()}], binary(), keyword()) ::
          {:ok, %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}} | {:error, term()}
  def request(method, url, headers, body, opts) when method in [:get, :post] do
    with :ok <- ensure_started(:inets),
         :ok <- ensure_started(:ssl) do
      timeout = Keyword.get(opts, :timeout, 30_000)
      connect_timeout = Keyword.get(opts, :connect_timeout, min(timeout, 10_000))

      http_options = [timeout: timeout, connect_timeout: connect_timeout]
      http_options = if String.starts_with?(url, "https://"), do: Keyword.put(http_options, :ssl, ssl_options()), else: http_options

      request_headers =
        headers
        |> Enum.reject(fn {key, _} -> method == :post and String.downcase(key) == "content-type" end)
        |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

      request =
        case method do
          :post -> {String.to_charlist(url), request_headers, ~c"text/plain; charset=utf-8", body}
          :get -> {String.to_charlist(url), request_headers}
        end

      case :httpc.request(method, request, http_options, body_format: :binary) do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          {:ok, %{status: status, headers: Enum.map(response_headers, &normalize_header/1), body: IO.iodata_to_binary(response_body)}}

        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    error -> {:error, error}
  catch
    kind, value -> {:error, {kind, value}}
  end

  def request(method, _url, _headers, _body, _opts), do: {:error, {:unsupported_method, method}}

  defp ensure_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_header({key, value}), do: {to_string(key), to_string(value)}

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
