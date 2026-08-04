defmodule Req.DecodeTest do
  use Req.Case, async: true

  test "multiple types" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.prepend_resp_headers([
            {"content-type", "text/plain"},
            {"content-type", "text/plain; charset=utf-8"}
          ])
          |> Plug.Conn.send_resp(200, "ok")
        end
      )

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == "ok"
  end

  describe "json" do
    test "success" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            Req.Test.json(conn, %{a: 1})
          end
        )

      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == %{"a" => 1}
      assert resp.headers["content-type"] == ["application/json; charset=utf-8"]
    end

    test "json-api" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_header(
              "content-type",
              "application/vnd.api+json; charset=utf-8"
            )
            |> Req.Test.json(%{a: 1})
          end
        )

      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == %{"a" => 1}
    end

    test "custom options" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            Req.Test.json(conn, %{a: 1})
          end
        )

      resp = Req.stream!(req, decoders: [json: &Jason.decode(&1, keys: :atoms)])
      assert resp.status == 200
      assert resp.body == %{a: 1}
    end

    test "invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, "bad")
          end
        )

      {:error, err, resp} = Req.stream(req)

      assert err == %JSON.DecodeError{
               message: "invalid byte 98 at position (byte offset) 0",
               data: "bad",
               offset: 0
             }

      assert resp.status == 200
      assert resp.body == "bad"
    end
  end

  test "decoders: false disables JSON decoding" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    resp = Req.stream!(req, decoders: false)
    assert resp.status == 200
    assert resp.body == ~s|{"a":1}|
  end

  test "setting :decoders overwrites the default" do
    req = Req.new(decoders: [:zip]) |> Req.merge(decoders: [:tar])
    assert req.options[:decoders] == [:tar]
  end

  test "setting :decoders replaces the default, so JSON is not decoded unless included" do
    %{req: req} =
      serve("GET /": &Req.Test.json(&1, %{a: 1}))

    resp = Req.stream!(req, decoders: [:zip])
    assert resp.status == 200
    assert resp.body == ~s|{"a":1}|
  end

  test "unknown decoder format raises" do
    %{req: req} = serve("GET /": &Req.Test.json(&1, %{}))

    assert_raise ArgumentError, ~r/unknown decoder: :bogus/, fn ->
      Req.stream!(req, decoders: [:bogus])
    end
  end

  test "custom decoder (function)" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/calendar")
          |> Plug.Conn.send_resp(200, "raw-ics")
        end
      )

    resp = Req.stream!(req, decoders: [ics: &{:ok, String.upcase(&1)}])
    assert resp.status == 200
    assert resp.body == "RAW-ICS"
  end

  test "custom decoder (module exporting decode/1)" do
    # An EPUB is a ZIP archive, so Req.ZIP doubles as its decoder.
    files = [{~c"mimetype", "application/epub+zip"}]

    %{req: req} =
      serve(
        "GET /": fn conn ->
          {:ok, {_name, zip}} = :zip.create(~c"a.zip", files, [:memory])

          conn
          |> Plug.Conn.put_resp_content_type("application/epub+zip", nil)
          |> Plug.Conn.send_resp(200, zip)
        end
      )

    resp = Req.stream!(req, decoders: [epub: Req.ZIP])
    assert resp.status == 200
    assert resp.body == files
  end

  defmodule UpcaseDecoder do
    def decode(binary), do: {:ok, String.upcase(binary)}

    def decode_init, do: :noop

    def decode_chunk(state, data), do: {:ok, String.upcase(data), state}

    def decode_finish(_state), do: {:ok, nil}

    def decode_close(_state), do: :ok
  end

  test "custom streaming decoder" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/calendar")
          |> Plug.Conn.send_resp(200, "raw-ics")
        end
      )

    resp = Req.stream!(req, decoders: [ics: UpcaseDecoder])
    assert resp.status == 200
    assert resp.body == "RAW-ICS"

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        decoders: [ics: UpcaseDecoder]
      )

    assert resp.status == 200
    assert IO.iodata_to_binary(Enum.reverse(acc)) == "RAW-ICS"
  end

  test "custom decoder error" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/calendar")
          |> Plug.Conn.send_resp(200, "raw-ics")
        end
      )

    {:error, err, resp} =
      Req.stream(req, decoders: [ics: fn _ -> {:error, :nope} end])

    assert err == %RuntimeError{message: "decoding response body failed: :nope"}
    assert resp.status == 200
    assert resp.body == "raw-ics"
  end

  describe "tar" do
    test "not decoded by default" do
      %{req: req} =
        serve("GET /": &send_resp_tar(&1, [{~c"foo.txt", "bar"}]))

      resp = Req.stream!(req)
      assert resp.status == 200
      assert is_binary(resp.body)
    end

    test "content-type" do
      files = [{~c"foo.txt", "bar"}]
      %{req: req} = serve("GET /": &send_resp_tar(&1, files))

      resp = Req.stream!(req, decoders: [:tar])
      assert resp.status == 200
      assert resp.body == files
    end

    test "path" do
      files = [{~c"foo.txt", "bar"}]

      %{req: req, url: url} =
        serve(
          "GET /foo.tar": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
            |> send_resp_tar(files)
          end
        )

      resp = Req.stream!(req, url: "#{url}/foo.tar", decoders: [:tar])
      assert resp.status == 200
      assert resp.body == files
    end

    test "path, content type with charset utf8" do
      files = [{~c"foo.txt", "bar"}]

      %{req: req, url: url} =
        serve(
          "GET /foo.tar": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> send_resp_tar(files)
          end
        )

      resp = Req.stream!(req, url: "#{url}/foo.tar", decoders: [:tar])
      assert resp.status == 200
      assert resp.headers["content-type"] == ["application/octet-stream; charset=utf-8"]
      assert resp.body == files
    end

    test "path, no content-type" do
      files = [{~c"foo.txt", "bar"}]

      %{req: req, url: url} =
        serve(
          "GET /foo.tar.gz": fn conn ->
            Plug.Conn.send_resp(conn, 200, create_tar(files))
          end
        )

      resp = Req.stream!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz])
      assert resp.status == 200
      assert resp.body == files
    end

    test "tar.gz (path)" do
      files = [{~c"foo.txt", "bar"}]

      %{req: req, url: url} =
        serve(
          "GET /foo.tar.gz": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
            |> Plug.Conn.send_resp(200, create_tar(files, compressed: true))
          end
        )

      resp = Req.stream!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz])
      assert resp.status == 200
      assert resp.body == files
    end

    test "invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/x-tar", nil)
            |> Plug.Conn.send_resp(200, "invalid")
          end
        )

      {:error, err, resp} = Req.stream(req, decoders: [:tar])
      assert err == %Req.ArchiveError{format: :tar, reason: :eof, data: "invalid"}
      assert Exception.message(err) == "tar unpacking failed: Unexpected end of file"
      assert resp.status == 200
      assert resp.body == "invalid"
    end
  end

  describe "zip" do
    test "not decoded by default" do
      %{req: req} =
        serve("GET /": &send_resp_zip(&1, [{~c"foo.txt", "bar"}]))

      resp = Req.stream!(req)
      assert resp.status == 200
      assert is_binary(resp.body)
    end

    test "content-type" do
      files = [{~c"foo.txt", "bar"}]
      %{req: req} = serve("GET /": &send_resp_zip(&1, files))

      resp = Req.stream!(req, decoders: [:zip])
      assert resp.status == 200
      assert resp.body == files
    end

    test "path" do
      files = [{~c"foo.txt", "bar"}]

      %{req: req, url: url} =
        serve(
          "GET /foo.zip": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
            |> send_resp_zip(files)
          end
        )

      resp = Req.stream!(req, url: "#{url}/foo.zip", decoders: [:zip])
      assert resp.status == 200
      assert resp.body == files
    end

    test "invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/zip", nil)
            |> Plug.Conn.send_resp(200, "invalid")
          end
        )

      {:error, err, resp} = Req.stream(req, decoders: [:zip])
      assert err == %Req.ArchiveError{format: :zip, reason: nil, data: "invalid"}
      assert Exception.message(err) == "zip unpacking failed"
      assert resp.status == 200
      assert resp.body == "invalid"
    end
  end

  describe "gzip" do
    test "not decoded by default" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
            |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
          end
        )

      gzipped = :zlib.gzip("foo")
      resp = Req.stream!(req)
      assert resp.status == 200
      assert resp.body == gzipped
    end

    test "content-type" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
            |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
          end
        )

      resp = Req.stream!(req, decoders: [:gz])
      assert resp.status == 200
      assert resp.body == "foo"
    end

    test "streaming" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
            |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
          end
        )

      {:ok, resp, acc} =
        Req.stream(
          req,
          [],
          fn data, _resp, acc -> {:cont, [data | acc]} end,
          decoders: [:gz]
        )

      assert resp.status == 200
      assert IO.iodata_to_binary(Enum.reverse(acc)) == "foo"
    end

    test "invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
            |> Plug.Conn.send_resp(200, "bad")
          end
        )

      {:error, err, resp} = Req.stream(req, decoders: [:gz])

      assert err == %Req.DecompressError{
               format: :gzip,
               data: "bad",
               reason: :data_error
             }

      assert resp.status == 200
      assert resp.body == "bad"
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  end

  describe "zstd" do
    @tag skip: System.otp_release() < "28"
    test "not decoded by default" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/zstd", nil)
            |> Plug.Conn.send_resp(200, :zstd.compress("foo"))
          end
        )

      resp = Req.stream!(req)
      assert resp.status == 200
      assert IO.iodata_to_binary(resp.body) == IO.iodata_to_binary(:zstd.compress("foo"))
    end

    @tag skip: System.otp_release() < "28"
    test "content-type" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/zstd", nil)
            |> Plug.Conn.send_resp(200, :zstd.compress("foo"))
          end
        )

      resp = Req.stream!(req, decoders: [:zst])
      assert resp.status == 200
      assert resp.body == "foo"
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "path" do
      %{req: req, url: url} =
        serve(
          "GET /foo.zst": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
            |> Plug.Conn.send_resp(200, :zstd.compress("foo"))
          end
        )

      resp = Req.stream!(req, url: "#{url}/foo.zst", decoders: [:zst])
      assert resp.status == 200
      assert resp.body == "foo"
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/zstd", nil)
            |> Plug.Conn.send_resp(200, "bad")
          end
        )

      {:error, err, resp} = Req.stream(req, decoders: [:zst])

      assert err == %Req.DecompressError{
               format: :zstd,
               data: "bad",
               reason: "Unknown frame descriptor"
             }

      assert resp.status == 200
      assert resp.body == "bad"
    end
  end

  test "csv" do
    csv = [
      ["x", "y"],
      ["1", "2"],
      ["3", "4"]
    ]

    %{req: req} = serve("GET /": &send_resp_csv(&1, csv))

    resp = Req.stream!(req, decoders: [:csv])
    assert resp.status == 200
    assert resp.body == csv
  end

  test "decompress and decode" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          body =
            %{a: 1}
            |> Jason.encode_to_iodata!()
            |> :zlib.gzip()

          conn
          |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
        end
      )

    resp = Req.stream!(req, compressed: true)
    assert resp.status == 200
    assert resp.body == %{"a" => 1}
  end

  test "decompress and decode in raw mode" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          body =
            %{a: 1}
            |> Jason.encode_to_iodata!()
            |> :zlib.gzip()

          conn
          |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
        end
      )

    resp = Req.stream!(req, compressed: true, raw: true)
    assert resp.status == 200
    assert resp.headers["content-encoding"] == ["x-gzip"]
    assert resp.body |> :zlib.gunzip() |> Jason.decode!() == %{"a" => 1}
  end

  test "decode with unknown compression codec" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          body =
            %{a: 1}
            |> Jason.encode_to_iodata!()
            |> :zlib.compress()

          conn
          |> Plug.Conn.put_resp_header("content-encoding", "deflate")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
        end
      )

    {resp, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Req.stream!(req, compressed: true)
      end)

    assert resp.status == 200
    assert resp.headers["content-encoding"] == ["deflate"]
    assert resp.body |> :zlib.uncompress() |> Jason.decode!() == %{"a" => 1}
    assert log =~ ~s|[debug] algorithm "deflate" is not supported\n|
  end

  test "into: collectable is not decoded" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    resp = Req.request!(req, into: [])
    assert resp.status == 200
    assert resp.body == [~s|{"a":1}|]
  end

  test "json is not decoded when streaming" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc ->
        {:cont, [data | acc]}
      end)

    assert resp.status == 200
    assert IO.iodata_to_binary(Enum.reverse(acc)) == ~s|{"a":1}|
  end
end
