if Code.ensure_loaded?(Plug.Conn) do
  defmodule Req.Test.Adapter do
    @behaviour Plug.Conn.Adapter
    @moduledoc false

    ## Test helpers

    def conn(conn, method, uri, body) when is_binary(body) do
      conn = Plug.Adapters.Test.Conn.conn(conn, method, uri, body)
      {_, state} = conn.adapter
      state = Map.merge(state, %{body_read: false, has_more_body: false, raw_body: body})
      %{conn | adapter: {__MODULE__, state}}
    end

    ## Connection adapter
    def read_req_body(state, opts \\ []) do
      # We restore the body for the first automatic read for backwards
      # compatability with Req 0.5.10 and below.
      # TODO: remove in 0.6 if we allow opting out

      case Plug.Adapters.Test.Conn.read_req_body(state, opts) do
        {:more, body, state} ->
          {:more, body, %{state | has_more_body: true}}

        {:ok, body, %{has_more_body: true} = state} ->
          {:ok, body, state}

        {:ok, body, %{body_read: true} = state} ->
          {:ok, body, state}

        {:ok, body, state} ->
          {:ok, body, %{state | req_body: body}}
      end
    end

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn

    defdelegate send_file(state, status, headers, path, offset, length),
      to: Plug.Adapters.Test.Conn

    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate chunk(state, body), to: Plug.Adapters.Test.Conn
    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(payload), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(payload), to: Plug.Adapters.Test.Conn
  end
end
