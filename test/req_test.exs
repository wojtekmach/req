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

  ## Low-level API

  test "low-level API", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request = Req.Request.build(:get, c.url <> "/ok")
    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "simple request step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.Request.build(:get, c.url <> "/not-found")
      |> Req.Request.prepend_request_steps([
        fn request ->
          put_in(request.url.path, "/ok")
        end
      ])

    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "request step returns response", c do
    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_request_steps([
        fn request ->
          {request, %Req.Response{status: 200, body: "from cache"}}
        end
      ])
      |> Req.Request.prepend_response_steps([
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])

    assert {:ok, %{status: 200, body: "from cache - updated"}} = Req.Request.run(request)
  end

  test "request step returns exception", c do
    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_request_steps([
        fn request ->
          {request, RuntimeError.exception("oops")}
        end
      ])
      |> Req.Request.prepend_error_steps([
        fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      ])

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
  end

  test "request step halts with response", c do
    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_request_steps([
        fn request ->
          {Req.Request.halt(request), %Req.Response{status: 200, body: "from cache"}}
        end,
        &unreachable/1
      ])
      |> Req.Request.prepend_response_steps([
        &unreachable/1
      ])
      |> Req.Request.prepend_error_steps([
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "from cache"}} = Req.Request.run(request)
  end

  test "request step halts with exception", c do
    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_request_steps([
        fn request ->
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        &unreachable/1
      ])
      |> Req.Request.prepend_response_steps([
        &unreachable/1
      ])
      |> Req.Request.prepend_error_steps([
        &unreachable/1
      ])

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "simple response step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_response_steps([
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "response step returns exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_response_steps([
        fn {request, response} ->
          assert response.body == "ok"
          {request, RuntimeError.exception("oops")}
        end
      ])
      |> Req.Request.prepend_error_steps([
        fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      ])

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
  end

  test "response step halts with response", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_response_steps([
        fn {request, response} ->
          {Req.Request.halt(request), update_in(response.body, &(&1 <> " - updated"))}
        end,
        &unreachable/1
      ])
      |> Req.Request.prepend_error_steps([
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "response step halts with exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_response_steps([
        fn {request, response} ->
          assert response.body == "ok"
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        &unreachable/1
      ])
      |> Req.Request.prepend_error_steps([
        &unreachable/1
      ])

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "simple error step", c do
    Bypass.down(c.bypass)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_error_steps([
        fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, RuntimeError.exception("oops")}
        end
      ])

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "error step returns response", c do
    Bypass.down(c.bypass)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_response_steps([
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])
      |> Req.Request.prepend_error_steps([
        fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, %Req.Response{status: 200, body: "ok"}}
        end,
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "error step halts with response", c do
    Bypass.down(c.bypass)

    request =
      Req.Request.build(:get, c.url <> "/ok")
      |> Req.Request.prepend_response_steps([
        &unreachable/1
      ])
      |> Req.Request.prepend_error_steps([
        fn {request, exception} ->
          assert exception.reason == :econnrefused
          {Req.Request.halt(request), %Req.Response{status: 200, body: "ok"}}
        end,
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  ## Helpers

  defp unreachable(_) do
    raise "unreachable"
  end
end
