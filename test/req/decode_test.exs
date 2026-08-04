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

    resp = Req.get!(req)
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

      resp = Req.get!(req)
      assert resp.status == 200
      assert resp.body == %{"a" => 1}
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

      resp = Req.get!(req)
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

      resp = Req.get!(req, decoders: [json: &Jason.decode(&1, keys: :atoms)])
      assert resp.status == 200
      assert resp.body == %{a: 1}
    end

    test "deprecated :decode_json option" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            Req.Test.json(conn, %{a: 1})
          end
        )

      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               resp = Req.get!(req, decode_json: [keys: :atoms])
               assert resp.status == 200
               assert resp.body == %{a: 1}
             end) =~ "setting `decode_json: options` is deprecated"
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

      {:error, err} = Req.get(req)
      assert err == %Jason.DecodeError{position: 0, token: nil, data: "bad"}
    end
  end

  test "decoders: false disables JSON decoding" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    resp = Req.get!(req, decoders: false)
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

    resp = Req.get!(req, decoders: [:zip])
    assert resp.status == 200
    assert resp.body == ~s|{"a":1}|
  end

  test "unknown decoder format raises" do
    %{req: req} = serve("GET /": &Req.Test.json(&1, %{}))

    assert_raise ArgumentError, ~r/unknown decoder format: :bogus/, fn ->
      Req.get!(req, decoders: [:bogus])
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

    resp = Req.get!(req, decoders: [ics: &{:ok, String.upcase(&1)}])
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

    resp = Req.get!(req, decoders: [epub: Req.ZIP])
    assert resp.status == 200
    assert resp.body == files
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

    {:error, err} = Req.get(req, decoders: [ics: fn _ -> {:error, :nope} end])
    assert err == %RuntimeError{message: "decoding response body failed: :nope"}
  end

  test "{format, format} reuses a built-in decoder" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/calendar")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}|)
        end
      )

    resp = Req.get!(req, decoders: [ics: :json])
    assert resp.status == 200
    assert resp.body == %{"a" => 1}
  end

  describe "tar" do
    test "not decoded by default" do
      %{req: req} =
        serve("GET /": &send_resp_tar(&1, [{~c"foo.txt", "bar"}]))

      body = Req.get!(req).body
      assert is_binary(body)
    end

    test "content-type" do
      files = [{~c"foo.txt", "bar"}]
      %{req: req} = serve("GET /": &send_resp_tar(&1, files))

      resp = Req.get!(req, decoders: [:tar])
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

      resp = Req.get!(req, url: "#{url}/foo.tar", decoders: [:tar])
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

      resp = Req.get!(req, url: "#{url}/foo.tar", decoders: [:tar])
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

      resp = Req.get!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz])
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

      resp = Req.get!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz])
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

      {:error, err} = Req.get(req, decoders: [:tar])
      assert err == %Req.ArchiveError{format: :tar, reason: :eof, data: "invalid"}
      assert Exception.message(err) == "tar unpacking failed: Unexpected end of file"
    end
  end

  describe "zip" do
    test "not decoded by default" do
      %{req: req} =
        serve("GET /": &send_resp_zip(&1, [{~c"foo.txt", "bar"}]))

      body = Req.get!(req).body
      assert is_binary(body)
    end

    test "content-type" do
      files = [{~c"foo.txt", "bar"}]
      %{req: req} = serve("GET /": &send_resp_zip(&1, files))

      resp = Req.get!(req, decoders: [:zip])
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

      resp = Req.get!(req, url: "#{url}/foo.zip", decoders: [:zip])
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

      {:error, err} = Req.get(req, decoders: [:zip])
      assert err == %Req.ArchiveError{format: :zip, reason: nil, data: "invalid"}
      assert Exception.message(err) == "zip unpacking failed"
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

      resp = Req.get!(req)
      assert resp.status == 200
      assert resp.body == :zlib.gzip("foo")
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

      resp = Req.get!(req, decoders: [:gz])
      assert resp.status == 200
      assert resp.body == "foo"
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

      {:error, err} = Req.get(req, decoders: [:gz])
      assert err == %RuntimeError{message: "decoding response body failed: :data_error"}
    end
  end

  # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
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

      body = Req.get!(req).body
      assert IO.iodata_to_binary(body) == IO.iodata_to_binary(:zstd.compress("foo"))
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

      resp = Req.get!(req, decoders: [:zst])
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

      resp = Req.get!(req, url: "#{url}/foo.zst", decoders: [:zst])
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

      {:error, err} = Req.get(req, decoders: [:zst])

      assert err == %RuntimeError{
               message: "Could not decompress Zstandard data: \"Unknown frame descriptor\""
             }
    end
  end

  test "csv" do
    csv = [
      ["x", "y"],
      ["1", "2"],
      ["3", "4"]
    ]

    %{req: req} = serve("GET /": &send_resp_csv(&1, csv))

    resp = Req.get!(req, decoders: [:csv])
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

    resp = Req.get!(req, compressed: true)
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

    resp = Req.get!(req, compressed: true, raw: true)
    assert resp.status == 200

    assert resp.body
           |> :zlib.gunzip()
           |> Jason.decode!() == %{
             "a" => 1
           }
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
        Req.get!(req, compressed: true)
      end)

    assert resp.body |> :zlib.uncompress() |> Jason.decode!() == %{"a" => 1}
    assert log =~ ~s|[debug] algorithm "deflate" is not supported\n|
  end
end
