defmodule ReqTest do
  use ExUnit.Case, async: true

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

    test "post!/3", c do
      Bypass.expect(c.bypass, "POST", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.post!(c.url <> "/json", {:json, %{foo: "bar"}}).body == %{"a" => 1}
    end

    test "put!/3", c do
      Bypass.expect(c.bypass, "PUT", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.put!(c.url <> "/json", {:json, %{foo: "bar"}}).body == %{"a" => 1}
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

  test "raw mode", c do
    raw = :zlib.gzip(Jason.encode_to_iodata!(%{"a" => 1}))

    Bypass.expect(c.bypass, "GET", "/json+gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, raw)
    end)

    assert Req.get!(c.url <> "/json+gzip", raw: true).body == raw
  end

  ## Finch errors

  test "pool timeout", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [finch_options: [pool_timeout: 0]]
    assert {:timeout, _} = catch_exit(Req.get!(c.url <> "/", options))
  end

  test "receive timeout", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      Process.sleep(1000)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [finch_options: [receive_timeout: 0]]

    assert {:error, %Mint.TransportError{reason: :timeout}} =
             Req.request(:get, c.url <> "/", options)

    # TODO:
    # when this is uncommented, we'll get an exit shutdown, figure out why
    # Process.sleep(1000)
  end
end
