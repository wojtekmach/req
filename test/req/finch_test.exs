# Finch-specific tests. See test/req/adapter_test.exs for tests that all adapters should pass.
defmodule Req.FinchTest do
  use Req.Case, async: true

  @moduletag :adapter_finch

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

      options = [finch: [pool_timeout: 0]]

      assert_raise RuntimeError, ~r/unable to provide a connection within the timeout/, fn ->
        Req.get!(url, options)
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

    defmodule ExamplePlug do
      def init(options), do: options

      def call(conn, []) do
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end

    test ":connect_options bad option" do
      assert_raise ArgumentError, "unknown option :timeou. Did you mean :timeout?", fn ->
        Req.get!("http://localhost", connect_options: [timeou: 0])
      end
    end

    test ":finch option" do
      assert_raise ArgumentError, "unknown registry: MyFinch", fn ->
        Req.get!("http://localhost", finch: [name: MyFinch])
      end
    end

    test ":finch and :connect_options" do
      assert_raise ArgumentError, "cannot set both :finch and :connect_options", fn ->
        Req.request!(finch: [name: MyFinch], connect_options: [timeout: 0])
      end
    end

    test ":finch with IPv6 URL" do
      start_supervised!(
        {Plug.Cowboy,
         scheme: :http,
         plug: ExamplePlug,
         ref: ExamplePlug.IPv6Named,
         port: 0,
         net: :inet6,
         ipv6_v6only: true}
      )

      ipv6_port = :ranch.get_port(ExamplePlug.IPv6Named)

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
      assert Req.request!(req).body == "ok"

      assert Req.request!("http://localhost:#{ipv6_port}", finch: [name: finch_name], inet6: true).body ==
               "ok"
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

      assert Req.get!(url, finch_private: %{pid: self()}).body == "finch_private"
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

      assert Req.get!(url: url, into: fun).body == ""
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

      assert Req.get!(url,
               finch: [name: Req.Finch, pool_tag: :bulk],
               finch_private: %{pid: self()}
             ).body ==
               "ok"

      assert_received {:pool_tag, :bulk}
    end

    test "finch: pool options start a pool" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get!(url, finch: [conn_max_idle_time: 10_000]).body == "ok"
    end

    test "finch: pool options cannot be set together with :name" do
      assert_raise ArgumentError, ~r/cannot set Finch pool options together with :name/, fn ->
        Req.request!(finch: [name: Req.Finch, conn_max_idle_time: 10_000])
      end
    end
  end
end
