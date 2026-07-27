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

    def run(request) do
      result =
        case request.body do
          iodata when is_binary(iodata) or is_list(iodata) ->
            {:ok, IO.iodata_to_binary(iodata), request}

          nil ->
            {:ok, "", request}

          req_body_fun when is_function(req_body_fun, 1) ->
            drain_req_body_fun(req_body_fun, request, [])

          enumerable ->
            {:ok, enumerable |> Enum.to_list() |> IO.iodata_to_binary(), request}
        end

      case result do
        {:ok, req_body, request} ->
          run(request, req_body)

        # Halting req_body_fun closes the connection without reading the
        # response, so the plug is never called.
        {:halt, request} ->
          {request, Req.Response.new(status: nil)}
      end
    end

    defp run(request, req_body) do
      plug = request.options.plug

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

      if exception = conn.private[:req_test_exception] do
        {request, exception}
      else
        handle_plug_result(conn, request)
      end
    end

    defp drain_req_body_fun(req_body_fun, request, chunks) do
      case req_body_fun.(request) do
        {:data, chunk, request} ->
          drain_req_body_fun(req_body_fun, request, [chunk | chunks])

        {:done, request} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), request}

        {:halt, request} ->
          {:halt, request}

        other ->
          raise "expected req_body_fun to return {:data, chunk, request}, {:done, request}, or {:halt, request}, got: #{inspect(other)}"
      end
    end

    defp handle_plug_result(conn, request) do
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

          Enum.reduce_while(
            chunks || [conn.resp_body],
            {request, response},
            fn chunk, acc ->
              case fun.({:data, chunk}, acc) do
                {:cont, acc} ->
                  {:cont, acc}

                {:halt, acc} ->
                  {:halt, acc}

                other ->
                  raise ArgumentError,
                        "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
              end
            end
          )

        :self ->
          async = %Req.Response.Async{
            pid: self(),
            ref: make_ref(),
            stream_fun: &plug_parse_message/2,
            cancel_fun: &plug_cancel/1
          }

          resp = Req.Response.new(status: conn.status, headers: conn.resp_headers, body: async)

          for chunk <- chunks || [conn.resp_body] do
            send(self(), {async.ref, {:data, chunk}})
          end

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

            acc =
              Enum.reduce(
                chunks || [conn.resp_body],
                acc,
                fn chunk, acc ->
                  collector.(acc, {:cont, chunk})
                end
              )

            acc = collector.(acc, :done)
            {request, %{response | body: acc}}
          else
            {request, put_in(response.body, conn.resp_body)}
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
else
  defmodule Req.Plug do
    @moduledoc false

    require Logger

    def run(_request) do
      Logger.error("""
      Could not find plug dependency.

      Please add :plug to your dependencies:

          {:plug, "~> 1.0"}
      """)

      raise "missing plug dependency"
    end
  end
end
