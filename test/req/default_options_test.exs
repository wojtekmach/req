defmodule Req.DefaultOptionsTest do
  use Req.Case, async: false

  test "default options" do
    pid = self()
    Req.default_options(params: %{"foo" => "bar"})

    %{req: req} =
      serve(fn conn ->
        conn = fetch_query_params(conn)
        send(pid, {:params, conn.query_params})
        send_resp(conn, 200, "ok")
      end)

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_received {:params, %{"foo" => "bar"}}
  after
    Application.put_env(:req, :default_options, [])
  end
end
