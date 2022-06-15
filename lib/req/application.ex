defmodule Req.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Req.FinchSupervisor}
    ]

    with {:ok, _sup} <- Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, _} =
        DynamicSupervisor.start_child(
          Req.FinchSupervisor,
          {Finch, name: Req.FinchSupervisor.HTTP1, pools: %{default: [protocol: :http1]}}
        )

      {:ok, _} =
        DynamicSupervisor.start_child(
          Req.FinchSupervisor,
          {Finch, name: Req.FinchSupervisor.HTTP2, pools: %{default: [protocol: :http2]}}
        )
    end
  end
end
