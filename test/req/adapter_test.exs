defmodule Req.AdapterTest do
  use Req.Case, async: true

  @adapter Req.Case.adapter()

  describe "run" do
    @tag :transport
    test ":inet6" do
      %{url: ipv4_url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      %{url: ipv6_url} =
        start_http_server(
          fn conn ->
            Plug.Conn.send_resp(conn, 200, "ok")
          end,
          [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]
        )

      assert Req.request!(adapter: @adapter, url: ipv4_url).body == "ok"
      assert Req.request!(adapter: @adapter, url: ipv4_url, inet6: true).body == "ok"
      assert Req.request!(adapter: @adapter, url: ipv6_url, inet6: true).body == "ok"

      ipv6_url = %{ipv6_url | host: "::1"}
      assert Req.request!(adapter: @adapter, url: ipv6_url).body == "ok"
    end

    @tag :transport
    test ":unix_socket" do
      socket_path = Path.join(System.tmp_dir!(), "req-#{System.unique_integer([:positive])}.sock")
      on_exit(fn -> File.rm(socket_path) end)

      start_http_server(
        fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end,
        ip: {:local, socket_path},
        port: 0
      )

      assert Req.request!(adapter: @adapter, url: "http://localhost", unix_socket: socket_path).body ==
               "ok"
    end

    @tag :transport
    test "connect_options[:timeout]" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.request!(adapter: @adapter, url: url, connect_options: [timeout: 5000]).body ==
               "ok"
    end

    @tag :capture_log
    @tag :http2
    @tag :transport
    test "connect_options[:protocols]", %{test: test} do
      %{url: url} =
        start_http_server(fn conn ->
          assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      # Finch H2 pool re-connects forever so start custom pool under test supervisor.
      start_supervised!({Req.Finch, name: test, connect_options: [protocols: [:http2]]})

      req = Req.new(adapter: @adapter, url: url, finch: test, retry_delay: 100)

      assert Req.request!(req).body == "ok"
    end

    @tag :transport
    test "connect_options[:transport_opts]" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req =
        Req.new(
          adapter: @adapter,
          url: %{url | scheme: "https"},
          connect_options: [transport_opts: [cacertfile: "bad.pem"]]
        )

      assert_raise File.Error, ~r/could not read file "bad.pem"/, fn ->
        Req.request!(req)
      end
    end

    @tag :transport
    test "Req.HTTPError" do
      %{url: url} =
        start_tcp_server(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 bad\r\ncontent-length: 0\r\n\r\n")
        end)

      req = Req.new(adapter: @adapter, url: url, retry: false)
      {:error, %Req.HTTPError{protocol: :http1, reason: :invalid_status_line}} = Req.request(req)
    end

    @tag :transport
    test "Req.TransportError" do
      req = Req.new(adapter: @adapter, url: "http://localhost:9999", retry: false)
      {:error, %Req.TransportError{reason: :econnrefused}} = Req.request(req)
    end

    @tag :transport
    test "Req.TransportError with :inet6" do
      req = Req.new(adapter: @adapter, url: "http://localhost:9999", inet6: true, retry: false)
      {:error, %Req.TransportError{reason: :econnrefused}} = Req.request(req)
    end

    # TODO: implement :receive_timeout in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    @tag :transport
    test ":receive_timeout" do
      pid = self()

      %{url: url} =
        start_tcp_server(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)
          send(pid, :ping)
          body = "ok"

          Process.sleep(1000)

          data = """
          HTTP/1.1 200 OK
          content-length: #{byte_size(body)}

          #{body}
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      req = Req.new(adapter: @adapter, url: url, receive_timeout: 50, retry: false)
      assert {:error, %Req.TransportError{reason: :timeout}} = Req.request(req)
      assert_received :ping
    end

    # TODO: implement :request_timeout in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    @tag :transport
    test ":request_timeout" do
      pid = self()

      %{url: url} =
        start_tcp_server(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)
          send(pid, :ping)
          body = "ok"
          resp_header = "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n"
          :ok = :gen_tcp.send(socket, resp_header)
          Process.sleep(100)
          :ok = :gen_tcp.send(socket, body)
        end)

      req = Req.new(adapter: @adapter, url: url, request_timeout: 0, retry: false)
      assert {:error, %Req.TransportError{reason: :timeout}} = Req.request(req)
      assert_received :ping
    end

    # TODO: implement req_body_fun support in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    test "body: req_body_fun succeeded" do
      %{req: req} =
        serve(fn conn ->
          assert {:ok, "foobar", conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req_body_fun = fn
        %Req.Request{private: %{phase: :bar}} = request ->
          request = Req.Request.put_private(request, :phase, :done)
          {:data, "bar", request}

        %Req.Request{private: %{phase: :done}} = request ->
          {:done, request}

        %Req.Request{} = request ->
          request = Req.Request.put_private(request, :phase, :bar)
          {:data, "foo", request}
      end

      {req, resp} = Req.run!(req, method: :post, body: req_body_fun)
      assert req.private[:phase] == :done
      assert resp.status == 200
      assert resp.body == "ok"
    end

    # TODO: implement req_body_fun support in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    test "body: req_body_fun halted" do
      %{req: req} =
        serve(fn conn ->
          assert {:ok, "", conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req_body_fun = fn
        %Req.Request{} = request ->
          request = Req.Request.put_private(request, :phase, :halted)
          {:halt, request}
      end

      {req, resp} = Req.run!(req, method: :post, body: req_body_fun)
      assert req.private[:phase] == :halted
      assert resp.status == nil
      assert resp.body == ""
    end

    # TODO: implement req_body_fun support in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    test "body: req_body_fun errored" do
      %{req: req} =
        serve(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req_body_fun = fn %Req.Request{} -> :oops end

      assert_raise RuntimeError,
                   "expected req_body_fun to return {:data, chunk, request}, {:done, request}, or {:halt, request}, got: :oops",
                   fn ->
                     Req.post!(req, body: req_body_fun)
                   end
    end

    @tag :transport
    test "into: fun" do
      %{url: url} =
        start_tcp_server(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK\r
          transfer-encoding: chunked\r
          trailer: x-foo, x-bar\r
          \r
          6\r
          chunk1\r
          6\r
          chunk2\r
          0\r
          x-foo: foo\r
          x-bar: bar\r
          \r
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      pid = self()

      resp =
        Req.get!(
          adapter: @adapter,
          url: url,
          into: fn {:data, data}, acc ->
            send(pid, {:data, data})
            {:cont, acc}
          end
        )

      assert resp.status == 200
      assert resp.headers["transfer-encoding"] == ["chunked"]
      assert resp.headers["trailer"] == ["x-foo, x-bar"]

      assert resp.trailers["x-foo"] == ["foo"]
      assert resp.trailers["x-bar"] == ["bar"]

      receive do
        {:data, "chunk1"} ->
          assert_receive {:data, "chunk2"}

        # adapter might emit one chunk
        {:data, "chunk1chunk2"} ->
          :ok
      after
        100 ->
          flunk("expected {:data, _} message")
      end

      refute_receive _
    end

    test "into: fun with halt" do
      %{req: req} =
        serve(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      # shrink httpc's socket buffer so it flushes at chunk boundaries
      connect_options =
        if @adapter == :httpc do
          [transport_opts: [buffer: 8]]
        else
          []
        end

      resp =
        Req.get!(
          req,
          connect_options: connect_options,
          into: fn {:data, data}, {req, resp} ->
            resp = update_in(resp.body, &(&1 <> data))
            {:halt, {req, resp}}
          end
        )

      assert resp.status == 200
      assert resp.body == "foo"
    end

    # TODO: normalize transport errors in Req.HTTPC adapter's async path
    @tag skip: @adapter == :httpc
    @tag :transport
    test "into: fun handle error" do
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Req.get(
                 adapter: @adapter,
                 url: "http://localhost:9999",
                 retry: false,
                 into: fn {:data, data}, {req, resp} ->
                   resp = update_in(resp.body, &(&1 <> data))
                   {:halt, {req, resp}}
                 end
               )
    end

    # TODO: implement Collectable into in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    @tag :transport
    test "into: collectable" do
      %{url: url} =
        start_tcp_server(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK\r
          transfer-encoding: chunked\r
          trailer: x-foo, x-bar\r
          \r
          6\r
          chunk1\r
          6\r
          chunk2\r
          0\r
          x-foo: foo\r
          x-bar: bar\r
          \r
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      resp =
        Req.get!(
          adapter: @adapter,
          url: url,
          into: []
        )

      assert resp.status == 200
      assert resp.headers["transfer-encoding"] == ["chunked"]
      assert resp.headers["trailer"] == ["x-foo, x-bar"]

      assert resp.trailers["x-foo"] == ["foo"]
      assert resp.trailers["x-bar"] == ["bar"]

      assert resp.body == ["chunk1", "chunk2"]
    end

    # TODO: implement Collectable into in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    test "into: collectable non-200" do
      # Ignores the collectable and returns body as usual

      %{req: req} =
        serve(fn conn ->
          Req.Test.json(%{conn | status: 404}, %{error: "not found"})
        end)

      resp = Req.get!(req, into: :not_a_collectable)

      assert resp.status == 404
      assert resp.body == %{"error" => "not found"}
    end

    # TODO: implement Collectable into in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    @tag :transport
    test "into: collectable handle error" do
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Req.get(
                 adapter: @adapter,
                 url: "http://localhost:9999",
                 retry: false,
                 into: IO.stream()
               )
    end

    test "into: :self" do
      %{req: req} =
        serve(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      # shrink httpc's socket buffer so it flushes at chunk boundaries
      connect_options =
        if @adapter == :httpc do
          [transport_opts: [buffer: 8]]
        else
          []
        end

      resp = Req.get!(req, connect_options: connect_options, into: :self)
      assert resp.status == 200
      assert {:ok, [data: "foo"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [data: "bar"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [:done]} = Req.parse_message(resp, assert_receive(_))
      assert :unknown = Req.parse_message(resp, :other)
      refute_receive _
    end

    test "into: :self cancel" do
      %{req: req} =
        serve(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      resp = Req.get!(req, into: :self)
      assert resp.status == 200
      assert :ok = Req.cancel_async_response(resp)
    end

    @tag :capture_log
    test "into: :self with redirect" do
      %{req: req, url: url} =
        serve(fn conn ->
          case conn.request_path do
            "/redirect" ->
              conn
              |> Plug.Conn.put_resp_header("location", "/")
              |> Plug.Conn.send_resp(307, "redirecting to /")

            "/" ->
              Plug.Conn.send_resp(conn, 200, "ok")
          end
        end)

      req = Req.merge(req, url: %{url | path: "/redirect"}, into: :self)

      assert Req.get!(req).body |> Enum.to_list() == ["ok"]
    end

    test "into: :self enumerable with unrelated message" do
      %{req: req} =
        serve(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      send(self(), :other)
      resp = Req.get!(req, into: :self)
      assert Enum.to_list(resp.body) == ["ok"]
      assert_received :other
    end

    # TODO: implement :receive_timeout in Req.HTTPC adapter
    @tag skip: @adapter == :httpc
    @tag :transport
    test "into: :self with :receive_timeout" do
      %{url: url} =
        start_http_server(fn conn ->
          Process.sleep(100)
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get(adapter: @adapter, url: url, into: :self, receive_timeout: 0, retry: false) ==
               {:error, %Req.TransportError{reason: :timeout}}
    end
  end
end
