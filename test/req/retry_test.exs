defmodule Req.RetryTest do
  use Req.Case, async: true

  @tag :capture_log
  test "eventually successful - function" do
    %{req: req, url: url} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    request = Req.merge(req, retry_delay: &Integer.pow(2, &1))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, resp} = Req.stream(request)
        assert resp.request.private.req_retry_count == 3
        assert resp.status == 200
        assert resp.body == "ok"
        assert URI.to_string(resp.request.url) == "#{url}"
      end)

    assert log =~
             "[warning] retry: got response with status 500, will retry in 1ms, 3 attempts left\n"

    assert log =~
             "[warning] retry: got response with status 500, will retry in 2ms, 2 attempts left\n"

    assert log =~
             "[warning] retry: got response with status 500, will retry in 4ms, 1 attempt left\n"
  end

  test "invalid :retry_delay" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          send_resp(conn, 500, "")
        end
      )

    req = Req.merge(req, retry_delay: fn _ -> :ok end)

    assert_raise ArgumentError,
                 "expected :retry_delay function to return non-negative integer, got: :ok",
                 fn ->
                   Req.stream!(req)
                 end
  end

  @tag :capture_log
  test "eventually successful - integer" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    request = Req.merge(req, retry_delay: 1)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, resp} = Req.stream(request)
        assert resp.request.private.req_retry_count == 2
        assert resp.status == 200
        assert resp.body == "ok"
      end)

    assert log =~
             "[warning] retry: got response with status 500, will retry in 1ms, 3 attempts left\n"

    assert log =~
             "[warning] retry: got response with status 500, will retry in 1ms, 2 attempts left\n"
  end

  @tag :capture_log
  test "default log_level" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    request = Req.merge(req, retry_delay: 1)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        resp = Req.stream!(request)
        assert resp.status == 200
        assert resp.body == "ok"
      end)

    assert log =~
             "[warning] retry: got response with status 500, will retry in 1ms, 3 attempts left\n"
  end

  @tag :capture_log
  test "custom log_level" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    request = Req.merge(req, retry_delay: 1, retry_log_level: :info)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        resp = Req.stream!(request)
        assert resp.status == 200
        assert resp.body == "ok"
      end)

    assert log =~
             "[info] retry: got response with status 500, will retry in 1ms, 3 attempts left\n"
  end

  test "logging disabled" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    request = Req.merge(req, retry_delay: 1, retry_log_level: false)
    resp = Req.stream!(request)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "does not retry response with malformed compressed body" do
    pid = self()

    %{req: req} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)

          conn
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(500, "bad gzip")
        end
      )

    {:error, err, resp} = Req.stream(req, compressed: true, retry_delay: 1)
    assert err == %Req.DecompressError{format: :gzip, data: "bad gzip", reason: :data_error}
    assert resp.status == 500
    assert resp.body == ""

    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "retry-after" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp_retry_after(&1, 0),
        "GET /": &send_resp_retry_after(%{&1 | status: 503}, DateTime.add(DateTime.utc_now(), 2)),
        "GET /": &send_resp(&1, 200, "ok")
      )

    resp = Req.stream!(req, max_retries: 5)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  @tag :capture_log
  test ":retry_delay" do
    pid = self()

    %{req: req} =
      serve_sequence(
        "GET /": &send_resp_retry_after(&1, 0),
        "GET /": &send_resp_retry_after(&1, -1),
        "GET /": &send_resp_retry_after(%{&1 | status: 503}, DateTime.utc_now()),
        "GET /":
          &send_resp_retry_after(%{&1 | status: 503}, DateTime.add(DateTime.utc_now(), -3600)),
        "GET /": &send_resp(&1, 200, "ok")
      )

    retry_delay = fn retry_count ->
      send(pid, {:retry_delay, retry_count})
      0
    end

    resp = Req.stream!(req, retry_delay: retry_delay, max_retries: 5)
    assert resp.status == 200
    assert resp.body == "ok"

    assert_received {:retry_delay, 0}
    assert_received {:retry_delay, 1}
    assert_received {:retry_delay, 2}
    assert_received {:retry_delay, 3}
  end

  @tag :capture_log
  test "retry: fun sees req.private.req_retry_count" do
    pid = self()

    %{req: req} =
      serve(
        "GET /": fn conn ->
          send_resp(conn, 500, "oops")
        end
      )

    retry_fun = fn req, resp ->
      send(pid, {:retry_count, req.private[:req_retry_count]})
      resp.status == 500
    end

    {req, resp} = Req.run(req, retry: retry_fun, retry_delay: 1)
    assert req.private.req_retry_count == 3
    assert resp.status == 500
    assert resp.body == "oops"

    assert_received {:retry_count, nil}
    assert_received {:retry_count, 1}
    assert_received {:retry_count, 2}
    assert_received {:retry_count, 3}
    refute_received {:retry_count, _}
  end

  @tag :capture_log
  test "always failing" do
    pid = self()

    %{req: request} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry_delay: 1)

    {:ok, resp} = Req.stream(request)
    assert resp.request.private.req_retry_count == 3
    assert resp.status == 500
    assert resp.body == "oops"

    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "retry: :safe_transient does not retry on POST" do
    pid = self()

    %{req: request} =
      serve(
        "POST /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry: :safe_transient, max_retries: 10)

    resp = Req.stream!(request, method: :post)
    assert resp.status == 500
    assert resp.body == "oops"
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "retry: :transient retries on POST" do
    pid = self()

    %{req: request} =
      serve(
        "POST /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry: :transient, retry_delay: 1, max_retries: 1)

    resp = Req.stream!(request, method: :post)
    assert resp.status == 500
    assert resp.body == "oops"
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  test "retry: false" do
    pid = self()

    %{req: request} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry: false)

    resp = Req.stream!(request)
    assert resp.status == 500
    assert resp.body == "oops"
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "custom function returning true" do
    pid = self()

    fun = fn _request, response ->
      assert response.status == 500
      true
    end

    %{req: request} =
      serve(
        "POST /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry: fun, retry_delay: 1)

    resp = Req.stream!(request, method: :post)
    assert resp.status == 500
    assert resp.body == "oops"
    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  test "custom function receives response without body" do
    pid = self()

    fun = fn _request, response ->
      # TODO: decide whether to stuff acc into resp.body here (#413)
      send(pid, {:retry, response.status, response.body})
      false
    end

    %{req: req} = serve("GET /": &send_resp(&1, 500, "oops"))

    {:ok, resp} = Req.stream(req, retry: fun)
    assert resp.status == 500
    assert resp.body == "oops"

    assert_received {:retry, 500, nil}
    refute_received _
  end

  @tag :capture_log
  test "custom function returning {:delay, milliseconds}" do
    pid = self()

    fun = fn _request, response ->
      assert response.status == 500
      {:delay, 1}
    end

    %{req: request} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry: fun)

    resp = Req.stream!(request)
    assert resp.status == 500
    assert resp.body == "oops"
    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "raise on custom function returning {:delay, milliseconds} when `:retry_delay` is provided" do
    pid = self()

    fun = fn _request, response ->
      assert response.status == 500
      {:delay, 1}
    end

    %{req: request} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    request = Req.merge(request, retry: fun, retry_delay: 1)

    assert_raise ArgumentError,
                 "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`",
                 fn -> Req.stream!(request) end
  end

  @tag :capture_log
  test "does not re-encode params" do
    pid = self()

    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert conn.query_string == "a=1&b=2"
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    resp = Req.stream!(req, params: [a: 1, b: 2], retry_delay: 1)
    assert resp.status == 500
    assert resp.body == "oops"
    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "stream" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        retry_delay: 1
      )

    assert resp.status == 200
    assert resp.body == nil
    assert acc == ["ok"]
  end

  @tag :capture_log
  test "stream always failing" do
    pid = self()

    %{req: req} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)
          send_resp(conn, 500, "oops")
        end
      )

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        retry_delay: 1
      )

    assert resp.status == 500
    assert acc == ["oops"]

    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "re-runs request steps on each attempt" do
    pid = self()

    %{req: req} =
      serve("GET /": &send_resp(&1, 500, "oops"))

    req =
      Req.Request.append_request_steps(req,
        count: fn request ->
          send(pid, :step_ran)
          request
        end
      )

    resp = Req.stream!(req, retry_delay: 1, max_retries: 3)
    assert resp.status == 500
    assert resp.body == "oops"

    # 1 initial attempt + 3 retries
    assert_received :step_ran
    assert_received :step_ran
    assert_received :step_ran
    assert_received :step_ran
    refute_received _
  end
end
