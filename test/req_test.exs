defmodule ReqTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [start_http_server: 1, start_https_server: 1]

  doctest Req,
    only: [
      new: 1,
      merge: 2,
      get_headers_list: 1,
      assign: 2,
      assign: 3,
      assign_new: 3,
      update_assign: 3,
      update_assign: 4
    ]

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "default_headers", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      Plug.Conn.send_resp(conn, 200, user_agent)
    end)

    assert "req/" <> _ = Req.get!(c.url).body
  end

  test "headers", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      headers = Enum.filter(conn.req_headers, fn {name, _} -> String.starts_with?(name, "x-") end)
      send(pid, {:headers, headers})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    Req.get!(c.url, headers: [x_a: 1, x_b: ~U[2021-01-01 09:00:00Z]])
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1"}, {"x-b", "Fri, 01 Jan 2021 09:00:00 GMT"}]

    req = Req.new(headers: [x_a: 1, x_a: 2])

    unless Req.MixProject.legacy_headers_as_lists?() do
      assert req.headers == %{"x-a" => ["1", "2"]}
    end

    Req.get!(req, url: c.url)
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1, 2"}]

    req = Req.new(headers: [x_a: 1, x_b: 1])
    Req.get!(req, url: c.url, headers: [x_a: 2])
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "2"}, {"x-b", "1"}]
  end

  test "redact" do
    assert inspect(Req.new(auth: {:bearer, "foo"})) =~ ~s|auth: {:bearer, "***"}|

    assert inspect(Req.new(auth: {:basic, "foo:bar"})) =~ ~s|auth: {:basic, "foo****"}|

    assert inspect(Req.new(auth: fn -> {:basic, "foo:bar"} end)) =~ ~s|auth: #Function|

    if Req.MixProject.legacy_headers_as_lists?() do
      assert inspect(Req.new(headers: [authorization: "bearer foobar"])) =~
               ~s|{"authorization", "bearer ***"}|
    else
      assert inspect(Req.new(headers: [authorization: "bearer foo"])) =~
               ~s|"authorization" => ["bearer ***"]|
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
    %{url: origin_url} =
      start_http_server(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        {:ok, conn} = Plug.Conn.chunk(conn, "baz")
        conn
      end)

    %{url: echo_url} =
      start_http_server(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

    resp = Req.get!(origin_url, into: :self)
    assert Req.put!(echo_url, body: resp.body).body == "foobarbaz"
  end

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
