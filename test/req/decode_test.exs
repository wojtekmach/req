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

    assert Req.get!(req).body == "ok"
  end

  test "json" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    assert Req.get!(req).body == %{"a" => 1}
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

    assert Req.get!(req).body == %{"a" => 1}
  end

  test "json with custom options" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    assert Req.get!(req, decoders: [json: &Jason.decode(&1, keys: :atoms)]).body == %{
             a: 1
           }
  end

  test "deprecated :decode_json option" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert Req.get!(req, decode_json: [keys: :atoms]).body == %{a: 1}
           end) =~ "setting `decode_json: options` is deprecated"
  end

  test "json invalid" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "bad")
        end
      )

    assert {:error, %Jason.DecodeError{}} = Req.get(req)
  end

  test "archives are not decoded by default" do
    %{req: req} =
      serve("GET /": &send_resp_zip(&1, [{~c"foo.txt", "bar"}]))

    body = Req.get!(req).body
    assert is_binary(body)
  end

  test "decoders: false disables JSON decoding" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          Req.Test.json(conn, %{a: 1})
        end
      )

    assert Req.get!(req, decoders: false).body == ~s|{"a":1}|
  end

  test "setting :decoders overwrites the default" do
    req = Req.new(decoders: [:zip]) |> Req.merge(decoders: [:tar])
    assert req.options[:decoders] == [:tar]
  end

  test "setting :decoders replaces the default, so JSON is not decoded unless included" do
    %{req: req} =
      serve("GET /": &Req.Test.json(&1, %{a: 1}))

    assert Req.get!(req, decoders: [:zip]).body == ~s|{"a":1}|
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

    assert Req.get!(req, decoders: [epub: Req.ZIP]).body == files
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

    assert {:error, %RuntimeError{} = e} =
             Req.get(req, decoders: [ics: fn _ -> {:error, :nope} end])

    assert Exception.message(e) == "decoding response body failed: :nope"
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

    assert Req.get!(req, decoders: [ics: :json]).body == %{"a" => 1}
  end

  test "tar (content-type)" do
    files = [{~c"foo.txt", "bar"}]
    %{req: req} = serve("GET /": &send_resp_tar(&1, files))

    assert Req.get!(req, decoders: [:tar]).body == files
  end

  test "tar (path)" do
    files = [{~c"foo.txt", "bar"}]

    %{req: req, url: url} =
      serve(
        "GET /foo.tar": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
          |> send_resp_tar(files)
        end
      )

    assert Req.get!(req, url: "#{url}/foo.tar", decoders: [:tar]).body == files
  end

  test "tar (path, content type with charset utf8)" do
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

  test "tar (path, no content-type)" do
    files = [{~c"foo.txt", "bar"}]

    %{req: req, url: url} =
      serve(
        "GET /foo.tar.gz": fn conn ->
          Plug.Conn.send_resp(conn, 200, create_tar(files))
        end
      )

    assert Req.get!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz]).body == files
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

    assert Req.get!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz]).body == files
  end

  test "tar invalid" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-tar", nil)
          |> Plug.Conn.send_resp(200, "invalid")
        end
      )

    assert {:error, e} = Req.get(req, decoders: [:tar])
    assert e == %Req.ArchiveError{format: :tar, reason: :eof, data: "invalid"}
    assert Exception.message(e) == "tar unpacking failed: Unexpected end of file"
  end

  test "zip (content-type)" do
    files = [{~c"foo.txt", "bar"}]
    %{req: req} = serve("GET /": &send_resp_zip(&1, files))

    assert Req.get!(req, decoders: [:zip]).body == files
  end

  test "zip (path)" do
    files = [{~c"foo.txt", "bar"}]

    %{req: req, url: url} =
      serve(
        "GET /foo.zip": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
          |> send_resp_zip(files)
        end
      )

    assert Req.get!(req, url: "#{url}/foo.zip", decoders: [:zip]).body == files
  end

  test "zip invalid" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/zip", nil)
          |> Plug.Conn.send_resp(200, "invalid")
        end
      )

    assert {:error, e} = Req.get(req, decoders: [:zip])
    assert e == %Req.ArchiveError{format: :zip, reason: nil, data: "invalid"}
    assert Exception.message(e) == "zip unpacking failed"
  end

  test "gzip (content-type)" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
          |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
        end
      )

    assert Req.get!(req, decoders: [:gz]).body == "foo"
  end

  test "gzip invalid" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
          |> Plug.Conn.send_resp(200, "bad")
        end
      )

    assert {:error, e} = Req.get(req, decoders: [:gz])
    assert %RuntimeError{} = e
    assert Exception.message(e) == "decoding response body failed: :data_error"
  end

  # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  @tag skip: System.otp_release() < "28"
  test "zstd (content-type)" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/zstd", nil)
          |> Plug.Conn.send_resp(200, :zstd.compress("foo"))
        end
      )

    assert Req.get!(req, decoders: [:zst]).body == "foo"
  end

  # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  @tag skip: System.otp_release() < "28"
  test "zstd (path)" do
    %{req: req, url: url} =
      serve(
        "GET /foo.zst": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
          |> Plug.Conn.send_resp(200, :zstd.compress("foo"))
        end
      )

    assert Req.get!(req, url: "#{url}/foo.zst", decoders: [:zst]).body == "foo"
  end

  # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
  @tag skip: System.otp_release() < "28"
  test "zstd invalid" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/zstd", nil)
          |> Plug.Conn.send_resp(200, "bad")
        end
      )

    assert {:error, e} = Req.get(req, decoders: [:zst])
    assert %RuntimeError{} = e

    assert Exception.message(e) ==
             "Could not decompress Zstandard data: \"Unknown frame descriptor\""
  end

  test "csv" do
    csv = [
      ["x", "y"],
      ["1", "2"],
      ["3", "4"]
    ]

    %{req: req} = serve("GET /": &send_resp_csv(&1, csv))

    assert Req.get!(req, decoders: [:csv]).body == csv
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

    assert Req.get!(req, compressed: true).body == %{"a" => 1}
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

    assert Req.get!(req, compressed: true, raw: true).body
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
