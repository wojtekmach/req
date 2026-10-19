defmodule Req.RequestTest do
  use Req.Case, async: true
  # new/1 doctests hit api.github.com, they run as part of
  # integration tests instead.
  doctest Req.Request, except: [delete_header: 2, new: 1]

  test "low-level API" do
    %{url: url} =
      start_http_server(fn conn ->
        assert conn.request_path == "/ok"
        send_resp(conn, 200, "ok")
      end)

    request = new(url: URI.append_path(url, "/ok"))
    resp = Req.stream!(request)
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

  test "simple request step" do
    %{url: url} =
      start_http_server(fn conn ->
        assert conn.request_path == "/ok"
        send_resp(conn, 200, "ok")
      end)

    request =
      new(url: URI.append_path(url, "/not-found"))
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          put_in(request.url.path, "/ok")
        end
      )

    resp = Req.stream!(request)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "step wrapper as function" do
    %{url: url} =
      start_http_server(fn conn ->
        assert conn.request_path == "/ok"
        send_resp(conn, 200, "ok")
      end)

    caller = self()

    wrapper = fn req, acc, fun, state, next ->
      wrapped_fun = fn
        {:status, status} = event, resp, acc, state ->
          send(caller, {:wrapper, req.url.path, status})
          fun.(event, resp, acc, state)

        event, resp, acc, state ->
          fun.(event, resp, acc, state)
      end

      next.(req, acc, wrapped_fun, state)
    end

    request =
      new(url: URI.append_path(url, "/ok"))
      |> Req.Request.prepend_request_steps(wrapper: wrapper)

    resp = Req.stream!(request)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_received {:wrapper, "/ok", 200}
  end

  test "step as MFArgs" do
    %{url: url} =
      start_http_server(fn conn ->
        assert conn.request_path == "/"
        send_resp(conn, 200, "ok")
      end)

    request =
      new(url: url)
      |> Req.Request.prepend_request_steps(foo: {__MODULE__, :simple_step, [:hi]})

    resp = Req.stream!(request)
    assert resp.status == 200
    assert resp.body == "ok"
    assert_received :hi
  end

  def simple_step(request, what) do
    send(self(), what)
    request
  end

  test "response steps" do
    %{url: url} =
      start_http_server(fn conn ->
        assert conn.request_path == "/ok"
        send_resp(conn, 200, "ok")
      end)

    request = new(url: URI.append_path(url, "/ok"))

    request =
      put_in(request.response_steps,
        upcase: fn {request, response} ->
          response = update_in(response.body, &String.upcase/1)
          {request, response}
        end
      )

    resp = Req.stream!(request)
    assert resp.status == 200
    assert resp.body == "OK"
  end

  test "error steps" do
    request = new(url: "http://localhost:9999/ok")

    request =
      put_in(request.error_steps,
        wrap: fn {request, exception} ->
          {request, %RuntimeError{message: "wrapped: " <> Exception.message(exception)}}
        end
      )

    {:error, err, _resp} = Req.stream(request)
    assert err == %RuntimeError{message: "wrapped: connection refused"}
  end

  test "transport error" do
    request = new(url: "http://localhost:9999/ok")

    {:error, err, resp} = Req.stream(request)
    assert err == %Req.TransportError{reason: :econnrefused}
    assert resp.status == nil
    assert resp.body == ""
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
end
