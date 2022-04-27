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

  describe "high-level API" do
    test "get!/2", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.get!(c.url).body == %{"a" => 1}
    end

    test "post!/2", c do
      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.post!(c.url, json: %{foo: "bar"}).body == %{"a" => 1}
    end

    test "put!/2", c do
      Bypass.expect(c.bypass, "PUT", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.put!(c.url, json: %{foo: "bar"}).body == %{"a" => 1}
    end

    test "delete!/2", c do
      Bypass.expect(c.bypass, "DELETE", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert Req.delete!(c.url).body == "ok"
    end
  end
end
