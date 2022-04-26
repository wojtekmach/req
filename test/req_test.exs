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
      Bypass.expect(c.bypass, "GET", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.get!(c.url <> "/json").body == %{"a" => 1}
    end

    test "post!/", c do
      Bypass.expect(c.bypass, "POST", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.post!(c.url <> "/json", body: {:json, %{foo: "bar"}}).body == %{"a" => 1}
    end

    test "put!/", c do
      Bypass.expect(c.bypass, "PUT", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.put!(c.url <> "/json", body: {:json, %{foo: "bar"}}).body == %{"a" => 1}
    end

    test "delete!/2", c do
      Bypass.expect(c.bypass, "DELETE", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.delete!(c.url <> "/json").body == %{"a" => 1}
    end
  end
end
