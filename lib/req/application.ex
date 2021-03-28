defmodule Req.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Finch, name: Req.Finch}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
