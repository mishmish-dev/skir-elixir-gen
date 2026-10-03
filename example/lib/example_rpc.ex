defmodule Example.RPC do
  @moduledoc "Example native Elixir SkirRPC service built from generated method helpers."

  alias Example.Protocol.UserSkir
  alias Example.Protocol.UserSkir.User
  alias Skir.RPC.Service

  @spec service() :: Service.t()
  def service do
    Service.new()
    |> UserSkir.add_get_user(&get_user/2)
  end

  @spec get_user(integer(), term()) :: {:ok, User.t()}
  def get_user(id, _metadata), do: {:ok, %User{id: id, name: "Alice"}}
end
