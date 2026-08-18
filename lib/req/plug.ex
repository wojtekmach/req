if Code.ensure_loaded?(Plug) do
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
      # compatibility with Req 0.5.10 and below.
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

    defdelegate send_file(state, status, headers, path, offset, len), to: Plug.Adapters.Test.Conn

    def send_chunked(state, _status, _headers) do
      {:ok, "", %{state | chunks: []}}
    end

    def chunk(state, chunk) do
      chunk = IO.iodata_to_binary(chunk)
      body = IO.iodata_to_binary([state.chunks, chunk])
      {:ok, body, %{state | chunks: state.chunks ++ [chunk]}}
    end

    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn

    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn

    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn

    defdelegate get_peer_data(payload), to: Plug.Adapters.Test.Conn

    defdelegate get_http_protocol(payload), to: Plug.Adapters.Test.Conn
  end

  defmodule Req.Plug do
    @moduledoc """
    Runs the request against a plug instead of over the network.

    This is a Req _adapter_, used automatically when the `:plug` option is set.

    It requires [`:plug`](https://hexdocs.pm/plug) dependency:

        {:plug, "~> 1.0"}

    ## Request Options

      * `:plug` - the plug to run the request through. It can be one of:

          * A _function_ plug: a `fun(conn)` or `fun(conn, options)` function that takes a
            `Plug.Conn` and returns a `Plug.Conn`.

          * A _module_ plug: a `module` name or a `{module, options}` tuple.

        Req automatically calls `Plug.Conn.fetch_query_params/2` before your plug, so you can
        get query params using `conn.query_params`.

        Req also automatically parses request body using `Plug.Parsers` for JSON, urlencoded and
        multipart requests and you can access it with `conn.body_params`. The raw request body of
        the request is available by calling `Req.Test.raw_body/1` with the `conn` in your tests.

    ## Examples

    This step is particularly useful to test plugs:

        defmodule Echo do
          def call(conn, _) do
            "/" <> path = conn.request_path
            Plug.Conn.send_resp(conn, 200, path)
          end
        end

        test "echo" do
          assert Req.get!("http:///hello", plug: Echo).body == "hello"
        end

    You can define plugs as functions too:

        test "echo" do
          echo = fn conn ->
            "/" <> path = conn.request_path
            Plug.Conn.send_resp(conn, 200, path)
          end

          assert Req.get!("http:///hello", plug: echo).body == "hello"
        end

    which is particularly useful to create HTTP service stubs, similar to tools like
    [Bypass](https://github.com/PSPDFKit-labs/bypass).

    When testing JSON APIs, it's common to use the `Req.Test.json/2` helper:

        test "JSON" do
          plug = fn conn ->
            Req.Test.json(conn, %{message: "Hello, World!"})
          end

          resp = Req.get!(plug: plug)
          assert resp.status == 200
          assert resp.headers["content-type"] == ["application/json; charset=utf-8"]
          assert resp.body == %{"message" => "Hello, World!"}
        end

    You can simulate network errors by calling `Req.Test.transport_error/2`
    in your plugs:

        test "network issues" do
          plug = fn conn ->
            Req.Test.transport_error(conn, :timeout)
          end

          assert Req.get(plug: plug, retry: false) ==
                   {:error, %Req.TransportError{reason: :timeout}}
        end
    """

    def stream(request, acc, fun, state) when is_function(fun, 4) do
      resp = Req.Response.new(status: nil, body: nil)

      case prepare_body(request, acc) do
        {:ok, req_body, acc} ->
          stream(request, req_body, resp, acc, fun, state)

        # Halting req_body_fun closes the connection without reading the
        # response, so the plug is never called.
        {:halt, acc} ->
          resp = put_in(resp.request, request)
          {:halt, resp, acc, state}
      end
    end

    defp prepare_body(request, acc) do
      case request.body do
        iodata when is_binary(iodata) or is_list(iodata) ->
          {:ok, IO.iodata_to_binary(iodata), acc}

        nil ->
          {:ok, "", acc}

        req_body_fun when is_function(req_body_fun, 1) ->
          drain_req_body_fun(req_body_fun, acc, [])

        enumerable ->
          {:ok, enumerable |> Enum.to_list() |> IO.iodata_to_binary(), acc}
      end
    end

    defp stream(request, req_body, resp, acc, fun, state) do
      {request, conn} = call_conn(request, req_body)
      resp = put_in(resp.request, request)

      if exception = conn.private[:req_test_exception] do
        {{:error, exception}, resp, acc, state}
      else
        chunks = finish_conn(conn)

        case request.into do
          :self ->
            stream_into_self(conn, chunks, resp, acc, fun, state)

          _other ->
            events =
              [status: conn.status, headers: conn.resp_headers] ++
                for chunk <- chunks || [conn.resp_body], chunk != "", do: {:data, chunk}

            stream_events(events, resp, acc, state, fun)
        end
      end
    end

    defp stream_into_self(conn, chunks, resp, acc, fun, state) do
      events = [status: conn.status, headers: conn.resp_headers]

      case stream_events(events, resp, acc, state, fun) do
        {:ok, resp, acc, state} ->
          async = %Req.Response.Async{
            pid: self(),
            ref: make_ref(),
            stream_fun: &plug_parse_message/2,
            cancel_fun: &plug_cancel/1
          }

          for chunk <- chunks || [conn.resp_body], chunk != "" do
            send(self(), {async.ref, {:data, chunk}})
          end

          send(self(), {async.ref, :done})
          resp = put_in(resp.body, async)
          {:ok, resp, acc, state}

        result ->
          result
      end
    end

    defp stream_events([], resp, acc, state, _fun) do
      {:ok, resp, acc, state}
    end

    defp stream_events([event | events], resp, acc, state, fun) do
      resp =
        case event do
          {:status, status} ->
            put_in(resp.status, status)

          {:headers, headers} ->
            put_in(resp.headers, Req.Fields.new_without_normalize_with_duplicates(headers))

          _ ->
            resp
        end

      case fun.(event, resp, acc, state) do
        {:ok, resp, acc, state} ->
          stream_events(events, resp, acc, state, fun)

        result ->
          result
      end
    end

    defp call_conn(request, req_body) do
      plug = request.options.plug

      {req_body, request} =
        case Req.Request.get_header(request, "content-encoding") do
          [] ->
            {req_body, request}

          [encoding] when encoding in ["gzip", "x-gzip"] ->
            case Req.Gzip.decode(req_body) do
              {:ok, req_body} ->
                {req_body, Req.Request.delete_header(request, "content-encoding")}

              {:error, exception} ->
                raise exception
            end

          _other ->
            {req_body, request}
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
        |> Plug.Conn.fetch_query_params(validate_utf8: false)
        |> Plug.Conn.put_private(:req_private, request.private)
        |> Plug.Parsers.call(parser_opts)

      # Handle cases where the body isn't read with Plug.Parsers
      {mod, state} = conn.adapter
      state = %{state | body_read: true}
      conn = %{conn | adapter: {mod, state}}
      conn = call_plug(conn, plug)

      unless match?(%Plug.Conn{}, conn) do
        raise ArgumentError, "expected to return %Plug.Conn{}, got: #{inspect(conn)}"
      end

      {request, conn}
    end

    defp drain_req_body_fun(req_body_fun, acc, chunks) do
      case req_body_fun.(acc) do
        {:data, chunk, acc} ->
          drain_req_body_fun(req_body_fun, acc, [chunk | chunks])

        {:done, chunk, acc} ->
          {:ok, [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary(), acc}

        {:done, acc} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), acc}

        {:halt, acc} ->
          {:halt, acc}

        other ->
          raise "expected req_body_fun to return {:data, chunk, acc}, {:done, chunk, acc}, " <>
                  "{:done, acc}, or {:halt, acc}, got: #{inspect(other)}"
      end
    end

    defp finish_conn(conn) do
      # consume messages sent by Plug.Test adapter
      {Req.Plug.Adapter, %{ref: ref, chunks: chunks}} = conn.adapter

      if conn.state == :unset do
        raise """
        expected connection to have a response but no response was set/sent.

        Please verify that you are using Plug.Conn.send_resp/3 in your plug:

            Req.Test.stub(MyStub, fn conn ->
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

      chunks
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
else
  defmodule Req.Plug do
    @moduledoc false

    require Logger

    def stream(_request, _acc, _fun, _state) do
      missing_plug()
    end

    defp missing_plug do
      Logger.error("""
      Could not find plug dependency.

      Please add :plug to your dependencies:

          {:plug, "~> 1.0"}
      """)

      raise "missing plug dependency"
    end
  end
end
