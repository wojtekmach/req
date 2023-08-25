defmodule ReqTest do
  use ExUnit.Case, async: true

  doctest Req,
    only: [
      new: 1,
      update: 2
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
    assert inspect(Req.new(auth: {:bearer, "foo"})) =~ ~s|auth: {:bearer, "[redacted]"}|

    assert inspect(Req.new(auth: {"foo", "bar"})) =~ ~s|auth: {"[redacted]", "[redacted]"}|

    if Req.MixProject.legacy_headers_as_lists?() do
      assert inspect(Req.new(headers: [authorization: "bearer foo"])) =~
               ~s|{"authorization", "[redacted]"}|
    else
      assert inspect(Req.new(headers: [authorization: "bearer foo"])) =~
               ~s|"authorization" => ["[redacted]"]|
    end
  end
end
