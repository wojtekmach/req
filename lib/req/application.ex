defmodule Req.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Req.Finch, name: Req.Finch},
      {DynamicSupervisor, strategy: :one_for_one, name: Req.FinchSupervisor},
      {Req.Test.Ownership, name: Req.Test.Ownership}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
