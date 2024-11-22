defmodule Req.FinchTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [start_http_server: 1, start_tcp_server: 1]

  describe "run" do
    test ":finch_request" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      pid = self()

      fun = fn req, finch_request, finch_name, finch_opts ->
        {:ok, resp} = Finch.request(finch_request, finch_name, finch_opts)
        send(pid, resp)
        {req, Req.Response.new(status: resp.status, headers: resp.headers, body: "finch_request")}
      end

      assert Req.get!(url, finch_request: fun).body == "finch_request"
      assert_received %Finch.Response{body: "ok"}
    end

    test ":finch_request error" do
      fun = fn req, _finch_request, _finch_name, _finch_opts ->
        {req, %ArgumentError{message: "exec error"}}
      end

      assert_raise ArgumentError, "exec error", fn ->
        Req.get!("http://localhost", finch_request: fun, retry: false)
      end
    end

    test ":finch_request with invalid return" do
      fun = fn _, _, _, _ -> :ok end

      assert_raise RuntimeError, ~r"expected adapter to return \{request, response\}", fn ->
        Req.get!("http://localhost", finch_request: fun)
      end
    end

    test "pool timeout" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      options = [pool_timeout: 0]

      assert_raise RuntimeError, ~r/unable to provide a connection within the timeout/, fn ->
        Req.get!(url, options)
      end
    end

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

      req = Req.new(url: url, receive_timeout: 50, retry: false)
      assert {:error, %Req.TransportError{reason: :timeout}} = Req.request(req)
      assert_received :ping
    end

    test "Req.HTTPError" do
      %{url: url} =
        start_tcp_server(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)
          :ok = :gen_tcp.send(socket, "bad\r\n")
        end)

      req = Req.new(url: url, retry: false)
      {:error, %Req.HTTPError{protocol: :http1, reason: :invalid_status_line}} = Req.request(req)
    end

    test ":connect_options :protocol" do
      %{url: url} =
        start_http_server(fn conn ->
          assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(url: url, connect_options: [protocols: [:http2]], retry: false)
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options :proxy" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      # Bandit will forward request to itself
      # Not quite a proper forward proxy server, but good enough
      proxy = {:http, "localhost", url.port, []}

      req = Req.new(base_url: url, connect_options: [proxy: proxy])
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options :hostname" do
      %{url: url} =
        start_http_server(fn conn ->
          assert ["example.com:" <> _] = Plug.Conn.get_req_header(conn, "host")
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(base_url: url, connect_options: [hostname: "example.com"])
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options :transport_opts" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(connect_options: [transport_opts: [cacertfile: "bad.pem"]])

      assert_raise File.Error, ~r/could not read file "bad.pem"/, fn ->
        Req.request!(req, url: %{url | scheme: "https"})
      end
    end

    defmodule ExamplePlug do
      def init(options), do: options

      def call(conn, []) do
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end

    test ":inet6" do
      start_supervised!(
        {Plug.Cowboy, scheme: :http, plug: ExamplePlug, ref: ExamplePlug.IPv4, port: 0}
      )

      start_supervised!(
        {Plug.Cowboy,
         scheme: :http,
         plug: ExamplePlug,
         ref: ExamplePlug.IPv6,
         port: 0,
         net: :inet6,
         ipv6_v6only: true}
      )

      ipv4_port = :ranch.get_port(ExamplePlug.IPv4)
      ipv6_port = :ranch.get_port(ExamplePlug.IPv6)

      req = Req.new(url: "http://localhost:#{ipv4_port}")
      assert Req.request!(req).body == "ok"

      req = Req.new(url: "http://localhost:#{ipv4_port}", inet6: true)
      assert Req.request!(req).body == "ok"

      req = Req.new(url: "http://localhost:#{ipv6_port}", inet6: true)
      assert Req.request!(req).body == "ok"

      req = Req.new(url: "http://[::1]:#{ipv6_port}")
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options bad option" do
      assert_raise ArgumentError, "unknown option :timeou. Did you mean :timeout?", fn ->
        Req.get!("http://localhost", connect_options: [timeou: 0])
      end
    end

    test ":finch option" do
      assert_raise ArgumentError, "unknown registry: MyFinch", fn ->
        Req.get!("http://localhost", finch: MyFinch)
      end
    end

    test ":finch and :connect_options" do
      assert_raise ArgumentError, "cannot set both :finch and :connect_options", fn ->
        Req.request!(finch: MyFinch, connect_options: [timeout: 0])
      end
    end

    def send_telemetry_metadata_pid(_name, _measurements, metadata, _) do
      send(metadata.request.private.pid, :telemetry_private)
      :ok
    end

    test ":finch_private", %{test: test} do
      on_exit(fn -> :telemetry.detach("#{test}") end)

      :ok =
        :telemetry.attach(
          "#{test}",
          [:finch, :request, :stop],
          &__MODULE__.send_telemetry_metadata_pid/4,
          nil
        )

      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "finch_private")
        end)

      assert Req.get!(url, finch_private: %{pid: self()}).body == "finch_private"
      assert_received :telemetry_private
    end

    test "into: fun" do
      %{url: url} =
        start_tcp_server(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK
          transfer-encoding: chunked
          trailer: x-foo, x-bar

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

      assert_receive {:data, "chunk1"}
      assert_receive {:data, "chunk2"}
      refute_receive _
    end

    test "into: fun with halt" do
      # try fixing `** (exit) shutdown` on CI by starting custom server
      defmodule StreamPlug do
        def init(options), do: options

        def call(conn, []) do
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end
      end

      start_supervised!({Plug.Cowboy, plug: StreamPlug, scheme: :http, port: 0})
      url = "http://localhost:#{:ranch.get_port(StreamPlug.HTTP)}"

      resp =
        Req.get!(
          url: url,
          into: fn {:data, data}, {req, resp} ->
            resp = update_in(resp.body, &(&1 <> data))
            {:halt, {req, resp}}
          end
        )

      assert resp.status == 200
      assert resp.body == "foo"
    end

    test "into: fun handle error" do
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Req.get(
                 url: "http://localhost:9999",
                 retry: false,
                 into: fn {:data, data}, {req, resp} ->
                   resp = update_in(resp.body, &(&1 <> data))
                   {:halt, {req, resp}}
                 end
               )
    end

    test "into: collectable" do
      %{url: url} =
        start_tcp_server(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK
          transfer-encoding: chunked
          trailer: x-foo, x-bar

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

    @tag :tmp_dir
    test "into: collectable non-200", %{tmp_dir: tmp_dir} do
      # Ignores the collectable and returns body as usual

      File.mkdir_p!(tmp_dir)
      file = Path.join(tmp_dir, "result.bin")

      %{url: url} =
        start_tcp_server(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          body = ~s|{"error": "not found"}|

          data = """
          HTTP/1.1 404 OK
          content-length: #{byte_size(body)}
          content-type: application/json

          #{body}
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      resp =
        Req.get!(
          url: url,
          into: File.stream!(file)
        )

      assert resp.status == 404
      assert resp.body == %{"error" => "not found"}

      refute File.exists?(file)
    end

    test "into: collectable handle error" do
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Req.get(
                 url: "http://localhost:9999",
                 retry: false,
                 into: IO.stream()
               )
    end

    # TODO
    @tag :skip
    test "into: fun with content-encoding" do
      %{url: url} =
        start_http_server(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
        end)

      pid = self()

      fun = fn {:data, data}, acc ->
        send(pid, {:data, data})
        {:cont, acc}
      end

      assert Req.get!(url: url, into: fun).body == ""
      assert_received {:data, "foo"}
      refute_receive _
    end

    test "into: :self" do
      %{url: url} =
        start_http_server(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      resp = Req.get!(url: url, into: :self)
      assert resp.status == 200
      assert {:ok, [data: "foo"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [data: "bar"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [:done]} = Req.parse_message(resp, assert_receive(_))
      assert :unknown = Req.parse_message(resp, :other)
      refute_receive _
    end

    test "into: :self cancel" do
      %{url: url} =
        start_http_server(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      resp = Req.get!(url: url, into: :self)
      assert resp.status == 200
      assert :ok = Req.cancel_async_response(resp)
    end

    @tag :capture_log
    test "into: :self with redirect" do
      %{url: url} =
        TestHelper.start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      %{url: url} =
        TestHelper.start_http_server(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", to_string(url))
          |> Plug.Conn.send_resp(307, "redirecting to #{url}")
        end)

      req =
        Req.new(
          url: url,
          into: :self
        )

      assert Req.get!(req).body |> Enum.to_list() == ["ok"]
    end

    test "into: :self enumerable with unrelated message" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      send(self(), :other)
      resp = Req.get!(url: url, into: :self)
      assert Enum.to_list(resp.body) == ["ok"]
      assert_received :other
    end
  end

  describe "pool_options" do
    test "defaults" do
      assert Req.Finch.pool_options([]) ==
               [
                 protocols: [:http1]
               ]
    end

    test "ipv6" do
      assert Req.Finch.pool_options(inet6: true) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [inet6: true]]
               ]
    end

    test "connect_options protocols" do
      assert Req.Finch.pool_options(connect_options: [protocols: [:http2]]) ==
               [
                 protocols: [:http2]
               ]
    end

    test "connect_options timeout" do
      assert Req.Finch.pool_options(connect_options: [timeout: 0]) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [timeout: 0]]
               ]
    end

    test "connect_options transport_opts" do
      assert Req.Finch.pool_options(connect_options: [transport_opts: [cacerts: []]]) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [cacerts: []]]
               ]
    end

    test "connect_options transport_opts + timeout + ipv6" do
      assert Req.Finch.pool_options(
               connect_options: [timeout: 0, transport_opts: [cacerts: []]],
               inet6: true
             ) ==
               [
                 protocols: [:http1],
                 conn_opts: [transport_opts: [timeout: 0, inet6: true, cacerts: []]]
               ]
    end
  end
end
