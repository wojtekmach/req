defmodule Req.DecompressTest do
  use Req.Case, async: true

  test "does not set accept-encoding by default" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "accept-encoding") == []
          send_resp_gzip(conn, "foo")
        end
      )

    resp = Req.get!(req)
    assert Req.Response.get_header(resp, "content-encoding") == ["gzip"]
    assert resp.body == :zlib.gzip("foo")
  end

  test "does not set accept-encoding with into: collectable" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "accept-encoding") == []
          send_resp(conn, 200, "")
        end
      )

    Req.get!(req, compressed: true, into: [])
  end

  test "does not set accept-encoding with into: fun" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "accept-encoding") == []
          send_resp(conn, 200, "foo")
        end
      )

    resp =
      Req.get!(req,
        compressed: true,
        into: fn {:data, data}, {req, resp} ->
          {:cont, {req, update_in(resp.body, &(&1 <> data))}}
        end
      )

    assert resp.body == "foo"
  end

  describe "gzip" do
    test "success" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
            if System.otp_release() >= "28" do
              assert get_req_header(conn, "accept-encoding") == ["zstd, br, gzip"]
            else
              assert get_req_header(conn, "accept-encoding") == ["br, gzip"]
            end

            conn
            |> put_resp_header("content-encoding", "x-gzip")
            |> send_resp_gzip("foo")
          end
        )

      resp = Req.get!(req, compressed: true)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "error" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header("content-encoding", "x-gzip")
            |> send_resp(200, "bad")
          end
        )

      assert_raise Req.DecompressError, "gzip decompression failed", fn ->
        Req.get!(req, compressed: true)
      end
    end
  end

  test "identity" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "identity")
          |> send_resp(200, "foo")
        end
      )

    resp = Req.get!(req, compressed: true)
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == "foo"
  end

  describe "brotli" do
    test "success" do
      %{req: req} =
        serve("GET /": &send_resp_br(&1, "foo"))

      resp = Req.get!(req, compressed: true)
      assert resp.body == "foo"
    end

    test "error" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header("content-encoding", "br")
            |> send_resp(200, "bad")
          end
        )

      assert_raise Req.DecompressError, "br decompression failed", fn ->
        Req.get!(req, compressed: true)
      end
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  end

  describe "zstd" do
    @tag skip: System.otp_release() < "28"
    test "success" do
      %{req: req} =
        serve("GET /": &send_resp_zstd(&1, "foo"))

      resp = Req.get!(req, compressed: true)
      assert resp.body == "foo"
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "error" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header("content-encoding", "zstd")
            |> send_resp(200, "bad")
          end
        )

      assert_raise Req.DecompressError,
                   ~S[zstd decompression failed, reason: "Unknown frame descriptor"],
                   fn ->
                     Req.get!(req, compressed: true)
                   end
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  end

  @tag skip: System.otp_release() < "28"
  test "multiple codecs" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "gzip, zstd")
          |> send_resp(200, "foo" |> :zlib.gzip() |> :zstd.compress())
        end
      )

    resp = Req.get!(req, compressed: true)
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == "foo"
  end

  # TODO: Remove the OTP check when requiring OTP 28 (Elixir 1.21/22?).
  @tag skip: System.otp_release() < "28" or Req.Case.adapter() == :httpc
  test "multiple codecs with multiple headers" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          body = "foo" |> :zlib.gzip() |> :zstd.compress()

          conn
          |> prepend_resp_headers([
            {"content-encoding", "gzip"},
            {"content-encoding", "zstd"}
          ])
          |> send_resp(200, body)
        end
      )

    resp = Req.get!(req, compressed: true)
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert Req.Response.get_header(resp, "content-length") == []
    assert resp.body == "foo"
  end

  @tag :capture_log
  test "unknown codecs" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "unknown1, unknown2")
          |> send_resp(200, <<1, 2, 3>>)
        end
      )

    resp = Req.get!(req, compressed: true)
    assert Req.Response.get_header(resp, "content-encoding") == ["unknown1, unknown2"]
    assert resp.body == <<1, 2, 3>>
  end

  test "HEAD request" do
    %{req: req} =
      serve("HEAD /": &send_resp_gzip(&1, ""))

    assert Req.head!(req, compressed: true).body == ""
  end
end
