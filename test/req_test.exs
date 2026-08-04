defmodule ReqTest do
  use Req.Case, async: true

  doctest Req,
    only: [
      new: 2,
      merge: 2,
      get_headers_list: 1
    ]

  test "default_headers" do
    %{req: req} =
      serve(fn conn ->
        [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
        Plug.Conn.send_resp(conn, 200, user_agent)
      end)

    resp = Req.stream!(req)
    assert resp.status == 200
    assert "req/" <> _ = resp.body
  end

  test "headers" do
    pid = self()

    %{req: req} =
      serve(fn conn ->
        headers =
          conn.req_headers
          |> Enum.filter(fn {name, _} -> String.starts_with?(name, "x-") end)
          |> Enum.group_by(fn {name, _} -> name end, fn {_, value} -> value end)
          |> Enum.map(fn {name, values} -> {name, values |> Enum.sort() |> Enum.join(", ")} end)
          |> Enum.sort()

        send(pid, {:headers, headers})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

    resp = Req.stream!(req, headers: [x_a: 1, x_b: ~U[2021-01-01 09:00:00Z]])
    assert resp.status == 200
    assert resp.body == "ok"

    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1"}, {"x-b", "Fri, 01 Jan 2021 09:00:00 GMT"}]

    req2 = Req.merge(req, headers: [x_a: 1, x_a: 2])

    unless Req.MixProject.legacy_headers_as_lists?() do
      assert req2.headers == %{"x-a" => ["1", "2"]}
    end

    resp = Req.stream!(req2)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1, 2"}]

    req2 = Req.merge(req, headers: [x_a: 1, x_b: 1])
    resp = Req.stream!(req2, headers: [x_a: 2])
    assert resp.status == 200
    assert resp.body == "ok"
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "2"}, {"x-b", "1"}]
  end

  test "respects userinfo in URL" do
    pid = self()

    %{req: req, url: url} =
      serve(fn conn ->
        case List.keyfind(conn.req_headers, "authorization", 0) do
          {_, auth_header} -> send(pid, {:authorization, auth_header})
          _ -> nil
        end

        Plug.Conn.send_resp(conn, 200, "ok")
      end)

    with_userinfo = String.replace("#{url}", "http://", "http://foo:bar@")
    resp = Req.stream!(req, url: with_userinfo)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_receive {:authorization, "Basic " <> _}

    # explicit :auth option is favored over userinfo in URL
    resp = Req.stream!(req, url: with_userinfo, auth: {:bearer, "token"})
    assert resp.status == 200
    assert resp.body == "ok"

    assert_receive {:authorization, "Bearer token"}

    req2 = Req.merge(req, auth: {:bearer, "token"})
    resp = Req.stream!(req2, url: with_userinfo)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_receive {:authorization, "Bearer token"}

    req2 = Req.new(url: with_userinfo)
    refute inspect(req2) =~ "foo:bar@"
    assert inspect(req2) =~ "#{url}"
  end

  test "private" do
    req = Req.new(private: %{a: 1})
    assert req.private == %{a: 1}

    req = Req.merge(req, private: [b: 2])
    assert req.private == %{a: 1, b: 2}
  end

  test "inspect" do
    assert inspect(Req.new(), pretty: true) == """
           Req.new(
             url: nil,
             method: :get,
             headers: [],
             body: nil
           )\
           """

    assert inspect(Req.new("https://elixir-lang.org"), pretty: true) == """
           Req.new(
             "https://elixir-lang.org",
             method: :get,
             headers: [],
             body: nil
           )\
           """

    assert inspect(Req.new(adapter: MyAdapter), pretty: true) == """
           Req.new(
             url: nil,
             method: :get,
             headers: [],
             body: nil,
             adapter: MyAdapter
           )\
           """
  end

  test "inspect steps" do
    req = %{
      Req.new()
      | request_steps: [custom: __MODULE__],
        response_steps: [custom: __MODULE__],
        error_steps: [custom: __MODULE__]
    }

    assert inspect(req, pretty: true) == """
           Req.new(
             url: nil,
             method: :get,
             headers: [],
             body: nil,
             request_steps: [custom: ReqTest],
             response_steps: [custom: ReqTest],
             error_steps: [custom: ReqTest]
           )\
           """
  end

  test "redact" do
    assert inspect(Req.new(auth: {:bearer, "foo"}), pretty: true) == """
           Req.new(
             url: nil,
             method: :get,
             headers: [],
             body: nil,

             # options
             auth: {:bearer, "***"}
           )\
           """

    assert inspect(Req.new(auth: {:basic, "foo:bar"}), pretty: true) == """
           Req.new(
             url: nil,
             method: :get,
             headers: [],
             body: nil,

             # options
             auth: {:basic, "foo****"}
           )\
           """

    assert inspect(Req.new(auth: {:digest, "alice:secret"})) =~
             ~s|auth: {:digest, "ali*********"}|

    assert inspect(Req.new(auth: "standalone-secret")) =~
             ~s|auth: "sta**************"|

    assert inspect(
             Req.new(
               aws_sigv4: [
                 access_key_id: "access",
                 secret_access_key: "secret",
                 token: "session-secret"
               ]
             )
           ) =~
             ~s|aws_sigv4: [access_key_id: "acc***", secret_access_key: "sec***", token: "ses***********"]|

    assert inspect(Req.new(auth: fn -> {:basic, "foo:bar"} end)) =~ ~s|auth: #Function|

    defmodule AuthToken do
      def generate, do: {:bearer, "some-value"}
    end

    assert inspect(Req.new(auth: {AuthToken, :generate, []}), pretty: true) == """
           Req.new(
             url: nil,
             method: :get,
             headers: [],
             body: nil,

             # options
             auth: {ReqTest.AuthToken, :generate, []}
           )\
           """

    if Req.MixProject.legacy_headers_as_lists?() do
      assert inspect(Req.new(headers: [authorization: "bearer foobar"])) =~
               ~s|{"authorization", "bearer foo***"}|
    else
      assert inspect(Req.new(headers: [authorization: "bearer foobar"]), pretty: true) == """
             Req.new(
               url: nil,
               method: :get,
               headers: [{"authorization", "bearer foo***"}],
               body: nil
             )\
             """
    end
  end

  test "plugins" do
    foo = fn req ->
      Req.Request.register_options(req, [:foo])
    end

    req = Req.new(plugins: [foo], foo: 42)
    assert req.options.foo == 42
  end

  test "async enumerable" do
    %{req: origin} =
      serve(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        {:ok, conn} = Plug.Conn.chunk(conn, "baz")
        conn
      end)

    %{req: echo} =
      serve(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

    resp = Req.request!(origin, into: :self)
    assert resp.status == 200

    resp = Req.stream!(echo, method: :put, body: resp.body)
    assert resp.status == 200
    assert resp.body == "foobarbaz"
  end

  @tag :transport
  test "http1 + http2" do
    %{url: url} =
      start_https_server(fn conn ->
        assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

    req =
      Req.new(
        adapter: adapter_fun(),
        url: url,
        connect_options: [
          transport_opts: [cacertfile: "#{__DIR__}/support/ca.pem"],
          protocols: [:http1, :http2]
        ],
        retry: false
      )

    if Req.Case.adapter() == :httpc do
      assert_raise ArgumentError, "httpc adapter does not support HTTP/2", fn ->
        Req.stream!(req)
      end
    else
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end
  end

  describe "stream" do
    @tag skip: adapter() == :httpc
    test "success" do
      %{req: req} =
        serve(fn conn ->
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/plain", nil)
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, "chunk1")
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk2")
          conn
        end)

      {:ok, resp, acc} =
        Req.stream(req, [], fn data, _resp, acc ->
          {:cont, [data | acc]}
        end)

      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-type") == ["text/plain"]
      assert resp.body == nil
      assert acc == ["chunk2", "chunk1"]
    end

    @tag skip: adapter() == :httpc
    test "halt" do
      %{req: req} =
        serve(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk1")
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk2")
          conn
        end)

      {:ok, resp, acc} =
        Req.stream(req, [], fn data, _resp, acc ->
          {:halt, [data | acc]}
        end)

      assert resp.status == 200
      assert resp.body == nil
      assert acc == ["chunk1"]
    end

    @tag skip: adapter() == :httpc
    test "invalid return" do
      %{req: req} =
        serve(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk1")
          conn
        end)

      assert_raise ArgumentError,
                   ~s|expected {:cont, acc} or {:halt, acc}, got: ["chunk1"]|,
                   fn ->
                     Req.stream(req, [], fn data, _resp, acc ->
                       [data | acc]
                     end)
                   end
    end

    @tag :transport
    @tag skip: adapter() == :httpc
    test "initial transport error" do
      %{url: url} =
        start_tcp_server(fn _socket ->
          nil
        end)

      req = Req.new(adapter: adapter_fun(), url: url, retry: false)

      {:error, err, resp, acc} =
        Req.stream(req, [], fn data, _resp, acc ->
          {:cont, [data | acc]}
        end)

      assert err == %Req.TransportError{reason: :closed}
      assert resp.status == nil
      assert resp.body == nil
      assert resp.request.url == url
      assert acc == []
    end

    @tag :transport
    @tag :capture_log
    @tag skip: adapter() == :httpc
    test "mid-stream transport error" do
      %{req: req} =
        serve(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "chunk1")
          raise "oops"
          conn
        end)

      req = Req.new(req, retry: false)

      {:error, err, resp, acc} =
        Req.stream(req, [], fn data, _resp, acc ->
          {:cont, [data | acc]}
        end)

      assert err == %Req.TransportError{reason: :closed}
      assert resp.status == 200
      assert resp.body == nil
      assert resp.request.url == req.url
      assert acc == ["chunk1"]
    end

    @tag :transport
    test "trailers" do
      %{url: url} =
        start_tcp_server(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK\r
          transfer-encoding: chunked\r
          trailer: x-foo, x-bar\r
          \r
          6\r
          chunk1\r
          0\r
          x-foo: foo\r
          x-bar: bar\r
          \r
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      req = Req.new(adapter: adapter_fun(), url: url)

      assert {:ok, resp, :ok} =
               Req.stream(req, :ok, fn _data, _resp, acc ->
                 {:cont, acc}
               end)

      assert resp.status == 200
      assert resp.trailers["x-foo"] == ["foo"]
      assert resp.trailers["x-bar"] == ["bar"]
    end

    test "into: is not supported" do
      fun = fn _data, _resp, acc -> {:cont, acc} end

      assert_raise ArgumentError, "Req.stream/4 does not support :into option", fn ->
        Req.stream("http://localhost", [], fun, into: [])
      end

      assert_raise ArgumentError, "Req.stream/4 does not support :into option", fn ->
        Req.stream("http://localhost", [], fun, into: :self)
      end
    end
  end
end
