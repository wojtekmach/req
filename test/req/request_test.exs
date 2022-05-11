defmodule Req.RequestTest do
  use ExUnit.Case, async: true
  doctest Req.Request, only: [register_options: 2]

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "low-level API", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request = new(url: c.url <> "/ok")
    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "simple request step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/not-found")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          put_in(request.url.path, "/ok")
        end
      )

    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "prepare/1" do
    request =
      Req.new(method: :get, base_url: "http://foo", url: "/bar", auth: {"foo", "bar"})
      |> Req.Request.prepare()

    assert request.url == URI.parse("http://foo/bar")

    authorization = "Basic " <> Base.encode64("foo:bar")

    assert [
             {"authorization", ^authorization},
             {"accept-encoding", "br, gzip, deflate"},
             {"user-agent", "req/" <> _}
           ] = request.headers
  end

  test "request step returns response", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {request, %Req.Response{status: 200, body: "from cache"}}
        end
      )
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert {:ok, %{status: 200, body: "from cache - updated"}} = Req.Request.run(request)
  end

  test "request step returns exception", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {request, RuntimeError.exception("oops")}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      )

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
  end

  test "request step halts with response", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {Req.Request.halt(request), %Req.Response{status: 200, body: "from cache"}}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:ok, %{status: 200, body: "from cache"}} = Req.Request.run(request)
  end

  test "request step halts with exception", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "simple response step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "response step returns exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          assert response.body == "ok"
          {request, RuntimeError.exception("oops")}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      )

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
  end

  test "response step halts with response", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {Req.Request.halt(request), update_in(response.body, &(&1 <> " - updated"))}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "response step halts with exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          assert response.body == "ok"
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "simple error step", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, RuntimeError.exception("oops")}
        end
      )

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "error step returns response", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, %Req.Response{status: 200, body: "ok"}}
        end,
        bar: &unreachable/1
      )

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "error step halts with response", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          {Req.Request.halt(request), %Req.Response{status: 200, body: "ok"}}
        end,
        bar: &unreachable/1
      )

    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  ## Helpers

  defp new(options) do
    options = Keyword.update(options, :url, nil, &URI.parse/1)
    struct!(Req.Request, options)
  end

  defp unreachable(_) do
    raise "unreachable"
  end
end
