defmodule Req.StepsTest do
  use ExUnit.Case, async: true

  require Logger

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  ## Request steps

  describe "compressed" do
    test "sets accept-encoding" do
      req = Req.new() |> Req.Request.prepare()
      assert req.headers["accept-encoding"] == ["zstd, br, gzip"]
    end

    test "does not set accept-encoding when streaming response body" do
      req = Req.new(into: []) |> Req.Request.prepare()
      refute req.headers["accept-encoding"]
    end
  end

  describe "put_base_url" do
    test "it works" do
      %{url: url} =
        start_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get!("/", base_url: url).body == "ok"
      assert Req.get!("", base_url: url).body == "ok"

      req = Req.new(base_url: url)
      assert Req.get!(req, url: "/").body == "ok"
      assert Req.get!(req, url: "").body == "ok"
    end

    test "with absolute url" do
      %{url: url} =
        start_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get!(url, base_url: "ignored").body == "ok"
    end

    test "with base path" do
      %{url: url} =
        start_server(fn conn ->
          assert conn.request_path == "/api/v2/foo"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get!("/foo", base_url: url <> "/api/v2", retry: false).body == "ok"
      assert Req.get!("foo", base_url: url <> "/api/v2").body == "ok"
      assert Req.get!("/foo", base_url: url <> "/api/v2/").body == "ok"
      assert Req.get!("foo", base_url: url <> "/api/v2/").body == "ok"
      assert Req.get!("", base_url: url <> "/api/v2/foo").body == "ok"
    end

    test "function" do
      plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, conn.request_path)
      end

      assert Req.get!(plug: plug, base_url: fn -> "/api/v1" end).body == "/api/v1"
      assert Req.get!(plug: plug, base_url: fn -> "/api/v1" end, url: "foo").body == "/api/v1/foo"
      assert Req.get!(plug: plug, base_url: fn -> URI.new!("/api/v1") end).body == "/api/v1"
      assert Req.get!(plug: plug, base_url: {URI, :new!, ["/api/v1"]}).body == "/api/v1"
    end
  end

  describe "auth" do
    test "string" do
      req = Req.new(auth: "foo") |> Req.Request.prepare()

      assert Req.Request.get_header(req, "authorization") == ["foo"]
    end

    test "basic" do
      req = Req.new(auth: {:basic, "foo:bar"}) |> Req.Request.prepare()

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

  describe "checksum" do
    @foo_md5 "md5:acbd18db4cc2f85cedef654fccc4a4d8"
    @foo_sha1 "sha1:0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33"
    @foo_sha256 "sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"

    test "into: binary", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "foo")
      end)

      req = Req.new(url: c.url)

      resp = Req.get!(req, checksum: @foo_md5)
      assert resp.body == "foo"

      resp = Req.get!(req, checksum: @foo_sha1)
      assert resp.body == "foo"

      resp = Req.get!(req, checksum: @foo_sha256)
      assert resp.body == "foo"

      assert_raise Req.ChecksumMismatchError,
                   """
                   checksum mismatch
                   expected: sha1:bad
                   actual:   #{@foo_sha1}\
                   """,
                   fn ->
                     Req.get!(req, checksum: "sha1:bad")
                   end
    end

    # TODO
    @tag :skip
    test "into: binary with gzip", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        ["zstd, br, gzip"] = Plug.Conn.get_req_header(conn, "accept-encoding")

        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
      end)

      req = Req.new(url: c.url)

      resp = Req.get!(req, checksum: @foo_md5)
      assert resp.body == "foo"

      assert_raise Req.ChecksumMismatchError,
                   """
                   checksum mismatch
                   expected: sha1:bad
                   actual:   #{@foo_sha1}\
                   """,
                   fn ->
                     Req.get!(req, checksum: "sha1:bad")
                   end
    end

    test "into: fun", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "foo")
      end)

      req =
        Req.new(
          url: c.url,
          into: fn {:data, chunk}, {req, resp} ->
            {:cont, {req, update_in(resp.body, &(&1 <> chunk))}}
          end
        )

      resp = Req.get!(req, checksum: @foo_sha1)
      assert resp.body == "foo"

      resp = Req.get!(req, checksum: @foo_sha256)
      assert resp.body == "foo"

      assert_raise Req.ChecksumMismatchError,
                   """
                   checksum mismatch
                   expected: sha1:bad
                   actual:   #{@foo_sha1}\
                   """,
                   fn ->
                     Req.get!(req, checksum: "sha1:bad")
                   end
    end

    test "into: collectable", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "foo")
      end)

      req =
        Req.new(
          url: c.url,
          into: []
        )

      resp = Req.get!(req, checksum: @foo_sha1)
      assert resp.body == ["foo"]

      resp = Req.get!(req, checksum: @foo_sha256)
      assert resp.body == ["foo"]

      assert_raise Req.ChecksumMismatchError,
                   """
                   checksum mismatch
                   expected: sha1:bad
                   actual:   #{@foo_sha1}\
                   """,
                   fn ->
                     Req.get!(req, checksum: "sha1:bad")
                   end
    end

    test "into: :self", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        Plug.Conn.send_resp(conn, 200, "foo")
      end)

      req =
        Req.new(
          url: c.url,
          into: :self
        )

      assert_raise ArgumentError, ":checksum cannot be used with `into: :self`", fn ->
        Req.get!(req, checksum: @foo_sha1)
      end
    end
  end

  describe "put_aws_sigv4" do
    # TODO: flaky
    @tag :skip
    test "body: binary" do
      plug = fn conn ->
        assert {:ok, "hello", conn} = Plug.Conn.read_body(conn)

        assert Plug.Conn.get_req_header(conn, "x-amz-content-sha256") == [
                 "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
               ]

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 """
                 AWS4-HMAC-SHA256 \
                 Credential=foo/20240101/us-east-1/s3/aws4_request,\
                 SignedHeaders=accept-encoding;host;user-agent;x-amz-content-sha256;x-amz-date,\
                 Signature=a7a27655988cf90a6d834c6544e8a5e1ef00308a64692f0e656167165d42ec4d\
                 """
               ]

        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        Req.new(
          url: "http://localhost",
          aws_sigv4: [
            access_key_id: "foo",
            secret_access_key: "bar",
            service: :s3,
            datetime: ~U[2024-01-01 00:00:00Z]
          ],
          body: "hello",
          plug: plug
        )

      assert Req.put!(req).body == "ok"
    end

    # TODO: flaky
    @tag :skip
    test "body: enumerable" do
      plug = fn conn ->
        assert {:ok, "hello", conn} = Plug.Conn.read_body(conn)

        assert Plug.Conn.get_req_header(conn, "x-amz-content-sha256") == ["UNSIGNED-PAYLOAD"]

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 """
                 AWS4-HMAC-SHA256 \
                 Credential=foo/20240101/us-east-1/s3/aws4_request,\
                 SignedHeaders=accept-encoding;content-length;host;user-agent;x-amz-content-sha256;x-amz-date,\
                 Signature=6d8d9e360bf82d48064ee93cc628133da813bfc9b587fe52f8792c2335b29312\
                 """
               ]

        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        Req.new(
          url: "http://localhost",
          aws_sigv4: [
            access_key_id: "foo",
            secret_access_key: "bar",
            service: :s3,
            datetime: ~U[2024-01-01 00:00:00Z]
          ],
          headers: [content_length: 5],
          body: Stream.take(["hello"], 1),
          plug: plug
        )

      assert Req.put!(req).body == "ok"
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
        TestSocket.serve(fn socket ->
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
      assert Req.Response.get_header(resp, "content-length") == []
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
  end

  describe "output" do
    unless System.get_env("REQ_NOWARN_OUTPUT") do
      @describetag :skip
    end

    @tag :tmp_dir
    test "decode_body with output", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        Req.Test.json(conn, %{a: 1})
      end)

      assert Req.get!(c.url, output: c.tmp_dir <> "/a.json").body == ""
      assert File.read!(c.tmp_dir <> "/a.json") == ~s|{"a":1}|
    end

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
        Req.Test.json(conn, %{a: 1})
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
    test "multiple types", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        headers =
          [
            {"content-type", "text/plain"},
            {"content-type", "text/plain; charset=utf-8"}
          ] ++ conn.resp_headers

        Plug.Conn.send_resp(%{conn | resp_headers: headers}, 200, "ok")
      end)

      assert Req.get!(c.url).body == "ok"
    end

    test "json", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        Req.Test.json(conn, %{a: 1})
      end)

      assert Req.get!(c.url).body == %{"a" => 1}
    end

    test "json-api", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/vnd.api+json; charset=utf-8")
        |> Req.Test.json(%{a: 1})
      end)

      assert Req.get!(c.url).body == %{"a" => 1}
    end

    test "json with custom options", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        Req.Test.json(conn, %{a: 1})
      end)

      assert Req.get!(c.url, decode_json: [keys: :atoms]).body == %{a: 1}
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

    {resp, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Req.get!("", plug: plug)
      end)

    assert resp.body |> :zlib.uncompress() |> Jason.decode!() == %{"a" => 1}
    assert log =~ ~s|algorithm \"deflate\" is not supported|
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

    test "change POST to GET to get on 301..303", c do
      for status <- 301..303 do
        Bypass.expect(c.bypass, "POST", "/redirect", fn conn ->
          redirect(conn, status, c.url <> "/ok")
        end)

        Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

        assert ExUnit.CaptureLog.capture_log(fn ->
                 assert Req.post!(c.url <> "/redirect", body: "body").status == 200
               end) =~ "[debug] redirecting to #{c.url}/ok"
      end
    end

    test "do not change method on 307 and 308", c do
      for status <- [307, 308] do
        Bypass.expect(c.bypass, "POST", "/redirect", fn conn ->
          redirect(conn, status, c.url <> "/ok")
        end)

        Bypass.expect(c.bypass, "POST", "/ok", fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

        assert ExUnit.CaptureLog.capture_log(fn ->
                 assert Req.post!(c.url <> "/redirect", body: "body").status == 200
               end) =~ "[debug] redirecting to #{c.url}/ok"
      end
    end

    test "never change HEAD requests", c do
      for status <- [301, 302, 303, 307, 307] do
        Bypass.expect(c.bypass, "HEAD", "/redirect", fn conn ->
          redirect(conn, status, c.url <> "/ok")
        end)

        Bypass.expect(c.bypass, "HEAD", "/ok", fn conn ->
          Plug.Conn.send_resp(conn, 200, "")
        end)

        assert ExUnit.CaptureLog.capture_log(fn ->
                 assert Req.head!(c.url <> "/redirect").status == 200
               end) =~ "[debug] redirecting to #{c.url}/ok"
      end
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
               assert Req.get!(c.url <> "/redirect", auth: {:basic, "foo:bar"}).status == 200
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
                        auth: {:basic, "authorization:credentials"},
                        redirect_trusted: true
                      ).status == 200
             end) =~ "[debug] redirecting to http://untrusted"
    end

    test "auth different host" do
      adapter = untrusted_redirect_adapter(:host, "trusted", "untrusted")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://trusted",
                        adapter: adapter,
                        auth: {:basic, "authorization:credentials"}
                      ).status == 200
             end) =~ "[debug] redirecting to http://untrusted"
    end

    test "auth different port" do
      adapter = untrusted_redirect_adapter(:port, 12345, 23456)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://trusted:12345",
                        adapter: adapter,
                        auth: {:basic, "authorization:credentials"}
                      ).status == 200
             end) =~ "[debug] redirecting to http://trusted:23456"
    end

    test "auth different scheme" do
      adapter = untrusted_redirect_adapter(:scheme, "http", "https")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("http://trusted",
                        adapter: adapter,
                        auth: {:basic, "authorization:credentials"}
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
          assert_raise Req.TooManyRedirectsError, "too many redirects (3)", fn ->
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

    test "invalid :retry_delay" do
      adapter = fn request ->
        {request, Req.Response.new(status: 500)}
      end

      req = Req.new(adapter: adapter, retry_delay: fn _ -> :ok end)

      assert_raise ArgumentError,
                   "expected :retry_delay function to return non-negative integer, got: :ok",
                   fn ->
                     Req.request!(req)
                   end
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
          |> Req.Test.json(%{a: 1})

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
      refute_receive _
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
      refute_receive _
    end

    test "into: fun" do
      req =
        Req.new(
          plug: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "foo")
            {:ok, conn} = Plug.Conn.chunk(conn, "bar")
            conn
          end,
          into: fn {:data, data}, {req, resp} ->
            resp = update_in(resp.body, &(&1 <> data))
            {:cont, {req, resp}}
          end
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == "foobar"
      refute_receive _
    end

    test "into: fun with halt" do
      req =
        Req.new(
          plug: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "foo")
            {:ok, conn} = Plug.Conn.chunk(conn, "bar")
            conn
          end,
          into: fn {:data, data}, {req, resp} ->
            resp = update_in(resp.body, &(&1 <> data))
            {:halt, {req, resp}}
          end
        )

      {resp, output} = ExUnit.CaptureIO.with_io(:standard_error, fn -> Req.request!(req) end)
      assert output =~ ~r/returning {:halt, acc} is not yet supported by Plug adapter/
      assert resp.status == 200
      assert resp.body == "foobar"
      refute_receive _
    end

    test "into: collectable" do
      req =
        Req.new(
          plug: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "foo")
            {:ok, conn} = Plug.Conn.chunk(conn, "bar")
            conn
          end,
          into: []
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == ["foobar"]
      refute_receive _
    end

    test "into: collectable with send_resp" do
      req =
        Req.new(
          plug: fn conn ->
            Plug.Conn.send_resp(conn, 200, "foo")
          end,
          into: []
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == ["foo"]
      refute_receive _
    end

    test "into: collectable with send_file" do
      req =
        Req.new(
          plug: fn conn ->
            Plug.Conn.send_file(conn, 200, "mix.exs")
          end,
          into: []
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert ["defmodule Req.MixProject do" <> _] = resp.body
      refute_receive _
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

    test ":receive_timeout" do
      pid = self()

      %{url: url} =
        TestSocket.serve(fn socket ->
          assert {:ok, "GET / HTTP/1.1\r\n" <> _} = :gen_tcp.recv(socket, 0)
          send(pid, :ping)
          body = "ok"

          Process.sleep(1000)

          data = """
          HTTP/1.1 200 OK
          content-length: #{byte_size(body)}

          #{body}
          """

          :ok = :gen_tcp.send(socket, data)
        end)

      req = Req.new(url: url, receive_timeout: 50, retry: false)
      assert {:error, %Mint.TransportError{reason: :timeout}} = Req.request(req)
      assert_received :ping
    end

    test ":connect_options :protocol", c do
      Bypass.stub(c.bypass, "GET", "/", fn conn ->
        {_, %{version: :"HTTP/2"}} = conn.adapter
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      req = Req.new(url: c.url, connect_options: [protocols: [:http2]])
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

    def send_telemetry_metadata_pid(_name, _measurements, metadata, _) do
      send(metadata.request.private.pid, :telemetry_private)
      :ok
    end

    test ":finch_private", c do
      on_exit(fn -> :telemetry.detach("#{c.test}") end)

      :ok =
        :telemetry.attach(
          "#{c.test}",
          [:finch, :request, :stop],
          &__MODULE__.send_telemetry_metadata_pid/4,
          nil
        )

      Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
        Plug.Conn.send_resp(conn, 200, "finch_private")
      end)

      assert Req.get!(c.url <> "/ok", finch_private: %{pid: self()}).body == "finch_private"
      assert_received :telemetry_private
    end

    test "into: fun" do
      %{url: url} =
        TestSocket.serve(fn socket ->
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

      assert resp.trailers["x-foo"] == ["foo"]
      assert resp.trailers["x-bar"] == ["bar"]

      assert_receive {:data, "chunk1"}
      assert_receive {:data, "chunk2"}
      refute_receive _
    end

    test "into: fun with halt" do
      # try fixing `** (exit) shutdown` on CI by starting custom server
      defmodule StreamPlug do
        def init(options), do: options

        def call(conn, []) do
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end
      end

      start_supervised!({Plug.Cowboy, plug: StreamPlug, scheme: :http, port: 0})
      url = "http://localhost:#{:ranch.get_port(StreamPlug.HTTP)}"

      resp =
        Req.get!(
          url: url,
          into: fn {:data, data}, {req, resp} ->
            resp = update_in(resp.body, &(&1 <> data))
            {:halt, {req, resp}}
          end
        )

      assert resp.status == 200
      assert resp.body == "foo"
    end

    test "into: fun handle error", %{bypass: bypass, url: url} do
      Bypass.down(bypass)

      assert {:error, %Mint.TransportError{reason: :econnrefused}} =
               Req.get(
                 url: url,
                 retry: false,
                 into: fn {:data, data}, {req, resp} ->
                   resp = update_in(resp.body, &(&1 <> data))
                   {:halt, {req, resp}}
                 end
               )
    end

    test "into: collectable" do
      %{url: url} =
        TestSocket.serve(fn socket ->
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

      assert resp.trailers["x-foo"] == ["foo"]
      assert resp.trailers["x-bar"] == ["bar"]

      assert resp.body == ["chunk1", "chunk2"]
    end

    test "into: collectable handle error", %{bypass: bypass, url: url} do
      Bypass.down(bypass)

      assert {:error, %Mint.TransportError{reason: :econnrefused}} =
               Req.get(
                 url: url,
                 retry: false,
                 into: IO.stream()
               )
    end

    # TODO
    @tag :skip
    test "into: fun with content-encoding", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
      end)

      pid = self()

      fun = fn {:data, data}, acc ->
        send(pid, {:data, data})
        {:cont, acc}
      end

      assert Req.get!(c.url, into: fun).body == ""
      assert_received {:data, "foo"}
      refute_receive _
    end

    test "into: :self", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      resp = Req.get!(url: "http://localhost:#{c.bypass.port}", into: :self)
      assert resp.status == 200
      assert {:ok, [data: "foo"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [data: "bar"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [:done]} = Req.parse_message(resp, assert_receive(_))
      refute_receive _
    end

    test "into: :self cancel", c do
      Bypass.expect(c.bypass, "GET", "/", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "foo")
        {:ok, conn} = Plug.Conn.chunk(conn, "bar")
        conn
      end)

      resp = Req.get!(url: "http://localhost:#{c.bypass.port}", into: :self)
      assert resp.status == 200
      assert :ok = Req.cancel_async_response(resp)
    end
  end

  defp start_server(plug) do
    plug = fn conn, _ -> plug.(conn) end
    pid = start_supervised!({Bandit, scheme: :http, port: 0, startup_log: false, plug: plug})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{pid: pid, url: "http://localhost:#{port}"}
  end
end
