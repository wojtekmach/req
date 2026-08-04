defmodule Req.ChecksumTest do
  use Req.Case, async: true

  @foo_md5 "md5:acbd18db4cc2f85cedef654fccc4a4d8"
  @foo_sha1 "sha1:0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33"
  @foo_sha256 "sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"

  test "into: binary" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "foo"))

    resp = Req.stream!(req, checksum: @foo_md5)
    assert resp.status == 200
    assert resp.body == "foo"

    resp = Req.stream!(req, checksum: @foo_sha1)
    assert resp.status == 200
    assert resp.body == "foo"

    resp = Req.stream!(req, checksum: @foo_sha256)
    assert resp.status == 200
    assert resp.body == "foo"

    assert_raise Req.ChecksumMismatchError,
                 """
                 checksum mismatch
                 expected: sha1:bad
                 actual:   #{@foo_sha1}\
                 """,
                 fn ->
                   Req.stream!(req, checksum: "sha1:bad")
                 end
  end

  # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  @tag skip: System.otp_release() < "28"
  test "into: binary with gzip" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          ["zstd, br, gzip"] = get_req_header(conn, "accept-encoding")

          conn
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(200, :zlib.gzip("foo"))
        end
      )

    req = Req.merge(req, compressed: true)

    resp = Req.stream!(req, checksum: @foo_md5)
    assert resp.status == 200
    assert resp.body == "foo"

    assert_raise Req.ChecksumMismatchError,
                 """
                 checksum mismatch
                 expected: sha1:bad
                 actual:   #{@foo_sha1}\
                 """,
                 fn ->
                   Req.stream!(req, checksum: "sha1:bad")
                 end
  end

  test "into: fun" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "foo"))

    {req, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Req.merge(req,
          into: fn {:data, chunk}, {req, resp} ->
            {:cont, {req, update_in(resp.body, &(&1 <> chunk))}}
          end
        )
      end)

    resp = Req.request!(req, checksum: @foo_sha1)
    assert resp.status == 200
    assert resp.body == "foo"

    resp = Req.request!(req, checksum: @foo_sha256)
    assert resp.status == 200
    assert resp.body == "foo"

    assert_raise Req.ChecksumMismatchError,
                 """
                 checksum mismatch
                 expected: sha1:bad
                 actual:   #{@foo_sha1}\
                 """,
                 fn ->
                   Req.request!(req, checksum: "sha1:bad")
                 end
  end

  test "into: collectable" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "foo"))

    req = Req.merge(req, into: [])

    resp = Req.request!(req, checksum: @foo_sha1)
    assert resp.status == 200
    assert resp.body == ["foo"]

    resp = Req.request!(req, checksum: @foo_sha256)
    assert resp.status == 200
    assert resp.body == ["foo"]

    assert_raise Req.ChecksumMismatchError,
                 """
                 checksum mismatch
                 expected: sha1:bad
                 actual:   #{@foo_sha1}\
                 """,
                 fn ->
                   Req.request!(req, checksum: "sha1:bad")
                 end
  end

  test "into: :self" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "foo"))

    req = Req.merge(req, into: :self)

    assert_raise ArgumentError, ":checksum cannot be used with `into: :self`", fn ->
      Req.request!(req, checksum: @foo_sha1)
    end
  end

  test "stream" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "foo"))

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        checksum: @foo_sha1
      )

    assert resp.status == 200
    assert resp.body == nil
    assert acc == ["foo"]

    {:error, err, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        checksum: "sha1:bad"
      )

    assert err ==
             Req.ChecksumMismatchError.exception(expected: "sha1:bad", actual: @foo_sha1)

    assert resp.status == 200
    assert acc == ["foo"]
  end

  test "stream halt" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, "foo"))

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:halt, [data | acc]} end,
        checksum: "sha1:bad"
      )

    assert resp.status == 200
    assert acc == ["foo"]
  end

  test "stream with gzip" do
    %{req: req} =
      serve("GET /": &send_resp_gzip(&1, "foo"))

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        compressed: true,
        checksum: @foo_sha1
      )

    assert resp.status == 200
    assert IO.iodata_to_binary(Enum.reverse(acc)) == "foo"
  end

  test "verifies checksum before decoding" do
    body = ~s|{"foo":"bar"}|
    checksum = "sha256:" <> (:sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower))

    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)
        end
      )

    resp = Req.stream!(req, checksum: checksum)
    assert resp.status == 200
    assert resp.body == %{"foo" => "bar"}
  end
end
