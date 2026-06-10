defmodule ReqTest do
  use Req.Case, async: true

  doctest Req,
    only:
      [
        new: 1,
        merge: 2,
        get_headers_list: 1,
        assign: 2,
        assign: 3,
        assign_new: 2,
        assign_new: 3
      ] ++
        (if Version.match?(System.version(), ">= 1.19.0") do
           [
             update_assign: 3,
             update_assign: 4
           ]
         else
           []
         end)

  test "default_headers" do
    %{req: req} =
      serve(fn conn ->
        [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
        Plug.Conn.send_resp(conn, 200, user_agent)
      end)

    assert "req/" <> _ = Req.get!(req).body
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

    Req.get!(req, headers: [x_a: 1, x_b: ~U[2021-01-01 09:00:00Z]])
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1"}, {"x-b", "Fri, 01 Jan 2021 09:00:00 GMT"}]

    req2 = Req.merge(req, headers: [x_a: 1, x_a: 2])

    unless Req.MixProject.legacy_headers_as_lists?() do
      assert req2.headers == %{"x-a" => ["1", "2"]}
    end

    Req.get!(req2)
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1, 2"}]

    req2 = Req.merge(req, headers: [x_a: 1, x_b: 1])
    Req.get!(req2, headers: [x_a: 2])
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
    Req.get!(req, url: with_userinfo)
    assert_receive {:authorization, "Basic " <> _}

    # explicit :auth option is favored over userinfo in URL
    Req.get!(req, url: with_userinfo, auth: {:bearer, "token"})
    assert_receive {:authorization, "Bearer token"}

    req2 = Req.merge(req, auth: {:bearer, "token"})
    Req.get!(req2, url: with_userinfo)
    assert_receive {:authorization, "Bearer token"}

    req2 = Req.new(url: with_userinfo)
    refute inspect(req2) =~ "foo:bar@"
    assert inspect(req2) =~ "#{url}"
  end

  test "redact" do
    assert inspect(Req.new(auth: {:bearer, "foo"})) =~ ~s|auth: {:bearer, "***"}|

    assert inspect(Req.new(auth: {:basic, "foo:bar"})) =~ ~s|auth: {:basic, "foo****"}|

    assert inspect(Req.new(auth: fn -> {:basic, "foo:bar"} end)) =~ ~s|auth: #Function|

    defmodule AuthToken do
      def generate, do: {:bearer, "some-value"}
    end

    assert inspect(Req.new(auth: {AuthToken, :generate, []})) =~
             ~s|auth: {ReqTest.AuthToken, :generate, []}|

    if Req.MixProject.legacy_headers_as_lists?() do
      assert inspect(Req.new(headers: [authorization: "bearer foobar"])) =~
               ~s|{"authorization", "bearer foo***"}|
    else
      assert inspect(Req.new(headers: [authorization: "bearer foobar"])) =~
               ~s|"authorization" => ["bearer foo***"]|
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

    resp = Req.get!(origin, into: :self)
    assert Req.put!(echo, body: resp.body).body == "foobarbaz"
  end

  @tag :http2
  test "http1 + http2" do
    %{url: url} =
      start_https_server(fn conn ->
        assert Plug.Conn.get_http_protocol(conn) == :"HTTP/2"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

    assert Req.get!(
             url,
             connect_options: [
               transport_opts: [cacertfile: "#{__DIR__}/support/ca.pem"],
               protocols: [:http1, :http2]
             ],
             retry: false
           ).body == "ok"
  end
end
