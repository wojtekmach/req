defmodule Req.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Supervisor.child_spec({Finch, name: Req.FinchHTTP1, pools: %{default: [protocol: :http1]}},
        id: Req.FinchHTTP1
      ),
      Supervisor.child_spec({Finch, name: Req.FinchHTTP2, pools: %{default: [protocol: :http2]}},
        id: Req.FinchHTTP2
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
