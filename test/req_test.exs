defmodule ReqTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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
    assert req.headers == [{"x-a", "1"}, {"x-a", "2"}]
    Req.get!(req, url: c.url)
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1, 2"}]

    req = Req.new(headers: [x_a: 1])
    Req.get!(req, url: c.url, headers: [x_a: 2])
    assert_receive {:headers, headers}
    assert headers == [{"x-a", "1, 2"}]
  end

  test "validation header raises if option was not supported",
       c do
    headers = [{:x_Invalid, "any value"}, {"NotValid", "whoops!"}]

    assert_raise(ArgumentError, "Value :anything not valid for option :invalid_header_keys", fn ->
      Req.new(invalid_header_keys: :anything, url: c.url, headers: headers)
      |> Req.get!()
    end)
  end

  test "header validation defaults to a warning if invalid header key is not sent", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      headers =
        Enum.filter(conn.req_headers, fn {name, _} -> String.contains?(name, ["foo", "bar"]) end)

      send(pid, {:headers, headers})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    headers = [{:x_Foo, "some value"}, {"Bar", 911}]

    {_result, log} =
      with_log(fn ->
        Req.new(url: c.url, headers: headers)
        |> Req.get!()
      end)

    expected_headers = [{"x-foo", "some value"}, {"bar", "911"}]

    assert_receive {:headers, headers}

    header_set = MapSet.new(headers)

    assert Enum.all?(expected_headers, &MapSet.member?(header_set, &1))

    assert log =~ ~r/is not lowercase/
  end

  test "header validation warns if option set and invalid header key sent", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      headers = Enum.filter(conn.req_headers, fn {name, _} -> String.contains?(name, "valid") end)

      send(pid, {:headers, headers})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    headers = [{:x_Invalid, "any value"}, {"NotValid", "whoops!"}]

    {_result, log} =
      with_log(fn ->
        Req.new(invalid_header_keys: :warn, url: c.url, headers: headers)
        |> Req.get!()
      end)

    expected_headers = [{"x-invalid", "any value"}, {"notvalid", "whoops!"}]

    assert_receive {:headers, headers}

    header_set = MapSet.new(headers)

    assert Enum.all?(expected_headers, &MapSet.member?(header_set, &1))

    assert log =~ ~r/is not lowercase/
  end

  test "header validation doesn't warn if option :ignore set and invalid header key sent",
       c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      headers = Enum.filter(conn.req_headers, fn {name, _} -> String.contains?(name, "valid") end)

      send(pid, {:headers, headers})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    headers = [{:x_Invalid, "any value"}, {"NotValid", "whoops!"}]

    {_result, log} =
      with_log(fn ->
        Req.new(invalid_header_keys: :ignore, url: c.url, headers: headers)
        |> Req.get!()
      end)

    expected_headers = [{"x-invalid", "any value"}, {"notvalid", "whoops!"}]

    assert_receive {:headers, headers}

    header_set = MapSet.new(headers)

    assert Enum.all?(expected_headers, &MapSet.member?(header_set, &1))

    refute log =~ ~r/is not lowercase/
  end

  test "header validation raises if option :raise set and invalid header key sent",
       c do
    headers = [{:x_Invalid, "any value"}, {"NotValid", "whoops!"}]

    assert_raise(RuntimeError, ~r/[x_Invalid|NotValid]/, fn ->
      Req.new(invalid_header_keys: :raise, url: c.url, headers: headers)
      |> Req.get!()
    end)
  end

  test "redact" do
    assert inspect(Req.new(auth: {:bearer, "foo"})) =~ ~s|auth: {:bearer, "[redacted]"}|

    assert inspect(Req.new(headers: [authorization: "bearer foo"])) =~
             ~s|{"authorization", "[redacted]"}|
  end
end
