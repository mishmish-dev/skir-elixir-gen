defmodule Skir.RPC.HTTPClient do
  @moduledoc """
  Transport behaviour used by `Skir.RPC.ServiceClient`.

  Implement this behaviour to use Finch, Req, Tesla, Mint, or another HTTP
  stack. The built-in `Skir.RPC.HTTPClient.Httpc` adapter uses OTP `:httpc`.
  """

  @type header :: {String.t(), String.t()}
  @type response :: %{status: integer(), headers: [header()], body: binary()}

  @callback request(:get | :post, String.t(), [header()], binary(), keyword()) ::
              {:ok, response()} | {:error, term()}
end
