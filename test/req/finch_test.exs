# Finch-specific tests. See test/req/adapter_test.exs for tests that all adapters should pass.
defmodule Req.FinchTest do
  use Req.Case, async: true

  @moduletag :adapter_finch

  describe "run" do
    test "pool timeout" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      options = [finch: [pool_timeout: 0]]

      assert_raise RuntimeError, ~r/unable to provide a connection within the timeout/, fn ->
        Req.stream!(url, options)
      end
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
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy option" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(base_url: url, http_proxy: "http://localhost:#{url.port}")
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy option with credentials" do
      %{url: url} =
        start_http_server(fn conn ->
          assert ["Basic " <> credentials] = Plug.Conn.get_req_header(conn, "proxy-authorization")
          assert Base.decode64!(credentials) == "user:pass"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(base_url: url, http_proxy: "http://user:pass@localhost:#{url.port}")
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy option with percent-encoded credentials" do
      %{url: url} =
        start_http_server(fn conn ->
          assert ["Basic " <> credentials] = Plug.Conn.get_req_header(conn, "proxy-authorization")
          assert Base.decode64!(credentials) == "user:p@ss:w0rd"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(base_url: url, http_proxy: "http://user:p%40ss%3Aw0rd@localhost:#{url.port}")
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy with unsupported scheme" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert_raise ArgumentError, ~r/expected proxy URL scheme to be http or https/, fn ->
        Req.stream!(base_url: url, http_proxy: "socks5://localhost:1080")
      end
    end

    test ":https_proxy does not apply to http requests" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(base_url: url, https_proxy: "http://localhost:1")
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":http_proxy with missing host" do
      assert_raise ArgumentError, "expected proxy URL to include a host", fn ->
        Req.stream!("http://example.com", http_proxy: "http://")
      end
    end

    test ":http_proxy with out-of-range port" do
      exception =
        assert_raise ArgumentError, "invalid proxy URL", fn ->
          Req.stream!("http://example.com", http_proxy: "http://user:s3cr3t@localhost:99999")
        end

      refute exception.message =~ "s3cr3t"
    end

    test ":http_proxy accepts an IPv6 host" do
      # The proxy URL is accepted (no ArgumentError); the connection itself
      # fails because nothing listens on [::1]:1.
      assert {:error, %Req.TransportError{}} =
               Req.get("http://example.com", http_proxy: "http://[::1]:1", retry: false)
    end

    test "proxy URL errors do not leak credentials" do
      exception =
        assert_raise ArgumentError, fn ->
          Req.stream!("http://example.com", http_proxy: "socks5://user:s3cr3t@localhost:1080")
        end

      refute exception.message =~ "s3cr3t"
      refute exception.message =~ "user"

      malformed =
        assert_raise ArgumentError, "invalid proxy URL", fn ->
          Req.stream!("http://example.com", http_proxy: "http://user:s3cr3t@lo calhost:8080")
        end

      refute malformed.message =~ "s3cr3t"
    end

    test ":https_proxy option through CONNECT tunnel" do
      %{url: url} =
        start_https_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      proxy = start_connect_proxy(url.port)

      req =
        Req.new(
          base_url: url,
          https_proxy: "http://localhost:#{proxy.port}",
          connect_options: [transport_opts: [verify: :verify_none]]
        )

      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"

      # Cleanup/ownership proof: the accept loop is owned by the test supervisor;
      # stopping it terminates the loop process AND closes its listen socket, so the
      # port refuses new connections.
      stop_supervised!(Task)
      refute Process.alive?(proxy.pid)
      assert {:error, :econnrefused} = :gen_tcp.connect(~c"localhost", proxy.port, [], 1_000)
    end

    test ":connect_options :hostname" do
      %{url: url} =
        start_http_server(fn conn ->
          assert ["example.com:" <> _] = Plug.Conn.get_req_header(conn, "host")
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(base_url: url, connect_options: [hostname: "example.com"])
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test ":connect_options bad option" do
      assert_raise ArgumentError, "unknown option :timeou. Did you mean :timeout?", fn ->
        Req.stream!("http://localhost", connect_options: [timeou: 0])
      end
    end

    test ":finch option" do
      assert_raise ArgumentError, "unknown registry: MyFinch", fn ->
        Req.stream!("http://localhost", finch: [name: MyFinch])
      end
    end

    test ":finch and :connect_options" do
      assert_raise ArgumentError, "cannot set both :finch and :connect_options", fn ->
        Req.stream!(finch: [name: MyFinch], connect_options: [timeout: 0])
      end
    end

    test ":finch with IPv6 URL" do
      %{port: ipv6_port} =
        start_http_server(&Plug.Conn.send_resp(&1, 200, "ok"), ip: {0, 0, 0, 0, 0, 0, 0, 1})

      finch_name = __MODULE__.IPv6Finch

      start_supervised!(
        {Finch,
         name: finch_name,
         pools: %{
           default: [
             protocols: [:http1],
             conn_opts: [transport_opts: [inet6: true]]
           ]
         }}
      )

      # :inet6 can be auto-set for IPv6 URLs; it should not conflict with :finch
      req = Req.new(url: "http://[::1]:#{ipv6_port}", finch: [name: finch_name])
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!("http://localhost:#{ipv6_port}", finch: [name: finch_name], inet6: true)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    def send_telemetry_metadata_pid(_name, _measurements, metadata, _) do
      if pid = metadata.request.private[:pid] do
        send(pid, :telemetry_private)
      end

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

      resp = Req.stream!(url, finch_private: %{pid: self()})
      assert resp.status == 200
      assert resp.body == "finch_private"

      assert_received :telemetry_private
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

      resp = Req.request!(url: url, into: fun)
      assert resp.status == 200
      assert resp.body == ""
      assert_received {:data, "foo"}
      refute_receive _
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

    def send_pool_tag(_name, _measurements, metadata, _config) do
      if pid = metadata.request.private[:pid] do
        send(pid, {:pool_tag, metadata.request.pool_tag})
      end

      :ok
    end

    test ":finch {name, pool_tag: tag} sets the request's pool_tag", %{test: test} do
      on_exit(fn -> :telemetry.detach("#{test}") end)

      :telemetry.attach("#{test}", [:finch, :request, :stop], &__MODULE__.send_pool_tag/4, nil)

      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      resp =
        Req.stream!(url, finch: [name: Req.Finch, pool_tag: :bulk], finch_private: %{pid: self()})

      assert resp.status == 200
      assert resp.body == "ok"

      assert_received {:pool_tag, :bulk}
    end

    test "finch: pool options start a pool" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      resp = Req.stream!(url, finch: [conn_max_idle_time: 10_000])
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "finch: pool options cannot be set together with :name" do
      assert_raise ArgumentError, ~r/cannot set Finch pool options together with :name/, fn ->
        Req.stream!(finch: [name: Req.Finch, conn_max_idle_time: 10_000])
      end
    end
  end

  # A minimal CONNECT proxy for testing https proxying end to end. The supervised
  # accept-loop task owns the listen socket (created inside the task, so it closes
  # when the task terminates) and each accepted client socket: the tunnel runs inline
  # in the accept loop, so no socket ever changes hands. Pipes are short-lived
  # spawned processes; after the first pipe ends, both sockets are closed and the
  # helper waits for the remaining pipe to terminate.
  defp start_connect_proxy(target_port) do
    test_pid = self()
    pid = start_supervised!({Task, fn -> connect_proxy_accept(test_pid, target_port) end})

    port =
      receive do
        {:connect_proxy_port, port} -> port
      after
        5_000 -> raise "connect proxy did not report its port"
      end

    %{port: port, pid: pid}
  end

  defp connect_proxy_accept(test_pid, target_port) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    send(test_pid, {:connect_proxy_port, port})
    connect_proxy_accept_loop(listen, target_port)
  end

  defp connect_proxy_accept_loop(listen, target_port) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        connect_proxy_tunnel(client, target_port)
        connect_proxy_accept_loop(listen, target_port)

      {:error, :closed} ->
        :ok
    end
  end

  defp connect_proxy_tunnel(client, target_port) do
    with {:ok, _headers} <- read_http_request_head(client, ""),
         {:ok, target} <-
           :gen_tcp.connect(~c"localhost", target_port, [:binary, packet: :raw, active: false]),
         :ok <- :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n") do
      pipe_bidirectional(client, target)
    end

    :gen_tcp.close(client)
  end

  defp read_http_request_head(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        if String.ends_with?(acc, "\r\n\r\n"),
          do: {:ok, acc},
          else: read_http_request_head(socket, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pipe_bidirectional(client, target) do
    parent = self()

    spawn(fn ->
      pipe(client, target)
      send(parent, :piped)
    end)

    spawn(fn ->
      pipe(target, client)
      send(parent, :piped)
    end)

    receive do
      :piped -> :ok
    end

    # Closing both ends must terminate the remaining pipe process; if it does not
    # exit, the helper (and the test using it) fails instead of leaking it.
    :gen_tcp.close(client)
    :gen_tcp.close(target)

    receive do
      :piped -> :ok
    after
      5_000 -> raise "connect proxy pipe did not terminate after sockets closed"
    end
  end

  defp pipe(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok -> pipe(from, to)
          {:error, _reason} -> :gen_tcp.close(to)
        end

      {:error, _reason} ->
        :gen_tcp.close(to)
    end
  end
end
