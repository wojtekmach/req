defmodule Req.RedirectTest do
  use Req.Case, async: true

  test "ignore when :redirect is false" do
    %{req: req, url: url} =
      serve("GET /redirect": &send_redirect(&1, 302, "/ok"))

    resp = Req.get!(req, url: "#{url}/redirect", redirect: false)
    assert resp.status == 302
  end

  test "absolute" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": fn conn ->
          send_redirect(conn, 302, "http://#{conn.host}:#{conn.port}/ok")
        end,
        "GET /ok": fn conn ->
          send_redirect(conn, 200, "/ok")
        end
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect", retry: false)
             assert resp.status == 200
           end) =~ "[debug] redirecting to #{url}/ok\n"
  end

  test "re-runs request steps on each hop" do
    pid = self()

    %{req: req, url: url} =
      serve(
        "GET /redirect": &send_redirect(&1, 302, "/ok"),
        "GET /ok": &send_resp(&1, 200, "ok")
      )

    req =
      Req.Request.append_request_steps(req,
        count: fn request ->
          send(pid, :step_ran)
          request
        end
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect")
             assert resp.status == 200
           end) =~ "[debug] redirecting to /ok\n"

    # 1 initial request + 1 redirect hop
    assert_received :step_ran
    assert_received :step_ran
    refute_received _
  end

  test "follows redirect with malformed compressed body" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": fn conn ->
          conn
          |> put_resp_header("content-encoding", "gzip")
          |> put_resp_header("location", "/ok")
          |> send_resp(302, "bad gzip")
        end,
        "GET /ok": &send_resp(&1, 200, "ok")
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             response = Req.get!(req, url: "#{url}/redirect", compressed: true)
             assert response.status == 200
             assert response.body == "ok"
           end) =~ "[debug] redirecting to /ok\n"
  end

  test "relative" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": fn conn ->
          location =
            case conn.query_string do
              "" -> "/ok"
              string -> "/ok?" <> string
            end

          send_redirect(conn, 302, location)
        end,
        "GET /ok": &send_resp(&1, 200, &1.query_string)
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             response = Req.get!(req, url: "#{url}/redirect")
             assert response.status == 200
             assert response.body == ""
           end) =~ "[debug] redirecting to /ok\n"

    assert ExUnit.CaptureLog.capture_log(fn ->
             response = Req.get!(req, url: "#{url}/redirect?a=1")
             assert response.status == 200
             assert response.body == "a=1"
           end) =~ "[debug] redirecting to /ok?a=1\n"
  end

  test "change POST to GET to get on 301..303" do
    for status <- 301..303 do
      %{req: req, url: url} =
        serve(
          "POST /redirect": fn conn ->
            send_redirect(conn, status, "http://#{conn.host}:#{conn.port}/ok")
          end,
          "GET /ok": &send_resp(&1, 200, "ok")
        )

      assert ExUnit.CaptureLog.capture_log(fn ->
               resp = Req.post!(req, url: "#{url}/redirect", body: "body")
               assert resp.status == 200
             end) =~ "[debug] redirecting to #{url}/ok\n"
    end
  end

  @tag :capture_log
  test "change POST to GET drops the request body" do
    %{req: req, url: url} =
      serve(
        "POST /redirect": fn conn ->
          send_redirect(conn, 303, "http://#{conn.host}:#{conn.port}/ok")
        end,
        "GET /ok": fn conn ->
          {:ok, body, conn} = read_body(conn)
          assert body == ""
          assert get_req_header(conn, "content-type") == []
          send_resp(conn, 200, "ok")
        end
      )

    resp = Req.post!(req, url: "#{url}/redirect", json: %{a: 1})
    assert resp.status == 200
  end

  test "do not change method on 307 and 308" do
    for status <- [307, 308] do
      %{req: req, url: url} =
        serve(
          "POST /redirect": fn conn ->
            send_redirect(conn, status, "http://#{conn.host}:#{conn.port}/ok")
          end,
          "POST /ok": &send_resp(&1, 200, "ok")
        )

      assert ExUnit.CaptureLog.capture_log(fn ->
               resp = Req.post!(req, url: "#{url}/redirect", body: "body")
               assert resp.status == 200
             end) =~ "[debug] redirecting to #{url}/ok\n"
    end
  end

  test "never change HEAD requests" do
    for status <- [301, 302, 303, 307, 307] do
      %{req: req, url: url} =
        serve(
          "HEAD /redirect": fn conn ->
            send_redirect(conn, status, "http://#{conn.host}:#{conn.port}/ok")
          end,
          "HEAD /ok": &send_resp(&1, 200, "")
        )

      assert ExUnit.CaptureLog.capture_log(fn ->
               resp = Req.head!(req, url: "#{url}/redirect")
               assert resp.status == 200
             end) =~ "[debug] redirecting to #{url}/ok\n"
    end
  end

  test "without location" do
    %{req: req, url: url} =
      serve(
        "POST /redirect": fn conn ->
          send_resp(conn, 303, "")
        end
      )

    resp = Req.post!(req, url: "#{url}/redirect")
    assert resp.status == 303
  end

  test "auth same host" do
    auth_header = {"authorization", "Basic " <> Base.encode64("foo:bar")}

    %{req: req, url: url} =
      serve(fn
        conn when conn.request_path == "/redirect" ->
          assert auth_header in conn.req_headers
          send_redirect(conn, 302, "http://#{conn.host}:#{conn.port}/auth")

        conn when conn.request_path == "/auth" ->
          assert auth_header in conn.req_headers
          send_resp(conn, 200, "ok")
      end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect", auth: {:basic, "foo:bar"})
             assert resp.status == 200
           end) =~ "[debug] redirecting to #{url}/auth\n"
  end

  test "auth location trusted" do
    %{req: req, url: url} =
      serve(fn
        conn when conn.host == "localhost" ->
          assert [_] = get_req_header(conn, "authorization")
          send_redirect(conn, 301, "http://127.0.0.1:#{conn.port}/ok")

        conn when conn.host == "127.0.0.1" ->
          assert [_] = get_req_header(conn, "authorization")
          send_resp(conn, 200, "ok")
      end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp =
               Req.get!(req, auth: {:basic, "authorization:credentials"}, redirect_trusted: true)

             assert resp.status == 200
           end) =~ "[debug] redirecting to http://127.0.0.1:#{url.port}/ok\n"
  end

  test "auth different host" do
    %{req: req, url: url} =
      serve(fn
        conn when conn.host == "localhost" ->
          assert [_] = get_req_header(conn, "authorization")
          send_redirect(conn, 301, "http://127.0.0.1:#{conn.port}/ok")

        conn when conn.host == "127.0.0.1" ->
          assert [] = get_req_header(conn, "authorization")
          send_resp(conn, 200, "ok")
      end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, auth: {:basic, "foo:bar"})
             assert resp.status == 200
           end) =~ "[debug] redirecting to http://127.0.0.1:#{url.port}/ok\n"
  end

  @tag :transport
  test "auth different port" do
    %{url: untrusted_url} =
      start_http_server(fn conn ->
        assert [] = get_req_header(conn, "authorization")
        send_resp(conn, 200, "ok")
      end)

    %{url: trusted_url} =
      start_http_server(fn conn ->
        assert ["Basic " <> _] = get_req_header(conn, "authorization")
        send_redirect(conn, 301, "#{untrusted_url}/ok")
      end)

    req = Req.new(url: trusted_url, adapter: adapter_fun())

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, auth: {:basic, "foo:bar"})
             assert resp.status == 200
           end) =~ "[debug] redirecting to #{untrusted_url}/ok\n"
  end

  @tag :transport
  test "auth different scheme" do
    %{url: untrusted_url} =
      start_https_server(fn conn ->
        assert [] = get_req_header(conn, "authorization")
        send_resp(conn, 200, "ok")
      end)

    %{url: trusted_url} =
      start_http_server(fn conn ->
        assert ["Basic " <> _] = get_req_header(conn, "authorization")
        send_redirect(conn, 301, "#{untrusted_url}/ok")
      end)

    req =
      Req.new(
        url: trusted_url,
        adapter: adapter_fun(),
        connect_options: [transport_opts: [cacertfile: "#{__DIR__}/../support/ca.pem"]]
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, auth: {:basic, "authorization:credentials"})
             assert resp.status == 200
           end) =~ "[debug] redirecting to #{untrusted_url}/ok\n"
  end

  test "userinfo in absolute location is stripped and warned about" do
    %{req: req, url: url} =
      serve(fn
        conn when conn.host == "localhost" ->
          location =
            to_string(%URI{
              scheme: "#{conn.scheme}",
              userinfo: "foo:bar",
              host: "127.0.0.1",
              port: conn.port,
              path: "/path"
            })

          send_redirect(conn, 302, location)

        conn when conn.host == "127.0.0.1" ->
          assert [] = get_req_header(conn, "authorization")
          send_resp(conn, 200, "ok")
      end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        resp = Req.get!(req)
        assert resp.status == 200
      end)

    assert log =~ "[warning] stripping userinfo from redirect location\n"
    assert log =~ "[debug] redirecting to http://127.0.0.1:#{url.port}/path\n"
  end

  test "skip params" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": fn conn ->
          send_redirect(conn, 302, "http://#{conn.host}:#{conn.port}/ok")
        end,
        "GET /ok": fn conn ->
          assert conn.query_string == ""
          send_resp(conn, 200, "ok")
        end
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect", params: [a: 1])
             assert resp.status == 200
           end) =~ "[debug] redirecting to #{url}/ok\n"
  end

  test "max redirects" do
    pid = self()

    %{req: req} =
      serve(
        "GET /": fn conn ->
          send(pid, :ping)
          send_redirect(conn, 302, "http://#{conn.host}:#{conn.port}/")
        end
      )

    req = Req.merge(req, max_redirects: 3, redirect_log_level: false)

    {req, e} = Req.Request.run_request(req)

    assert_receive :ping
    assert_receive :ping
    assert_receive :ping
    assert_receive :ping
    refute_receive _

    assert req.private == %{req_redirect_count: 3}
    assert Exception.message(e) == "too many redirects (3)"
  end

  test "redirect_log_level, default to :debug" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": &send_redirect(&1, 302, "/ok"),
        "GET /ok": &send_resp(&1, 200, "ok")
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect")
             assert resp.status == 200
           end) =~ "[debug] redirecting to /ok\n"
  end

  test "redirect_log_level, set to :error" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": &send_redirect(&1, 302, "/ok"),
        "GET /ok": &send_resp(&1, 200, "ok")
      )

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect", redirect_log_level: :error)
             assert resp.status == 200
           end) =~ "[error] redirecting to /ok\n"
  end

  test "redirect_log_level, disabled" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": &send_redirect(&1, 302, "/ok"),
        "GET /ok": &send_resp(&1, 200, "ok")
      )

    resp = Req.get!(req, url: "#{url}/redirect", redirect_log_level: false)
    assert resp.status == 200
  end

  test "inherit scheme" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": fn conn ->
          send_redirect(conn, 302, "//#{conn.host}:#{conn.port}/ok")
        end,
        "GET /ok": &send_resp(&1, 200, "ok")
      )

    "http:" <> no_scheme = "#{url}"

    assert ExUnit.CaptureLog.capture_log(fn ->
             resp = Req.get!(req, url: "#{url}/redirect")
             assert resp.status == 200
           end) =~ "[debug] redirecting to #{no_scheme}/ok\n"
  end
end
