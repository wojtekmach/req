defmodule Req.RetryTest do
  use Req.Case, async: true

  @tag :capture_log
  test "eventually successful - function" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 500, "oops"),
        "GET /": &send_resp(&1, 200, "ok")
      )

    request =
      Req.merge(req, retry_delay: &Integer.pow(2, &1))
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {request, response} = Req.Request.run_request(request)
        assert request.private.req_retry_count == 3
        assert response.body == "ok - updated"
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
                   Req.request!(req)
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

    request =
      Req.merge(req, retry_delay: 1)
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        response = Req.get!(request)
        assert response.body == "ok - updated"
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
    log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)

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

    log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)

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
    Req.get!(request)
  end

  @tag :capture_log
  test "retries response with malformed compressed body" do
    %{req: req} =
      serve_sequence(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(500, "bad gzip")
        end,
        "GET /": &send_resp(&1, 200, "ok")
      )

    response = Req.get!(req, compressed: true, retry_delay: 1)
    assert response.status == 200
    assert response.body == "ok"
  end

  @tag :capture_log
  test "retry-after" do
    %{req: req} =
      serve_sequence(
        "GET /": &send_resp_retry_after(&1, 0),
        "GET /": &send_resp_retry_after(%{&1 | status: 503}, DateTime.add(DateTime.utc_now(), 2)),
        "GET /": &send_resp(&1, 200, "ok")
      )

    assert Req.request!(req, max_retries: 5).body == "ok"
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

    assert Req.request!(req, retry_delay: retry_delay, max_retries: 5).body == "ok"
    assert_received {:retry_delay, 0}
    assert_received {:retry_delay, 1}
    assert_received {:retry_delay, 2}
    assert_received {:retry_delay, 3}
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

    request =
      request
      |> Req.merge(retry_delay: 1)
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert Req.get!(request).body == "oops - updated"
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

    assert Req.post!(request).status == 500
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

    assert Req.post!(request).status == 500
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

    assert Req.get!(request).status == 500
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

    assert Req.post!(request).status == 500
    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
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

    assert Req.get!(request).status == 500
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
                 fn -> Req.get!(request) end
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

    assert Req.get!(req, params: [a: 1, b: 2], retry_delay: 1).status == 500
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

    assert Req.get!(req, retry_delay: 1, max_retries: 3).status == 500

    # 1 initial attempt + 3 retries
    assert_received :step_ran
    assert_received :step_ran
    assert_received :step_ran
    assert_received :step_ran
    refute_received _
  end
end
