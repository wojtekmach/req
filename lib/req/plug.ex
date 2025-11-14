if Code.ensure_loaded?(Plug.Conn) do
  defmodule Req.Plug do
    @moduledoc false
    require Logger

    def run(request) do
      plug = request.options.plug

      req_body =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            IO.iodata_to_binary(iodata)

          nil ->
            ""

          enumerable ->
            enumerable |> Enum.to_list() |> IO.iodata_to_binary()
        end

      {req_body, request} =
        case Req.Request.get_header(request, "content-encoding") do
          [] ->
            {req_body, request}

          encoding_headers ->
            case Req.Utils.decompress_with_encoding(encoding_headers, req_body) do
              %Req.DecompressError{} = error ->
                raise error

              {decompressed_body, _unknown_codecs} ->
                {decompressed_body, Req.Request.delete_header(request, "content-encoding")}
            end
        end

      req_headers = Req.Fields.get_list(request.headers)

      parser_opts =
        Plug.Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

      conn =
        Req.Plug.Adapter.conn(%Plug.Conn{}, request.method, request.url, req_body)
        |> Map.replace!(:req_headers, req_headers)
        |> Plug.Conn.fetch_query_params()
        |> Plug.Parsers.call(parser_opts)

      # Handle cases where the body isn't read with Plug.Parsers
      {mod, state} = conn.adapter
      state = %{state | body_read: true}
      conn = %{conn | adapter: {mod, state}}
      conn = call_plug(conn, plug)

      unless match?(%Plug.Conn{}, conn) do
        raise ArgumentError, "expected to return %Plug.Conn{}, got: #{inspect(conn)}"
      end

      if exception = conn.private[:req_test_exception] do
        {request, exception}
      else
        handle_plug_result(conn, request)
      end
    end

    defp handle_plug_result(conn, request) do
      # consume messages sent by Plug.Test adapter
      {_, %{ref: ref}} = conn.adapter

      if conn.state == :unset do
        raise """
        expected connection to have a response but no response was set/sent.

        Please verify that you are using Plug.Conn.send_resp/3 in your plug:

            Req.Test.stub(MyStub, fn conn, ->
              Plug.Conn.send_resp(conn, 200, "Hello, World!")
            end)
        """
      end

      receive do
        {^ref, {_status, _headers, _body}} -> :ok
      after
        0 -> :ok
      end

      receive do
        {:plug_conn, :sent} -> :ok
      after
        0 -> :ok
      end

      case request.into do
        nil ->
          response =
            Req.Response.new(
              status: conn.status,
              headers: conn.resp_headers,
              body: conn.resp_body
            )

          {request, response}

        fun when is_function(fun, 2) ->
          response =
            Req.Response.new(
              status: conn.status,
              headers: conn.resp_headers
            )

          case fun.({:data, conn.resp_body}, {request, response}) do
            {:cont, acc} ->
              acc

            {:halt, acc} ->
              acc

            other ->
              raise ArgumentError, "expected {:cont, acc}, got: #{inspect(other)}"
          end

        :self ->
          async = %Req.Response.Async{
            pid: self(),
            ref: make_ref(),
            stream_fun: &plug_parse_message/2,
            cancel_fun: &plug_cancel/1
          }

          resp = Req.Response.new(status: conn.status, headers: conn.resp_headers, body: async)
          send(self(), {async.ref, {:data, conn.resp_body}})
          send(self(), {async.ref, :done})
          {request, resp}

        collectable ->
          response =
            Req.Response.new(
              status: conn.status,
              headers: conn.resp_headers
            )

          if conn.status == 200 do
            {acc, collector} = Collectable.into(collectable)
            acc = collector.(acc, {:cont, conn.resp_body})
            acc = collector.(acc, :done)
            {request, %{response | body: acc}}
          else
            {request, %{response | body: conn.resp_body}}
          end
      end
    end

    defp plug_parse_message(ref, {ref, {:data, data}}) do
      {:ok, [data: data]}
    end

    defp plug_parse_message(ref, {ref, :done}) do
      {:ok, [:done]}
    end

    defp plug_parse_message(_, _) do
      :unknown
    end

    defp plug_cancel(ref) do
      plug_clean_responses(ref)
      :ok
    end

    defp plug_clean_responses(ref) do
      receive do
        {^ref, _} -> plug_clean_responses(ref)
      after
        0 -> :ok
      end
    end

    defp call_plug(conn, plug) when is_atom(plug) do
      plug.call(conn, [])
    end

    defp call_plug(conn, {plug, options}) when is_atom(plug) do
      plug.call(conn, plug.init(options))
    end

    defp call_plug(conn, plug) when is_function(plug, 1) do
      plug.(conn)
    end

    defp call_plug(conn, plug) when is_function(plug, 2) do
      plug.(conn, [])
    end
  end

  defmodule Req.Plug.Adapter do
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
else
  defmodule Req.Plug do
    @moduledoc false

    def run(_request) do
      require Logger

      Logger.error("""
      Could not find plug dependency.

      Please add :plug to your dependencies:

          {:plug, "~> 1.0"}
      """)

      raise "missing plug dependency"
    end
  end
end
