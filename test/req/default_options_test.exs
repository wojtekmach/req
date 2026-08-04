defmodule Req.DefaultOptionsTest do
  use Req.Case

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "default options", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      send(pid, {:params, conn.params})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    Req.default_options(params: %{"foo" => "bar"})
    resp = Req.stream!(c.url)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_received {:params, %{"foo" => "bar"}}
  after
    Application.put_env(:req, :default_options, [])
  end
end
