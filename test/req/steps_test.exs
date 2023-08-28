defmodule Req.StepsTest do
  use ExUnit.Case, async: true

  require Logger

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  ## Request steps

  describe "put_base_url" do
    test "it works", c do
      Bypass.expect(c.bypass, "GET", "", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert Req.get!("/", base_url: c.url).body == "ok"
      assert Req.get!("", base_url: c.url).body == "ok"

      req = Req.new(base_url: c.url)
      assert Req.get!(req, url: "/").body == "ok"
      assert Req.get!(req, url: "").body == "ok"
    end

    test "with absolute url", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert Req.get!(c.url, base_url: "ignored").body == "ok"
    end

    test "with base path", c do
      Bypass.expect(c.bypass, "GET", "/api/v2/foo", fn conn ->
        assert conn.request_path == "/api/v2/foo"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert Req.get!("/foo", base_url: c.url <> "/api/v2", retry: false).body == "ok"
      assert Req.get!("foo", base_url: c.url <> "/api/v2").body == "ok"
      assert Req.get!("/foo", base_url: c.url <> "/api/v2/").body == "ok"
      assert Req.get!("foo", base_url: c.url <> "/api/v2/").body == "ok"
      assert Req.get!("", base_url: c.url <> "/api/v2/foo").body == "ok"
    end
  end

  describe "auth" do
    test "string" do
      req = Req.new(auth: "foo") |> Req.Request.prepare()

      assert Req.Request.get_header(req, "authorization") == ["foo"]
    end

    test "basic" do
      req = Req.new(auth: {"foo", "bar"}) |> Req.Request.prepare()

      assert Req.Request.get_header(req, "authorization") == ["Basic #{Base.encode64("foo:bar")}"]
    end

    test "bearer" do
      req = Req.new(auth: {:bearer, "abcd"}) |> Req.Request.prepare()

      assert Req.Request.get_header(req, "authorization") == ["Bearer abcd"]
    end

    @tag :tmp_dir
    test ":netrc", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        expected = "Basic " <> Base.encode64("foo:bar")

        case Plug.Conn.get_req_header(conn, "authorization") do
          [^expected] ->
            Plug.Conn.send_resp(conn, 200, "ok")

          _ ->
            Plug.Conn.send_resp(conn, 401, "unauthorized")
        end
      end)

      old_netrc = System.get_env("NETRC")

      System.put_env("NETRC", "#{c.tmp_dir}/.netrc")

      File.write!("#{c.tmp_dir}/.netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(c.url, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/tabs")

      File.write!("#{c.tmp_dir}/tabs", """
      machine localhost
           login foo
           password bar
      """)

      assert Req.get!(c.url, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/single_line")

      File.write!("#{c.tmp_dir}/single_line", """
      machine otherhost
      login meat
      password potatoes
      machine localhost login foo password bar
      """)

      assert Req.get!(c.url, auth: :netrc).status == 200

      if old_netrc, do: System.put_env("NETRC", old_netrc), else: System.delete_env("NETRC")
    end

    @tag :tmp_dir
    test "{:netrc, path}", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        expected = "Basic " <> Base.encode64("foo:bar")

        case Plug.Conn.get_req_header(conn, "authorization") do
          [^expected] ->
            Plug.Conn.send_resp(conn, 200, "ok")

          _ ->
            Plug.Conn.send_resp(conn, 401, "unauthorized")
        end
      end)

      assert_raise RuntimeError, "error reading .netrc file: no such file or directory", fn ->
        Req.get!(c.url, auth: {:netrc, "non_existent_file"})
      end

      File.write!("#{c.tmp_dir}/custom_netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(c.url, auth: {:netrc, c.tmp_dir <> "/custom_netrc"}).status == 200

      File.write!("#{c.tmp_dir}/wrong_netrc", """
      machine localhost
      login bad
      password bad
      """)

      assert Req.get!(c.url, auth: {:netrc, "#{c.tmp_dir}/wrong_netrc"}).status == 401

      File.write!("#{c.tmp_dir}/empty_netrc", "")

      assert_raise RuntimeError, ".netrc file is empty", fn ->
        Req.get!(c.url, auth: {:netrc, "#{c.tmp_dir}/empty_netrc"})
      end

      File.write!("#{c.tmp_dir}/bad_netrc", """
      bad
      """)

      assert_raise RuntimeError, "error parsing .netrc file", fn ->
        Req.get!(c.url, auth: {:netrc, "#{c.tmp_dir}/bad_netrc"})
      end
    end
  end

  describe "encode_body" do
    # neither `body: data` nor `body: stream` is used by the step but testing these
    # here for locality
    test "body", c do
      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

      req =
        Req.new(
          url: c.url,
          body: "foo"
        )

      assert Req.post!(req).body == "foo"
    end

    test "body stream", c do
      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

      req =
        Req.new(
          url: c.url,
          body: Stream.take(~w[foo foo foo], 2)
        )

      assert Req.post!(req).body == "foofoo"
    end

    test "json", c do
      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        assert {:ok, ~s|{"a":1}|, conn} = Plug.Conn.read_body(conn)
        assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
        assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

        Plug.Conn.send_resp(conn, 200, "")
      end)

      Req.post!(c.url, json: %{a: 1})
    end

    test "form" do
      req = Req.new(form: [a: 1]) |> Req.Request.prepare()
      assert req.body == "a=1"

      req = Req.new(form: %{a: 1}) |> Req.Request.prepare()
      assert req.body == "a=1"
    end
  end

  test "put_params" do
    req = Req.new(url: "http://foo", params: [x: 1, y: 2]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo?x=1&y=2"

    req = Req.new(url: "http://foo", params: [x: 1, x: 2]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo?x=1&x=2"

    req = Req.new(url: "http://foo?x=1", params: [x: 1, y: 2]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo?x=1&x=1&y=2"
  end

  test "put_path_params" do
    req = Req.new(url: "http://foo/:id", path_params: [id: "abc|def"]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo/abc%7Cdef"
  end

  test "put_range" do
    req = Req.new(range: "bytes=0-10") |> Req.Request.prepare()
    assert Req.Request.get_header(req, "range") == ["bytes=0-10"]

    req = Req.new(range: 0..20) |> Req.Request.prepare()
    assert Req.Request.get_header(req, "range") == ["bytes=0-20"]
  end

  describe "compress_body" do
    test "request" do
      req = Req.new(method: :post, json: %{a: 1}) |> Req.Request.prepare()
      assert Jason.decode!(req.body) == %{"a" => 1}

      req = Req.new(method: :post, json: %{a: 1}, compress_body: true) |> Req.Request.prepare()
      assert :zlib.gunzip(req.body) |> Jason.decode!() == %{"a" => 1}
      assert Req.Request.get_header(req, "content-encoding") == ["gzip"]
    end

    test "stream", c do
      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = :zlib.gunzip(body)
        Plug.Conn.send_resp(conn, 200, body)
      end)

      req =
        Req.new(
          url: c.url,
          method: :post,
          body: Stream.take(~w[foo foo foo], 2),
          compress_body: true
        )

      assert Req.post!(req).body == "foofoo"
    end
  end

  ## Response steps

  describe "decompress_body" do
    test "gzip", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
      end)

      resp = Req.get!(c.url)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "identity", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "identity")
        |> Plug.Conn.send_resp(200, "foo")
      end)

      resp = Req.get!(c.url)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "brotli", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        {:ok, body} = :brotli.encode("foo")

        conn
        |> Plug.Conn.put_resp_header("content-encoding", "br")
        |> Plug.Conn.send_resp(200, body)
      end)

      resp = Req.get!(c.url)
      assert resp.body == "foo"
    end

    test "zstd", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "zstd")
        |> Plug.Conn.send_resp(200, :ezstd.compress("foo"))
      end)

      resp = Req.get!(c.url)
      assert resp.body == "foo"
    end

    test "multiple codecs", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip, zstd")
        |> Plug.Conn.send_resp(200, "foo" |> :zlib.gzip() |> :ezstd.compress())
      end)

      resp = Req.get!(c.url)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "multiple codecs with multiple headers" do
      %{url: url} =
        TestServer.serve(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          body = "foo" |> :zlib.gzip() |> :ezstd.compress()

          data = """
          HTTP/1.1 200 OK
          content-encoding: gzip
          content-encoding: zstd
          content-length: #{byte_size(body)}

          #{body}
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      resp = Req.get!(url)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    @tag :capture_log
    test "unknown codecs", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "unknown1, unknown2")
        |> Plug.Conn.send_resp(200, <<1, 2, 3>>)
      end)

      resp = Req.get!(c.url)
      assert Req.Response.get_header(resp, "content-encoding") == ["unknown1, unknown2"]
      assert resp.body == <<1, 2, 3>>
    end

    test "HEAD request", c do
      Bypass.expect(c.bypass, "HEAD", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, "")
      end)

      assert Req.head!(c.url).body == ""
    end

    test "recalculate content-length header", c do
      body = "foo"
      gzipped_body = :zlib.gzip(body)

      assert byte_size(body) != byte_size(gzipped_body)

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_header("content-length", gzipped_body |> byte_size() |> to_string())
        |> Plug.Conn.send_resp(200, gzipped_body)
      end)

      resp = Req.get!(c.url)
      [content_length] = Req.Response.get_header(resp, "content-length")
      assert String.to_integer(content_length) == byte_size(body)
    end
  end

  describe "output" do
    @tag :tmp_dir
    test "path (compressed)", c do
      Bypass.expect_once(c.bypass, "GET", "/foo.txt", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("bar"))
      end)

      response = Req.get!(c.url <> "/foo.txt", output: c.tmp_dir <> "/foo.txt")
      assert response.body == ""
      assert File.read!(c.tmp_dir <> "/foo.txt") == "bar"
    end

    test ":remote_name", c do
      Bypass.expect_once(c.bypass, "GET", "/directory/does/not/matter/foo.txt", fn conn ->
        Plug.Conn.send_resp(conn, 200, "bar")
      end)

      response = Req.get!(c.url <> "/directory/does/not/matter/foo.txt", output: :remote_name)
      assert response.body == ""
      assert File.read!("foo.txt") == "bar"
    after
      File.rm("foo.txt")
    end

    test "disables decoding", c do
      Bypass.expect_once(c.bypass, "GET", "/foo.json", fn conn ->
        json(conn, 200, %{a: 1})
      end)

      response = Req.get!(c.url <> "/foo.json", output: :remote_name)
      assert response.body == ""
      assert File.read!("foo.json") == ~s|{"a":1}|
    after
      File.rm("foo.json")
    end

    test "empty filename", c do
      Bypass.expect_once(c.bypass, "GET", "", fn conn ->
        Plug.Conn.send_resp(conn, 200, "body contents")
      end)

      assert_raise RuntimeError, "cannot write to file \"\"", fn ->
        Req.get!(c.url, output: :remote_name)
      end
    end
  end

  describe "decode_body" do
    test "json", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        json(conn, 200, %{a: 1})
      end)

      assert Req.get!(c.url).body == %{"a" => 1}
    end

    test "json-api", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/vnd.api+json; charset=utf-8")
        |> json(200, %{a: 1})
      end)

      assert Req.get!(c.url).body == %{"a" => 1}
    end

    test "json with custom options", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        json(conn, 200, %{a: 1})
      end)

      assert Req.get!(c.url, decode_json: [keys: :atoms]).body == %{a: 1}
    end

    @tag :tmp_dir
    test "with output", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        json(conn, 200, %{a: 1})
      end)

      assert Req.get!(c.url, output: c.tmp_dir <> "/a.json").body == ""
      assert File.read!(c.tmp_dir <> "/a.json") == ~s|{"a":1}|
    end

    test "gzip", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
        |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
      end)

      assert Req.get!(c.url).body == "foo"
    end

    @tag :tmp_dir
    test "tar (content-type)", c do
      files = [{~c"foo.txt", "bar"}]

      path = ~c"#{c.tmp_dir}/foo.tar"
      :ok = :erl_tar.create(path, files)
      tar = File.read!(path)

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-tar")
        |> Plug.Conn.send_resp(200, tar)
      end)

      assert Req.get!(c.url).body == files
    end

    @tag :tmp_dir
    test "tar (path)", c do
      files = [{~c"foo.txt", "bar"}]

      path = ~c"#{c.tmp_dir}/foo.tar"
      :ok = :erl_tar.create(path, files)
      tar = File.read!(path)

      Bypass.expect(c.bypass, "GET", "/foo.tar", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, tar)
      end)

      assert Req.get!(c.url <> "/foo.tar").body == files
    end

    @tag :tmp_dir
    test "tar.gz (path)", c do
      files = [{~c"foo.txt", "bar"}]

      path = ~c"#{c.tmp_dir}/foo.tar"
      :ok = :erl_tar.create(path, files, [:compressed])
      tar = File.read!(path)

      Bypass.expect(c.bypass, "GET", "/foo.tar.gz", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, tar)
      end)

      assert Req.get!(c.url <> "/foo.tar.gz").body == files
    end

    test "zip (content-type)", c do
      files = [{~c"foo.txt", "bar"}]

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        {:ok, {~c"foo.zip", data}} = :zip.create(~c"foo.zip", files, [:memory])

        conn
        |> Plug.Conn.put_resp_content_type("application/zip", nil)
        |> Plug.Conn.send_resp(200, data)
      end)

      assert Req.get!(c.url).body == files
    end

    test "zip (path)", c do
      files = [{~c"foo.txt", "bar"}]

      Bypass.expect(c.bypass, "GET", "/foo.zip", fn conn ->
        {:ok, {~c"foo.zip", data}} = :zip.create(~c"foo.zip", files, [:memory])

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, data)
      end)

      assert Req.get!(c.url <> "/foo.zip").body == files
    end

    test "csv", c do
      csv = [
        ["x", "y"],
        ["1", "2"],
        ["3", "4"]
      ]

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        data = NimbleCSV.RFC4180.dump_to_iodata(csv)

        conn
        |> Plug.Conn.put_resp_content_type("text/csv")
        |> Plug.Conn.send_resp(200, data)
      end)

      assert Req.get!(c.url).body == csv
    end
  end

  test "decompress and decode" do
    plug = fn conn ->
      body =
        %{a: 1}
        |> Jason.encode_to_iodata!()
        |> :zlib.gzip()

      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    assert Req.get!("", plug: plug).body == %{"a" => 1}
  end

  test "decompress and decode in raw mode" do
    plug = fn conn ->
      body =
        %{a: 1}
        |> Jason.encode_to_iodata!()
        |> :zlib.gzip()

      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    assert Req.get!("", plug: plug, raw: true).body |> :zlib.gunzip() |> Jason.decode!() == %{
             "a" => 1
           }
  end

  test "decode with unknown compression codec" do
    plug = fn conn ->
      body =
        %{a: 1}
        |> Jason.encode_to_iodata!()
        |> :zlib.compress()

      conn
      |> Plug.Conn.put_resp_header("content-encoding", "deflate")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    assert Req.get!("", plug: plug).body |> :zlib.uncompress() |> Jason.decode!() == %{
             "a" => 1
           }
  end

  describe "redirect" do
    test "absolute", c do
      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        redirect(conn, 302, c.url <> "/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect").status == 200
             end) =~ "[debug] redirecting to #{c.url}/ok"
    end

    test "relative", c do
      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        location =
          case conn.query_string do
            nil -> "/ok"
            string -> "/ok?" <> string
          end

        redirect(conn, 302, location)
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, conn.query_string)
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               response = Req.get!(c.url <> "/redirect")
               assert response.status == 200
               assert response.body == ""
             end) =~ "[debug] redirecting to /ok"

      assert ExUnit.CaptureLog.capture_log(fn ->
               response = Req.get!(c.url <> "/redirect?a=1")
               assert response.status == 200
               assert response.body == "a=1"
             end) =~ "[debug] redirecting to /ok?a=1"
    end

    test "301..303", c do
      Bypass.expect(c.bypass, "POST", "/redirect", fn conn ->
        redirect(conn, 301, c.url <> "/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.post!(c.url <> "/redirect", body: "body").status == 200
             end) =~ "[debug] redirecting to #{c.url}/ok"
    end

    test "307..308", c do
      Bypass.expect(c.bypass, "POST", "/redirect", fn conn ->
        redirect(conn, 307, c.url <> "/ok")
      end)

      Bypass.expect(c.bypass, "POST", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.post!(c.url <> "/redirect", body: "body").status == 200
             end) =~ "[debug] redirecting to #{c.url}/ok"
    end

    test "auth same host", c do
      auth_header = {"authorization", "Basic " <> Base.encode64("foo:bar")}

      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        assert auth_header in conn.req_headers
        redirect(conn, 302, c.url <> "/auth")
      end)

      Bypass.expect(c.bypass, "GET", "/auth", fn conn ->
        assert auth_header in conn.req_headers
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect", auth: {"foo", "bar"}).status == 200
             end) =~ "[debug] redirecting to #{c.url}/auth"
    end

    test "auth location trusted" do
      adapter = fn request ->
        case request.url.host do
          "original" ->
            assert [_] = Req.Request.get_header(request, "authorization")

            response =
              Req.Response.new(
                status: 301,
                headers: [{"location", "http://untrusted"}],
                body: "redirecting"
              )

            {request, response}

          "untrusted" ->
            assert [_] = Req.Request.get_header(request, "authorization")

            response =
              Req.Response.new(
                status: 200,
                body: "bad things"
              )

            {request, response}
        end
      end

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://original",
                        adapter: adapter,
                        auth: {"authorization", "credentials"},
                        redirect_trusted: true
                      ).status == 200
             end) =~ "[debug] redirecting to http://untrusted"
    end

    test "auth different host" do
      adapter = untrusted_redirect_adapter(:host, "trusted", "untrusted")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://trusted",
                        adapter: adapter,
                        auth: {"authorization", "credentials"}
                      ).status == 200
             end) =~ "[debug] redirecting to http://untrusted"
    end

    test "auth different port" do
      adapter = untrusted_redirect_adapter(:port, 12345, 23456)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://trusted:12345",
                        adapter: adapter,
                        auth: {"authorization", "credentials"}
                      ).status == 200
             end) =~ "[debug] redirecting to http://trusted:23456"
    end

    test "auth different scheme" do
      adapter = untrusted_redirect_adapter(:scheme, "http", "https")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://trusted",
                        adapter: adapter,
                        auth: {"authorization", "credentials"}
                      ).status == 200
             end) =~ "[debug] redirecting to https://trusted"
    end

    test "skip params", c do
      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        redirect(conn, 302, c.url <> "/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        assert conn.query_string == ""
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect", params: [a: 1]).status == 200
             end) =~ "[debug] redirecting to #{c.url}/ok"
    end

    test "max redirects", c do
      pid = self()

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        send(pid, :ping)
        redirect(conn, 302, c.url)
      end)

      captured_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert_raise RuntimeError, "too many redirects (3)", fn ->
            Req.get!(c.url, max_redirects: 3)
          end
        end)

      assert_receive :ping
      assert_receive :ping
      assert_receive :ping
      assert_receive :ping
      refute_receive _

      assert captured_log =~ "redirecting to " <> c.url
    end

    test "redirect_log_level, default to :debug", c do
      "http:" <> no_scheme = c.url

      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        redirect(conn, 302, "#{no_scheme}/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect").status == 200
             end) =~ "[debug] redirecting to #{no_scheme}/ok"
    end

    test "redirect_log_level, set to :error", c do
      "http:" <> no_scheme = c.url

      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        redirect(conn, 302, "#{no_scheme}/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect", redirect_log_level: :error).status == 200
             end) =~ "[error] redirecting to #{no_scheme}/ok"
    end

    test "redirect_log_level, disabled", c do
      "http:" <> no_scheme = c.url

      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        redirect(conn, 302, "#{no_scheme}/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect", redirect_log_level: false).status == 200
             end) =~ ""
    end

    test "inherit scheme", c do
      "http:" <> no_scheme = c.url

      Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
        redirect(conn, 302, "#{no_scheme}/ok")
      end)

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(c.url <> "/redirect").status == 200
             end) =~ "[debug] redirecting to #{no_scheme}/ok"
    end
  end

  defp redirect(conn, status, url) do
    conn
    |> Plug.Conn.put_resp_header("location", url)
    |> Plug.Conn.send_resp(status, "redirecting to #{url}")
  end

  defp untrusted_redirect_adapter(component, original_value, updated_value) do
    fn request ->
      case Map.get(request.url, component) do
        ^original_value ->
          assert [_] = Req.Request.get_header(request, "authorization")

          new_url =
            request.url
            |> Map.put(component, updated_value)
            |> to_string()

          response =
            Req.Response.new(
              status: 301,
              headers: [{"location", new_url}],
              body: "redirecting"
            )

          {request, response}

        ^updated_value ->
          assert [] = Req.Request.get_header(request, "authorization")

          response =
            Req.Response.new(
              status: 200,
              body: "bad things"
            )

          {request, response}
      end
    end
  end

  ## Error steps

  describe "retry" do
    @tag :capture_log
    test "eventually successful - function", c do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
        attempt = request.private.attempt

        response =
          case attempt do
            0 ->
              Req.Response.new(status: 500, body: "oops")

            1 ->
              Req.Response.new(status: 500, body: "oops")

            2 ->
              Req.Response.new(status: 500, body: "oops")

            3 ->
              Req.Response.new(status: 200, body: "ok")
          end

        {request, response}
      end

      request =
        Req.new(adapter: adapter, url: c.url, retry_delay: &Integer.pow(2, &1))
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

      assert log =~ "will retry in 1ms, 3 attempts left"
      assert log =~ "will retry in 2ms, 2 attempts left"
      assert log =~ "will retry in 4ms, 1 attempt left"
    end

    @tag :capture_log
    test "eventually successful - integer", c do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
        attempt = request.private.attempt

        response =
          case attempt do
            0 ->
              Req.Response.new(status: 500, body: "oops")

            1 ->
              Req.Response.new(status: 500, body: "oops")

            2 ->
              Req.Response.new(status: 200, body: "ok")
          end

        {request, response}
      end

      request =
        Req.new(adapter: adapter, url: c.url, retry_delay: 1)
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

      assert log =~ "will retry in 1ms, 2 attempts left"
      assert log =~ "will retry in 1ms, 2 attempts left"
    end

    @tag :capture_log
    test "default log_level", c do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
        attempt = request.private.attempt

        response =
          case attempt do
            0 ->
              Req.Response.new(status: 500, body: "oops")

            1 ->
              Req.Response.new(status: 200, body: "ok")
          end

        {request, response}
      end

      request = Req.new(adapter: adapter, url: c.url, retry_delay: 1)
      log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)

      assert String.match?(
               log,
               ~r/\[error\][[:blank:]]+retry: got response with status 500, will retry in 1ms, 3 attempts left/u
             )
    end

    @tag :capture_log
    test "custom log_level", c do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
        attempt = request.private.attempt

        response =
          case attempt do
            0 ->
              Req.Response.new(status: 500, body: "oops")

            1 ->
              Req.Response.new(status: 200, body: "ok")
          end

        {request, response}
      end

      request = Req.new(adapter: adapter, url: c.url, retry_delay: 1, retry_log_level: :info)
      log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)

      assert String.match?(
               log,
               ~r/\[info\][[:blank:]]+retry: got response with status 500, will retry in 1ms, 3 attempts left/u
             )
    end

    @tag :capture_log
    test "logging disabled", c do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
        attempt = request.private.attempt

        response =
          case attempt do
            0 ->
              Req.Response.new(status: 500, body: "oops")

            1 ->
              Req.Response.new(status: 200, body: "ok")
          end

        {request, response}
      end

      request = Req.new(adapter: adapter, url: c.url, retry_delay: 1, retry_log_level: false)
      log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)
      assert log == ""
    end

    @tag :capture_log
    @tag timeout: 1000
    test "retry_delay" do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
        attempt = request.private.attempt

        response =
          case attempt do
            0 -> Req.Response.new(status: 429) |> retry_after(0)
            1 -> Req.Response.new(status: 503) |> retry_after(DateTime.utc_now())
            2 -> Req.Response.new(status: 200, body: "ok")
          end

        {request, response}
      end

      assert Req.request!(adapter: adapter, retry_delay: 10000).body == "ok"
    end

    defp retry_after(r, value), do: Req.Response.put_header(r, "retry-after", retry_after(value))
    defp retry_after(integer) when is_integer(integer), do: to_string(integer)
    defp retry_after(%DateTime{} = dt), do: Req.Steps.format_http_datetime(dt)

    @tag :capture_log
    test "always failing", c do
      pid = self()

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      request =
        Req.new(url: c.url, retry_delay: 1)
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
    test "retry: :safe_transient does not retry on POST", c do
      pid = self()

      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      request = Req.new(url: c.url, retry: :safe_transient, max_retries: 10)

      assert Req.post!(request).status == 500
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "retry: :transient retries on POST", c do
      pid = self()

      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      request = Req.new(url: c.url, retry: :transient, retry_delay: 1, max_retries: 1)

      assert Req.post!(request).status == 500
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    test "retry: false", c do
      pid = self()

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      request = Req.new(url: c.url, retry: false)

      assert Req.get!(request).status == 500
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "custom function returning true", c do
      pid = self()

      Bypass.expect(c.bypass, "POST", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      fun = fn _request, response ->
        assert response.status == 500
        true
      end

      request = Req.new(url: c.url, retry: fun, retry_delay: 1)

      assert Req.post!(request).status == 500
      assert_received :ping
      assert_received :ping
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "custom function returning {:delay, milliseconds}", c do
      pid = self()

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      fun = fn _request, response ->
        assert response.status == 500
        {:delay, 1}
      end

      request = Req.new(url: c.url, retry: fun)

      assert Req.get!(request).status == 500
      assert_received :ping
      assert_received :ping
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "raise on custom function returning {:delay, milliseconds} when `:retry_delay` is provided",
         c do
      pid = self()

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      fun = fn _request, response ->
        assert response.status == 500
        {:delay, 1}
      end

      request = Req.new(url: c.url, retry: fun, retry_delay: 1)

      assert_raise ArgumentError,
                   "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`",
                   fn -> Req.get!(request) end
    end

    @tag :capture_log
    test "does not re-encode params", c do
      pid = self()

      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        assert conn.query_string == "a=1&b=2"
        send(pid, :ping)
        Plug.Conn.send_resp(conn, 500, "oops")
      end)

      assert Req.get!(c.url, params: [a: 1, b: 2], retry_delay: 1).status == 500
      assert_received :ping
      assert_received :ping
      assert_received :ping
      assert_received :ping
      refute_received _
    end
  end

  @tag :tmp_dir
  test "cache", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      case Plug.Conn.get_req_header(conn, "if-modified-since") do
        [] ->
          send(pid, :cache_miss)

          conn
          |> Plug.Conn.put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
          |> Plug.Conn.send_resp(200, "ok")

        _ ->
          send(pid, :cache_hit)

          conn
          |> Plug.Conn.put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
          |> Plug.Conn.send_resp(304, "")
      end
    end)

    request = Req.new(url: c.url, cache: true, cache_dir: c.tmp_dir)

    response = Req.get!(request)
    assert response.status == 200
    assert response.body == "ok"
    assert_received :cache_miss

    response = Req.Request.run!(request)
    assert response.status == 200
    assert response.body == "ok"
    assert_received :cache_hit
  end

  @tag :tmp_dir
  @tag :capture_log
  test "cache + retry", c do
    pid = self()
    {:ok, _} = Agent.start_link(fn -> 0 end, name: :counter)

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      case Plug.Conn.get_req_header(conn, "if-modified-since") do
        [] ->
          send(pid, :cache_miss)

          conn
          |> Plug.Conn.put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
          |> json(200, %{a: 1})

        _ ->
          send(pid, :cache_hit)
          count = Agent.get_and_update(:counter, &{&1, &1 + 1})

          if count < 2 do
            Plug.Conn.send_resp(conn, 500, "")
          else
            conn
            |> Plug.Conn.put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
            |> Plug.Conn.send_resp(304, "")
          end
      end
    end)

    request =
      Req.new(
        url: c.url,
        retry_delay: 10,
        cache: true,
        cache_dir: c.tmp_dir
      )

    response = Req.get!(request)
    assert response.status == 200
    assert response.body == %{"a" => 1}
    assert_received :cache_miss

    response = Req.Request.run!(request)
    assert response.status == 200
    assert response.body == %{"a" => 1}
    assert_received :cache_hit
    assert_received :cache_hit
    assert_received :cache_hit
    refute_received _
  end

  describe "put_plug" do
    test "request" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == ~s|{"a":1}|
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert Req.request!(plug: plug, json: %{a: 1}).body == "ok"
    end

    test "request stream" do
      req =
        Req.new(
          plug: fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Plug.Conn.send_resp(conn, 200, body)
          end,
          body: Stream.take(~w[foo foo foo], 2)
        )

      assert Req.request!(req).body == "foofoo"
    end
  end

  describe "run_finch" do
    test ":finch_request", c do
      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      pid = self()

      fun = fn req, finch_request, finch_name, finch_opts ->
        {:ok, resp} = Finch.request(finch_request, finch_name, finch_opts)
        send(pid, resp)
        {req, Req.Response.new(status: resp.status, headers: resp.headers, body: "finch_request")}
      end

      assert Req.get!(c.url <> "/ok", finch_request: fun).body == "finch_request"
      assert_received %Finch.Response{body: "ok"}
    end

    test ":finch_request error", c do
      fun = fn req, _finch_request, _finch_name, _finch_opts ->
        {req, %ArgumentError{message: "exec error"}}
      end

      assert_raise ArgumentError, "exec error", fn ->
        Req.get!(c.url, finch_request: fun, retry: false)
      end
    end

    test ":finch_request with invalid return", c do
      fun = fn _, _, _, _ -> :ok end

      assert_raise RuntimeError, ~r"expected adapter to return \{request, response\}", fn ->
        Req.get!(c.url, finch_request: fun)
      end
    end

    test "pool timeout", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      options = [pool_timeout: 0]

      assert_raise RuntimeError, ~r/unable to provide a connection within the timeout/, fn ->
        Req.get!(c.url, options)
      end
    end

    test ":receive_timeout", c do
      pid = self()

      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        send(pid, :ping)
        Process.sleep(10)
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      options = [receive_timeout: 0, retry_delay: 10]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Mint.TransportError{reason: :timeout}} =
                   Req.request([method: :get, url: c.url] ++ options)

          assert_receive :ping
          assert_receive :ping
          assert_receive :ping
          assert_receive :ping
          refute_receive _
        end)

      refute log =~ "4 attempts left"

      assert log =~ "3 attempts left"
      assert log =~ "2 attempts left"
      assert log =~ "1 attempt left"
    end

    test ":connect_options :protocol", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        {_, %{version: :"HTTP/2"}} = conn.adapter
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      req = Req.new(url: c.url, connect_options: [protocol: :http2])
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options :proxy", c do
      Bypass.expect(c.bypass, "GET", "/foo/bar", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      # Bypass will forward request to itself
      # Not quite a proper forward proxy server, but good enough
      test_proxy = {:http, "localhost", c.bypass.port, []}

      req = Req.new(base_url: c.url, connect_options: [proxy: test_proxy])
      assert Req.request!(req, url: "/foo/bar").body == "ok"
    end

    test ":connect_options :hostname", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        assert Plug.Conn.get_req_header(conn, "host") == ["example.com:#{c.bypass.port}"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      req = Req.new(base_url: c.url, connect_options: [hostname: "example.com"])
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options :transport_opts", c do
      req = Req.new(connect_options: [transport_opts: [cacertfile: "bad.pem"]])

      assert_raise File.Error, ~r/could not read file "bad.pem"/, fn ->
        Req.request!(req, url: "https://localhost:#{c.bypass.port}")
      end
    end

    defmodule ExamplePlug do
      def init(options), do: options

      def call(conn, []) do
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end

    test ":inet6" do
      start_supervised!(
        {Plug.Cowboy, scheme: :http, plug: ExamplePlug, ref: ExamplePlug.IPv4, port: 0}
      )

      start_supervised!(
        {Plug.Cowboy,
         scheme: :http,
         plug: ExamplePlug,
         ref: ExamplePlug.IPv6,
         port: 0,
         net: :inet6,
         ipv6_v6only: true}
      )

      ipv4_port = :ranch.get_port(ExamplePlug.IPv4)
      ipv6_port = :ranch.get_port(ExamplePlug.IPv6)

      req = Req.new(url: "http://localhost:#{ipv4_port}")
      assert Req.request!(req).body == "ok"

      req = Req.new(url: "http://localhost:#{ipv4_port}", inet6: true)
      assert Req.request!(req).body == "ok"

      req = Req.new(url: "http://localhost:#{ipv6_port}", inet6: true)
      assert Req.request!(req).body == "ok"
    end

    test ":connect_options bad option", c do
      assert_raise ArgumentError, "unknown option :timeou. Did you mean :timeout?", fn ->
        Req.get!(c.url, connect_options: [timeou: 0])
      end
    end

    test ":finch and :connect_options" do
      assert_raise ArgumentError, "cannot set both :finch and :connect_options", fn ->
        Req.request!(finch: MyFinch, connect_options: [timeout: 0])
      end
    end

    test "into: fun" do
      %{url: url} =
        TestServer.serve(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK
          transfer-encoding: chunked
          trailer: x-foo, x-bar

          6\r
          chunk1\r
          6\r
          chunk2\r
          0\r
          x-foo: foo\r
          x-bar: bar\r
          \r
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      pid = self()

      resp =
        Req.get!(
          url: url,
          into: fn {:data, data}, acc ->
            send(pid, {:data, data})
            {:cont, acc}
          end
        )

      assert resp.status == 200
      assert resp.headers["transfer-encoding"] == ["chunked"]
      assert resp.headers["trailer"] == ["x-foo, x-bar"]
      assert resp.headers["x-foo"] == ["foo"]
      assert resp.headers["x-bar"] == ["bar"]
      assert_receive {:data, "chunk1"}
      assert_receive {:data, "chunk2"}
      refute_receive _
    end

    test "into: collectable" do
      %{url: url} =
        TestServer.serve(fn socket ->
          {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)

          data = """
          HTTP/1.1 200 OK
          transfer-encoding: chunked
          trailer: x-foo, x-bar

          6\r
          chunk1\r
          6\r
          chunk2\r
          0\r
          x-foo: foo\r
          x-bar: bar\r
          \r
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      resp =
        Req.get!(
          url: url,
          into: []
        )

      assert resp.status == 200
      assert resp.headers["transfer-encoding"] == ["chunked"]
      assert resp.headers["trailer"] == ["x-foo, x-bar"]
      assert resp.headers["x-foo"] == ["foo"]
      assert resp.headers["x-bar"] == ["bar"]
      assert resp.body == ["chunk1", "chunk2"]
    end

    async_finch? = Code.ensure_loaded?(Finch) and function_exported?(Finch, :async_request, 2)

    @tag skip: not async_finch?
    test "async request", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      {req, resp} = Req.async_request!(url: "http://localhost:#{c.bypass.port}")
      assert resp.status == 200
      assert {:ok, [data: "foo"]} = Req.parse_message(req, assert_receive(_))
      assert {:ok, [data: "bar"]} = Req.parse_message(req, assert_receive(_))
      assert {:ok, [:done]} = Req.parse_message(req, assert_receive(_))
      refute_receive _
    end

    @tag skip: not async_finch?
    test "async request cancellation", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      {req, resp} = Req.async_request!(url: "http://localhost:#{c.bypass.port}")
      assert resp.status == 200
      assert :ok = Req.cancel_async_request(req)
    end
  end

  defp json(conn, status, data) do
    conn =
      case Plug.Conn.get_resp_header(conn, "content-type") do
        [] ->
          Plug.Conn.put_resp_content_type(conn, "application/json")

        _ ->
          conn
      end

    Plug.Conn.send_resp(conn, status, Jason.encode_to_iodata!(data))
  end
end
