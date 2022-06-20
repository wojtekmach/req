defmodule ReqTest do
  use ExUnit.Case, async: true

  doctest Req,
    only: [
      new: 1
    ]

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "foo" do
    Req.request!(url: "https://httpbin.org/anything", connect_options: [protocol: :http2])
    |> IO.inspect()
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
end
