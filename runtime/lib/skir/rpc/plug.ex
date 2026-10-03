defmodule Skir.RPC.Plug do
  @moduledoc """
  Plug/Phoenix adapter for `Skir.RPC.Service` with no hard dependency on Plug.

  Use it from Phoenix with `forward "/rpc", Skir.RPC.Plug, service: &MyApp.RPC.service/0`.
  Plug must be present in the host application.
  """

  @compile {:no_warn_undefined, Plug.Conn}

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(term(), keyword()) :: term()
  def call(conn, opts) do
    service = opts |> Keyword.fetch!(:service) |> resolve_service()
    metadata = metadata(conn, Keyword.get(opts, :metadata))

    case conn.method do
      "POST" ->
        case read_body(conn, service.max_request_bytes, <<>>) do
          {:ok, body, conn} -> send_raw(conn, Skir.RPC.Service.handle_request(service, body, metadata))
          {:too_large, conn} -> send_text(conn, 413, "request body too large")
          {:error, conn} -> send_text(conn, 400, "invalid request body")
        end

      "GET" ->
        payload = URI.decode(conn.query_string || "")
        send_raw(conn, Skir.RPC.Service.handle_request(service, payload, metadata))

      _ ->
        send_text(conn, 405, "method not allowed")
    end
  end

  defp resolve_service(%Skir.RPC.Service{} = service), do: service
  defp resolve_service(fun) when is_function(fun, 0), do: resolve_service(fun.())
  defp resolve_service({module, function, args}) when is_atom(module) and is_atom(function) and is_list(args),
    do: resolve_service(apply(module, function, args))
  defp resolve_service(other), do: raise(ArgumentError, "invalid Skir.RPC.Plug service: #{inspect(other)}")

  defp metadata(conn, nil), do: %{headers: conn.req_headers, method: conn.method, path: conn.request_path, remote_ip: conn.remote_ip}
  defp metadata(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp read_body(conn, limit, acc) do
    remaining = limit - byte_size(acc)
    if remaining <= 0, do: {:too_large, conn}, else: read_body_chunk(conn, limit, acc, remaining)
  end

  defp read_body_chunk(conn, limit, acc, remaining) do
    opts = [length: min(remaining + 1, 1_000_000), read_length: min(remaining + 1, 1_000_000)]

    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        data = acc <> chunk
        if byte_size(data) > limit, do: {:too_large, conn}, else: {:ok, data, conn}

      {:more, chunk, conn} ->
        data = acc <> chunk
        if byte_size(data) > limit, do: {:too_large, conn}, else: read_body(conn, limit, data)

      {:error, _reason} -> {:error, conn}
    end
  end

  defp send_raw(conn, raw) do
    conn
    |> Plug.Conn.put_resp_header("content-type", raw.content_type)
    |> Plug.Conn.send_resp(raw.status_code, raw.data)
  end

  defp send_text(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
    |> Plug.Conn.send_resp(status, data)
  end
end
