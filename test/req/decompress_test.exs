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

    resp = Req.stream!(req)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["gzip"]
    assert resp.body == :zlib.gzip("foo")
  end

  test "does not set accept-encoding with into: fun" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "accept-encoding") == []
          send_resp(conn, 200, "foo")
        end
      )

    {resp, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Req.request!(req,
          compressed: true,
          into: fn {:data, data}, {req, resp} ->
            {:cont, {req, update_in(resp.body, &(&1 <> data))}}
          end
        )
      end)

    assert resp.status == 200
    assert resp.body == "foo"
  end

  test "raw" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          assert get_req_header(conn, "accept-encoding") != []
          send_resp_gzip(conn, "foo")
        end
      )

    resp = Req.stream!(req, compressed: true, raw: true)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["gzip"]
    assert resp.body == :zlib.gzip("foo")

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        compressed: true,
        raw: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["gzip"]
    assert resp.body == nil
    assert IO.iodata_to_binary(Enum.reverse(acc)) == :zlib.gzip("foo")
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

      resp = Req.stream!(req, compressed: true)
      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"

      {:ok, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == nil
      assert acc == ["foo"]
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

      {:error, err, resp} = Req.stream(req, compressed: true)
      assert err == %Req.DecompressError{format: :gzip, data: "bad", reason: :data_error}
      assert resp.status == 200
      assert resp.body == ""
      assert Exception.message(err) == "gzip decompression failed, reason: :data_error"

      {:error, err, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert err == %Req.DecompressError{format: :gzip, data: "bad", reason: :data_error}
      assert Exception.message(err) == "gzip decompression failed, reason: :data_error"
      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == nil
      assert acc == []
    end

    test "chunked" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            <<first::binary-size(10), rest::binary>> = :zlib.gzip("foo")

            conn =
              conn
              |> put_resp_header("content-encoding", "gzip")
              |> send_chunked(200)

            {:ok, conn} = chunk(conn, first)
            {:ok, conn} = chunk(conn, rest)
            conn
          end
        )

      resp = Req.stream!(req, compressed: true)
      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"

      {:ok, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, resp, acc ->
            assert Req.Response.get_header(resp, "content-encoding") == []
            {:cont, [data | acc]}
          end,
          compressed: true
        )

      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == nil
      assert IO.iodata_to_binary(Enum.reverse(acc)) == "foo"
    end

    test "truncated" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            <<first::binary-size(10), _rest::binary>> = :zlib.gzip("foo")

            conn
            |> put_resp_header("content-encoding", "gzip")
            |> send_resp(200, first)
          end
        )

      {:error, err, resp} = Req.stream(req, compressed: true)
      assert err == %Req.DecompressError{format: :gzip, reason: :data_error}
      assert resp.status == 200
      assert resp.body == ""

      {:error, err, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert err == %Req.DecompressError{format: :gzip, reason: :data_error}
      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == nil
      assert acc == []
    end

    @tag :transport
    @tag :capture_log
    @tag skip: adapter() == :httpc
    test "mid-stream transport error" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn =
              conn
              |> put_resp_header("content-encoding", "gzip")
              |> send_chunked(200)

            {:ok, conn} = chunk(conn, :zlib.gzip("foo"))
            raise "oops"
            conn
          end
        )

      {:error, err, resp} = Req.stream(req, compressed: true, retry: false)
      assert err == %Req.TransportError{reason: :closed}
      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"

      {:error, err, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true,
          retry: false
        )

      assert err == %Req.TransportError{reason: :closed}
      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == nil
      assert acc == ["foo"]
    end
  end

  test "stream step events" do
    req = Req.new(compressed: true)

    next = fn req, acc, fun, state ->
      resp =
        Req.Response.new(status: 200)
        |> Map.replace!(:request, req)
        |> Req.Response.put_header("content-encoding", "gzip")

      {:ok, resp, acc, state} = fun.({:status, 200}, resp, acc, state)
      {:ok, resp, acc, state} = fun.({:headers, resp.headers}, resp, acc, state)
      {:ok, resp, acc, state} = fun.({:data, :zlib.gzip("foo")}, resp, acc, state)
      {:ok, resp, acc, state} = fun.({:trailers, Req.Fields.new([])}, resp, acc, state)
      {:ok, resp, acc, state}
    end

    fun = fn
      {:headers, _headers} = event, resp, events, state ->
        resp = Req.Response.delete_header(resp, "content-encoding")
        {:ok, resp, [event | events], state}

      event, resp, events, state ->
        {:ok, resp, [event | events], state}
    end

    assert {:ok, resp, events, []} = Req.Decompress.stream(req, [], fun, [], next)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == ""

    assert [
             {:status, 200},
             {:headers, headers},
             {:data, "foo"},
             {:trailers, trailers}
           ] = Enum.reverse(events)

    assert Req.Fields.get_values(headers, "content-encoding") == ["gzip"]
    assert trailers == Req.Fields.new([])
  end

  test "multiple content encodings" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "gzip, gzip")
          |> send_resp(200, :zlib.gzip(:zlib.gzip("foo")))
        end
      )

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == "foo"

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        compressed: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == nil
    assert IO.iodata_to_binary(Enum.reverse(acc)) == "foo"
  end

  @tag :capture_log
  test "supported encoding followed by an unknown encoding" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "unknown, gzip")
          |> send_resp(200, :zlib.gzip("foo"))
        end
      )

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["unknown"]
    assert Req.Response.get_header(resp, "content-length") == []
    assert resp.body == "foo"

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        compressed: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["unknown"]
    assert Req.Response.get_header(resp, "content-length") == []
    assert resp.body == nil
    assert IO.iodata_to_binary(Enum.reverse(acc)) == "foo"
  end

  test "stream halt" do
    %{req: req} = serve("GET /": &send_resp_gzip(&1, "foo"))

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:halt, [data | acc]} end,
        compressed: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == nil
    assert acc == ["foo"]
  end

  test "HEAD" do
    %{req: req} =
      serve(
        "HEAD /": fn conn ->
          assert get_req_header(conn, "accept-encoding") != []

          conn
          |> put_resp_header("content-encoding", "x-gzip")
          |> send_resp_gzip("foo")
        end
      )

    resp = Req.stream!(req, method: :head, compressed: true)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["x-gzip"]
    assert resp.body == ""

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        method: :head,
        compressed: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["x-gzip"]
    assert resp.body == nil
    assert acc == []
  end

  test "bodyless response" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(204, "")
        end
      )

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 204
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == ""

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn _data, _resp, _acc -> flunk("bodyless response emitted data") end,
        compressed: true
      )

    assert resp.status == 204
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == nil
    assert acc == []
  end

  test "304 response with content-encoding" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(304, "")
        end
      )

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 304
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == ""

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn _data, _resp, _acc -> flunk("304 response emitted data") end,
        compressed: true
      )

    assert resp.status == 304
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == nil
    assert acc == []
  end

  @tag :capture_log
  test "redirect" do
    %{req: req, url: url} =
      serve(
        "GET /redirect": &send_redirect(&1, 302, "/"),
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/gzip")
          |> send_resp(200, :zlib.gzip("foo"))
        end
      )

    resp = Req.stream!(req, url: "#{url}/redirect", compressed: true, decoders: [:gz])
    assert resp.status == 200
    assert resp.body == "foo"
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

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == "foo"

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        compressed: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == nil
    assert acc == ["foo"]
  end

  describe "brotli" do
    test "success" do
      %{req: req} =
        serve("GET /": &send_resp_br(&1, "foo"))

      resp = Req.stream!(req, compressed: true)
      assert resp.status == 200
      assert resp.body == "foo"

      {:ok, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert resp.status == 200
      assert resp.body == nil
      assert acc == ["foo"]
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

      {:error, err, resp} = Req.stream(req, compressed: true)
      assert err == %Req.DecompressError{format: :br, reason: :brotli_error}
      assert resp.status == 200
      assert resp.body == ""
      assert Exception.message(err) == "br decompression failed, reason: :brotli_error"

      {:error, err, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert err == %Req.DecompressError{
               format: :br,
               reason: :brotli_error
             }

      assert resp.status == 200
      assert resp.body == nil
      assert acc == []
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  end

  describe "zstd" do
    @tag skip: System.otp_release() < "28"
    test "success" do
      %{req: req} =
        serve("GET /": &send_resp_zstd(&1, "foo"))

      resp = Req.stream!(req, compressed: true)
      assert resp.status == 200
      assert resp.body == "foo"

      {:ok, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert resp.status == 200
      assert resp.body == nil
      assert acc == ["foo"]
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

      {:error, err, resp} = Req.stream(req, compressed: true)
      assert resp.status == 200
      assert resp.body == ""

      assert err == %Req.DecompressError{
               format: :zstd,
               data: "bad",
               reason: "Unknown frame descriptor"
             }

      assert Exception.message(err) ==
               "zstd decompression failed, reason: \"Unknown frame descriptor\""

      {:error, err, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          compressed: true
        )

      assert err == %Req.DecompressError{
               format: :zstd,
               data: "bad",
               reason: "Unknown frame descriptor"
             }

      assert resp.status == 200
      assert resp.body == nil
      assert acc == []
    end
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

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["unknown1, unknown2"]
    assert resp.body == <<1, 2, 3>>

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        compressed: true
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == ["unknown1, unknown2"]
    assert resp.body == nil
    assert acc == [<<1, 2, 3>>]
  end

  test "HEAD request" do
    %{req: req} =
      serve("HEAD /": &send_resp_gzip(&1, ""))

    resp = Req.stream!(req, method: :head, compressed: true)
    assert resp.status == 200
    assert resp.body == ""

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        method: :head,
        compressed: true
      )

    assert resp.status == 200
    assert resp.body == nil
    assert acc == []
  end

  @tag skip: adapter() == :httpc
  test "into: collectable" do
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
          |> send_resp_chunked(Req.Gzip.encode_to_stream(["foo", "bar"]))
        end
      )

    resp = Req.request!(req, compressed: true, into: [])
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == ["foo", "bar"]
  end
end
