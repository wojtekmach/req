defmodule Req.RequestTest do
  use Req.Case, async: true
  # new/1 and run_request/1 doctests hit api.github.com, they run as part of
  # integration tests instead.
  doctest Req.Request, except: [delete_header: 2, new: 1, run_request: 1]

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "low-level API", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request = new(url: c.url <> "/ok")
    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "merge_options/2: deprecated options" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Req.Request.merge_options(Req.new(), url: "foo", headers: "bar")
      end)

    assert output =~ "Passing :url/:headers is deprecated"
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

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "step as MFArgs", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url)
      |> Req.Request.prepend_request_steps(foo: {__MODULE__, :simple_step, [:hi]})

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_received :hi
  end

  def simple_step(request, what) do
    send(self(), what)
    request
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

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "from cache - updated"
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

    {:error, err} = Req.Request.run(request)
    assert err == %RuntimeError{message: "oops - updated"}
  end

  test "request step halts with response", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          Req.Request.halt(request, %Req.Response{status: 200, body: "from cache"})
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "from cache"
    assert resp.request.halted == true
  end

  test "request step halts with exception", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          Req.Request.halt(request, RuntimeError.exception("oops"))
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    {:error, err} = Req.Request.run(request)
    assert err == %RuntimeError{message: "oops"}
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

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok - updated"
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

    {:error, err} = Req.Request.run(request)
    assert err == %RuntimeError{message: "oops - updated"}
  end

  test "response step halts with response", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          Req.Request.halt(request, update_in(response.body, &(&1 <> " - updated")))
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok - updated"
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
          Req.Request.halt(request, RuntimeError.exception("oops"))
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    {:error, err} = Req.Request.run(request)
    assert err == %RuntimeError{message: "oops"}
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

    {:error, err} = Req.Request.run(request)
    assert err == %RuntimeError{message: "oops"}
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

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok - updated"
  end

  test "error step halts with response", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          Req.Request.halt(request, %Req.Response{status: 200, body: "ok"})
        end,
        bar: &unreachable/1
      )

    {:ok, resp} = Req.Request.run(request)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "IEx.Info" do
    info = IEx.Info.info(Req.new(url: "https://elixir-lang.org"))

    assert get_key(info, "Data type") == "Req.Request"
    assert get_key(info, "Description") == "The request struct."

    assert get_key(info, "Raw representation") =~
             ~r/^%Req.Request\{.*request_steps: \[.*\].*\}$/s

    assert get_key(info, "Reference modules") == "Req.Request, Req"
  end

  ## Helpers

  defp get_key(info, key) do
    {^key, value} = List.keyfind(info, key, 0)
    value
  end

  defp new(options) do
    options = Keyword.update(options, :url, nil, &URI.parse/1)
    struct!(Req.Request, options)
  end

  defp unreachable(_) do
    raise "unreachable"
  end
end
