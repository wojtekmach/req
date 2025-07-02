defmodule Req.StepsTest do
  use ExUnit.Case, async: true
  import TestHelper, only: [start_http_server: 1, start_tcp_server: 1]
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
        start_http_server(fn conn ->
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
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get!(url, base_url: "ignored").body == "ok"
    end

    test "with base path" do
      %{url: url} =
        start_http_server(fn conn ->
          assert conn.request_path == "/api/v2/foo"
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      assert Req.get!("/foo", base_url: "#{url}/api/v2", retry: false).body == "ok"
      assert Req.get!("foo", base_url: "#{url}/api/v2").body == "ok"
      assert Req.get!("/foo", base_url: "#{url}/api/v2/").body == "ok"
      assert Req.get!("foo", base_url: "#{url}/api/v2/").body == "ok"
      assert Req.get!("", base_url: "#{url}/api/v2/foo").body == "ok"
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
      %{url: url} =
        start_http_server(fn conn ->
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

      assert Req.get!(url, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/tabs")

      File.write!("#{c.tmp_dir}/tabs", """
      machine localhost
           login foo
           password bar
      """)

      assert Req.get!(url, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/single_line")

      File.write!("#{c.tmp_dir}/single_line", """
      machine otherhost
      login meat
      password potatoes
      machine localhost login foo password bar
      """)

      assert Req.get!(url, auth: :netrc).status == 200

      if old_netrc, do: System.put_env("NETRC", old_netrc), else: System.delete_env("NETRC")
    end

    @tag :tmp_dir
    test "{:netrc, path}", c do
      %{url: url} =
        start_http_server(fn conn ->
          expected = "Basic " <> Base.encode64("foo:bar")

          case Plug.Conn.get_req_header(conn, "authorization") do
            [^expected] ->
              Plug.Conn.send_resp(conn, 200, "ok")

            _ ->
              Plug.Conn.send_resp(conn, 401, "unauthorized")
          end
        end)

      assert_raise RuntimeError, "error reading .netrc file: no such file or directory", fn ->
        Req.get!(url, auth: {:netrc, "non_existent_file"})
      end

      File.write!("#{c.tmp_dir}/custom_netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(url, auth: {:netrc, c.tmp_dir <> "/custom_netrc"}).status == 200

      File.write!("#{c.tmp_dir}/wrong_netrc", """
      machine localhost
      login bad
      password bad
      """)

      assert Req.get!(url, auth: {:netrc, "#{c.tmp_dir}/wrong_netrc"}).status == 401

      File.write!("#{c.tmp_dir}/empty_netrc", "")

      assert_raise RuntimeError, ".netrc file is empty", fn ->
        Req.get!(url, auth: {:netrc, "#{c.tmp_dir}/empty_netrc"})
      end

      File.write!("#{c.tmp_dir}/bad_netrc", """
      bad
      """)

      assert_raise RuntimeError, "error parsing .netrc file", fn ->
        Req.get!(url, auth: {:netrc, "#{c.tmp_dir}/bad_netrc"})
      end
    end
  end

  describe "encode_body" do
    # neither `body: data` nor `body: stream` is used by the step but testing these
    # here for locality
    test "body" do
      %{url: url} =
        start_http_server(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, body)
        end)

      req =
        Req.new(
          url: url,
          body: "foo"
        )

      assert Req.post!(req).body == "foo"
    end

    test "body stream" do
      %{url: url} =
        start_http_server(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, body)
        end)

      req =
        Req.new(
          url: url,
          body: Stream.take(~w[foo foo foo], 2)
        )

      assert Req.post!(req).body == "foofoo"
    end

    test "json" do
      %{url: url} =
        start_http_server(fn conn ->
          assert {:ok, ~s|{"a":1}|, conn} = Plug.Conn.read_body(conn)
          assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
          assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

          Plug.Conn.send_resp(conn, 200, "")
        end)

      Req.post!(url, json: %{a: 1})
    end

    test "form" do
      req = Req.new(form: [a: 1]) |> Req.Request.prepare()
      assert req.body == "a=1"

      req = Req.new(form: %{a: 1}) |> Req.Request.prepare()
      assert req.body == "a=1"
    end

    @tag :tmp_dir
    test "form_multipart", %{tmp_dir: tmp_dir} do
      File.write!("#{tmp_dir}/b.txt", "bbb")
      File.write!("#{tmp_dir}/c", "ccc")

      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-length") == ["391"]
        assert %{"a" => "1", "b" => b, "c" => c} = conn.body_params

        assert b.filename == "b.txt"
        assert b.content_type == "text/plain"
        assert File.read!(b.path) == "bbb"

        assert c.filename == "ccc"
        assert c.content_type == "application/octet-stream"
        assert File.read!(c.path) == "ccc"

        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert Req.post!(
               plug: plug,
               form_multipart: [
                 a: 1,
                 b: File.stream!("#{tmp_dir}/b.txt"),
                 c: {File.stream!("#{tmp_dir}/c"), filename: "ccc"}
               ]
             ).status == 200
    end

    test "form_multipart enum without size" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-length") == []
        assert %{"a" => "1", "b" => b} = conn.body_params

        assert b.filename == "cycle"
        assert b.content_type == "application/text"
        assert File.read!(b.path) == "abcabc"

        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert Req.post!(
               plug: plug,
               form_multipart: [
                 a: 1,
                 b:
                   {Stream.cycle(["a", "b", "c"]) |> Stream.take(6),
                    filename: "cycle", content_type: "application/text"}
               ]
             ).status == 200
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
    req =
      Req.new(url: "http://foo/:id{ola}", path_params: [id: "abc|def"]) |> Req.Request.prepare()

    assert URI.to_string(req.url) == "http://foo/abc%7Cdef{ola}"

    # With :curly style.

    req =
      Req.new(url: "http://foo/{id}:bar", path_params: [id: "abc|def"], path_params_style: :curly)
      |> Req.Request.prepare()

    assert URI.to_string(req.url) == "http://foo/abc%7Cdef:bar"
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

    test "stream" do
      %{url: url} =
        start_http_server(fn conn ->
          assert {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = :zlib.gunzip(body)
          Plug.Conn.send_resp(conn, 200, body)
        end)

      req =
        Req.new(
          url: url,
          method: :post,
          body: Stream.take(~w[foo foo foo], 2),
          compress_body: true
        )

      assert Req.post!(req).body == "foofoo"
    end

    test "nil body" do
      %{url: url} =
        start_http_server(fn conn ->
          assert Plug.Conn.get_req_header(conn, "content-encoding") == []
          Plug.Conn.send_resp(conn, 200, "ok")
        end)

      req = Req.new(url: url, compress_body: true)
      assert Req.get!(req).body == "ok"
    end
  end

  describe "checksum" do
    @foo_md5 "md5:acbd18db4cc2f85cedef654fccc4a4d8"
    @foo_sha1 "sha1:0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33"
    @foo_sha256 "sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"

    test "into: binary" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "foo")
        end)

      req = Req.new(url: url)

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

    test "into: binary with gzip" do
      %{url: url} =
        start_http_server(fn conn ->
          ["zstd, br, gzip"] = Plug.Conn.get_req_header(conn, "accept-encoding")

          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
        end)

      req = Req.new(url: url)

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

    test "into: fun" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "foo")
        end)

      req =
        Req.new(
          url: url,
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

    test "into: collectable" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "foo")
        end)

      req =
        Req.new(
          url: url,
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

    test "into: :self" do
      %{url: url} =
        start_http_server(fn conn ->
          Plug.Conn.send_resp(conn, 200, "foo")
        end)

      req =
        Req.new(
          url: url,
          into: :self
        )

      assert_raise ArgumentError, ":checksum cannot be used with `into: :self`", fn ->
        Req.get!(req, checksum: @foo_sha1)
      end
    end
  end

  describe "put_aws_sigv4" do
    test "body: binary" do
      plug = fn conn ->
        assert {:ok, "hello", conn} = Plug.Conn.read_body(conn)
        assert ["AWS4-HMAC-SHA256" <> _] = Plug.Conn.get_req_header(conn, "authorization")
        assert [<<_::binary-size(64)>>] = Plug.Conn.get_req_header(conn, "x-amz-content-sha256")
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        Req.new(
          url: "https://s3.amazonaws.com",
          aws_sigv4: [
            access_key_id: "foo",
            secret_access_key: "bar"
          ],
          body: "hello",
          plug: plug
        )

      assert Req.put!(req).body == "ok"
    end

    test "body: enumerable" do
      plug = fn conn ->
        assert {:ok, "hello", conn} = Plug.Conn.read_body(conn)
        assert ["AWS4-HMAC-SHA256" <> _] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["UNSIGNED-PAYLOAD"] = Plug.Conn.get_req_header(conn, "x-amz-content-sha256")
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        Req.new(
          url: "http://example.com",
          aws_sigv4: [
            access_key_id: "foo",
            secret_access_key: "bar",
            # test setting explicit :service
            service: :s3
          ],
          headers: [content_length: 5],
          body: Stream.take(["hello"], 1),
          plug: plug
        )

      assert Req.put!(req).body == "ok"
    end

    test "missing :access_key_id" do
      req = Req.new(aws_sigv4: [])

      assert_raise ArgumentError, "missing :access_key_id in :aws_sigv4 option", fn ->
        Req.get(req)
      end
    end

    test "missing :secret_access_key" do
      req = Req.new(aws_sigv4: [access_key_id: "foo"])

      assert_raise ArgumentError, "missing :secret_access_key in :aws_sigv4 option", fn ->
        Req.get(req)
      end
    end

    test "missing :service" do
      req =
        Req.new(
          aws_sigv4: [
            access_key_id: "foo",
            secret_access_key: "bar"
          ]
        )

      assert_raise ArgumentError, "missing :service in :aws_sigv4 option", fn ->
        Req.get(req)
      end
    end
  end

  ## Response steps

  describe "decompress_body" do
    test "gzip success" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
      end

      resp = Req.get!(plug: plug)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "gzip error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
        |> Plug.Conn.send_resp(200, "bad")
      end

      assert_raise Req.DecompressError, "gzip decompression failed", fn ->
        Req.get!(plug: plug)
      end
    end

    test "identity" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "identity")
        |> Plug.Conn.send_resp(200, "foo")
      end

      resp = Req.get!(plug: plug)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "brotli success" do
      plug = fn conn ->
        {:ok, body} = :brotli.encode("foo")

        conn
        |> Plug.Conn.put_resp_header("content-encoding", "br")
        |> Plug.Conn.send_resp(200, body)
      end

      resp = Req.get!(plug: plug)
      assert resp.body == "foo"
    end

    test "brotli error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "br")
        |> Plug.Conn.send_resp(200, "bad")
      end

      assert_raise Req.DecompressError, "br decompression failed", fn ->
        Req.get!(plug: plug)
      end
    end

    test "zstd success" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "zstd")
        |> Plug.Conn.send_resp(200, :ezstd.compress("foo"))
      end

      resp = Req.get!(plug: plug)
      assert resp.body == "foo"
    end

    test "zstd error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "zstd")
        |> Plug.Conn.send_resp(200, "bad")
      end

      assert_raise Req.DecompressError,
                   ~S[zstd decompression failed, reason: "failed to decompress: ZSTD_CONTENTSIZE_ERROR"],
                   fn ->
                     Req.get!(plug: plug)
                   end
    end

    test "multiple codecs" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip, zstd")
        |> Plug.Conn.send_resp(200, "foo" |> :zlib.gzip() |> :ezstd.compress())
      end

      resp = Req.get!(plug: plug)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "multiple codecs with multiple headers" do
      %{url: url} =
        start_tcp_server(fn socket ->
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
    test "unknown codecs" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "unknown1, unknown2")
        |> Plug.Conn.send_resp(200, <<1, 2, 3>>)
      end

      resp = Req.get!(plug: plug)
      assert Req.Response.get_header(resp, "content-encoding") == ["unknown1, unknown2"]
      assert resp.body == <<1, 2, 3>>
    end

    test "HEAD request" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, "")
      end

      assert Req.head!(plug: plug).body == ""
    end
  end

  describe "decode_body" do
    test "multiple types" do
      plug = fn conn ->
        headers =
          [
            {"content-type", "text/plain"},
            {"content-type", "text/plain; charset=utf-8"}
          ] ++ conn.resp_headers

        Plug.Conn.send_resp(%{conn | resp_headers: headers}, 200, "ok")
      end

      assert Req.get!(plug: plug).body == "ok"
    end

    test "json" do
      plug = fn conn ->
        Req.Test.json(conn, %{a: 1})
      end

      assert Req.get!(plug: plug).body == %{"a" => 1}
    end

    test "json-api" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/vnd.api+json; charset=utf-8")
        |> Req.Test.json(%{a: 1})
      end

      assert Req.get!(plug: plug).body == %{"a" => 1}
    end

    test "json with custom options" do
      plug = fn conn ->
        Req.Test.json(conn, %{a: 1})
      end

      assert Req.get!(plug: plug, decode_json: [keys: :atoms]).body == %{a: 1}
    end

    test "json invalid" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "bad")
      end

      assert {:error, %Jason.DecodeError{}} = Req.get(plug: plug)
    end

    test "tar (content-type)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-tar")
        |> Plug.Conn.send_resp(200, create_tar(files))
      end

      assert Req.get!(plug: plug).body == files
    end

    test "tar (path)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, create_tar(files))
      end

      assert Req.get!(plug: plug, url: "/foo.tar").body == files
    end

    test "tar (path, content type with charset utf8)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, create_tar(files))
      end

      resp = Req.get!(plug: plug, url: "/foo.tar")
      assert resp.headers["content-type"] == ["application/octet-stream; charset=utf-8"]
      assert resp.body == files
    end

    test "tar (path, no content-type)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, create_tar(files))
      end

      assert Req.get!(plug: plug, url: "/foo.tar.gz").body == files
    end

    test "tar.gz (path)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, create_tar(files, compressed: true))
      end

      assert Req.get!(plug: plug, url: "/foo.tar.gz").body == files
    end

    test "tar invalid" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-tar", nil)
        |> Plug.Conn.send_resp(200, "invalid")
      end

      assert {:error, e} = Req.get(plug: plug)
      assert e == %Req.ArchiveError{format: :tar, reason: :eof, data: "invalid"}
      assert Exception.message(e) == "tar unpacking failed: Unexpected end of file"
    end

    test "zip (content-type)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/zip", nil)
        |> Plug.Conn.send_resp(200, create_zip(files))
      end

      assert Req.get!(plug: plug).body == files
    end

    test "zip (path)" do
      files = [{~c"foo.txt", "bar"}]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, create_zip(files))
      end

      assert Req.get!(plug: plug, url: "/foo.zip").body == files
    end

    test "zip invalid" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/zip", nil)
        |> Plug.Conn.send_resp(200, "invalid")
      end

      assert {:error, e} = Req.get(plug: plug)
      assert e == %Req.ArchiveError{format: :zip, reason: nil, data: "invalid"}
      assert Exception.message(e) == "zip unpacking failed"
    end

    test "gzip (content-type)" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
        |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
      end

      assert Req.get!(plug: plug).body == "foo"
    end

    test "gzip invalid" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
        |> Plug.Conn.send_resp(200, "bad")
      end

      assert_raise ErlangError, "Erlang error: :data_error", fn ->
        Req.get(plug: plug)
      end
    end

    test "zstd (content-type)" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/zstd", nil)
        |> Plug.Conn.send_resp(200, :ezstd.compress("foo"))
      end

      assert Req.get!(plug: plug).body == "foo"
    end

    test "zstd (path)" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
        |> Plug.Conn.send_resp(200, :ezstd.compress("foo"))
      end

      assert Req.get!(plug: plug, url: "/foo.zst").body == "foo"
    end

    test "zstd invalid" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/zstd", nil)
        |> Plug.Conn.send_resp(200, "bad")
      end

      assert {:error, e} = Req.get(plug: plug)
      assert %RuntimeError{} = e

      assert Exception.message(e) ==
               "Could not decompress Zstandard data: \"failed to decompress: ZSTD_CONTENTSIZE_ERROR\""
    end

    test "csv" do
      csv = [
        ["x", "y"],
        ["1", "2"],
        ["3", "4"]
      ]

      plug = fn conn ->
        data = NimbleCSV.RFC4180.dump_to_iodata(csv)

        conn
        |> Plug.Conn.put_resp_content_type("text/csv")
        |> Plug.Conn.send_resp(200, data)
      end

      assert Req.get!(plug: plug).body == csv
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
        Req.get!(plug: plug)
      end)

    assert resp.body |> :zlib.uncompress() |> Jason.decode!() == %{"a" => 1}
    assert log =~ ~s|algorithm \"deflate\" is not supported|
  end

  describe "redirect" do
    test "ignore when :redirect is false" do
      %{url: url} =
        start_http_server(fn conn ->
          redirect(conn, 302, "/ok")
        end)

      assert Req.get!("#{url}/redirect", redirect: false).status == 302
    end

    test "absolute" do
      %{url: url} =
        start_http_server(fn
          conn when conn.request_path == "/redirect" ->
            redirect(conn, 302, "http://localhost:#{conn.port}/ok")

          conn when conn.request_path == "/ok" ->
            redirect(conn, 200, "/ok")
        end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!("#{url}/redirect", retry: false).status == 200
             end) =~ "[debug] redirecting to #{url}/ok"
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

    test "without location", c do
      Bypass.expect(c.bypass, "POST", "/redirect", fn conn ->
        Plug.Conn.send_resp(conn, 303, "")
      end)

      assert Req.post!(c.url <> "/redirect").status == 303
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

      req = Req.new(url: c.url, max_redirects: 3, redirect_log_level: false)
      {req, e} = Req.Request.run_request(req)

      assert_receive :ping
      assert_receive :ping
      assert_receive :ping
      assert_receive :ping
      refute_receive _

      assert req.private == %{req_redirect_count: 3}
      assert Exception.message(e) == "too many redirects (3)"
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

    test "inherit scheme" do
      adapter = fn
        request when request.url.path == "/redirect" ->
          response = Req.Response.new(status: 302, headers: %{"location" => ["//localhost/ok"]})
          {request, response}

        request ->
          assert request.url == URI.parse("http://localhost/ok")
          response = Req.Response.new(status: 200)
          {request, response}
      end

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(adapter: adapter, url: "http://localhost/redirect").status == 200
             end) =~ "[debug] redirecting to //localhost/ok"
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
               ~r/\[warning\][[:blank:]]+retry: got response with status 500, will retry in 1ms, 3 attempts left/u
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
    defp retry_after(%DateTime{} = dt), do: Req.Utils.format_http_date(dt)

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

    @tag :capture_log
    test "does not carry `halted` status over", c do
      adapter = fn request ->
        request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))

        attempt = request.private.attempt

        if attempt < 2 do
          Req.Request.halt(request, Req.Response.new(status: 500, body: "oops"))
        else
          {request, Req.Response.new(status: 200, body: "ok")}
        end
      end

      response_step = fn
        {request, %Req.Response{} = response} ->
          response = Req.Response.put_private(response, :ran_response_step, true)
          {request, response}

        {request, response} ->
          {request, response}
      end

      response =
        Req.new(url: c.url, adapter: adapter, retry_delay: &Integer.pow(2, &1))
        |> Req.Request.append_response_steps(response_step: response_step)
        |> Req.request!()

      assert %{ran_response_step: true} = response.private
    end
  end

  @tag :tmp_dir
  test "cache", c do
    pid = self()

    %{url: url} =
      start_http_server(fn conn ->
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

    request = Req.new(url: url, cache: true, cache_dir: c.tmp_dir)

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

    %{url: url} =
      start_http_server(fn conn ->
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
        url: url,
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

  describe "run_plug" do
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

    test "fetches query params" do
      plug = fn conn ->
        assert conn.query_params == %{"a" => "1"}
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert Req.request!(plug: plug, params: [a: 1]).body == "ok"
    end

    test "fetches request body" do
      plug = fn conn ->
        assert conn.body_params == %{"a" => 1}
        assert Req.Test.raw_body(conn) == "{\"a\":1}"
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert Req.post!(plug: plug, json: %{a: 1}).body == "ok"
    end

    test "into: fun" do
      req =
        Req.new(
          plug: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "foo")
            {:ok, conn} = Plug.Conn.chunk(conn, "bar")
            {:ok, conn} = Plug.Conn.chunk(conn, "baz")
            conn
          end,
          into: fn {:data, data}, {req, resp} ->
            body =
              if resp.body == "" do
                [data]
              else
                resp.body ++ [data]
              end

            {:cont, {req, put_in(resp.body, body)}}
          end
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == ["foo", "bar", "baz"]
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
            {:halt, {req, put_in(resp.body, [data])}}
          end
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == ["foo"]
      refute_receive _
    end

    test "into: fun with send_resp" do
      req =
        Req.new(
          plug: fn conn ->
            Plug.Conn.send_resp(conn, 200, "foo")
          end,
          into: fn {:data, data}, {req, resp} ->
            {:cont, {req, put_in(resp.body, [data])}}
          end
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == ["foo"]
      refute_receive _
    end

    test "into: fun with send_file" do
      req =
        Req.new(
          plug: fn conn ->
            Plug.Conn.send_file(conn, 200, "mix.exs")
          end,
          into: fn {:data, data}, {req, resp} ->
            {:cont, {req, put_in(resp.body, [data])}}
          end
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert ["defmodule Req.MixProject do" <> _] = resp.body
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
      assert resp.body == ["foo", "bar"]
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

    test "into: collectable non-200" do
      # Ignores the collectable and returns body as usual

      req =
        Req.new(
          plug: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 404)
            {:ok, conn} = Plug.Conn.chunk(conn, "foo")
            {:ok, conn} = Plug.Conn.chunk(conn, "bar")
            conn
          end,
          into: :not_a_collectable
        )

      resp = Req.request!(req)
      assert resp.status == 404
      assert resp.body == "foobar"
      refute_receive _
    end

    test "into: self" do
      req =
        Req.new(
          plug: fn conn ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "foo")
            {:ok, conn} = Plug.Conn.chunk(conn, "bar")
            conn
          end,
          into: :self
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert {:ok, [data: "foo"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [data: "bar"]} = Req.parse_message(resp, assert_receive(_))
      assert {:ok, [:done]} = Req.parse_message(resp, assert_receive(_))
      refute_receive _

      resp = Req.request!(req)
      assert resp.status == 200
      assert Enum.to_list(resp.body) == ["foo", "bar"]
      refute_receive _
    end

    test "errors" do
      req =
        Req.new(
          plug: fn conn ->
            Req.Test.transport_error(conn, :timeout)
          end,
          retry: false
        )

      assert Req.request(req) ==
               {:error, %Req.TransportError{reason: :timeout}}
    end

    test "bad return" do
      plug = fn _ ->
        :bad
      end

      assert_raise ArgumentError, "expected to return %Plug.Conn{}, got: :bad", fn ->
        Req.request!(plug: plug)
      end
    end

    test "no response" do
      plug = fn conn ->
        conn
      end

      assert_raise RuntimeError, ~r"expected connection to have a response", fn ->
        Req.request!(plug: plug)
      end
    end
  end

  def create_tar(files, options \\ []) when is_list(files) do
    options = Keyword.validate!(options, compressed: false)
    compressed = Keyword.fetch!(options, :compressed)

    fun = fn
      :write, {pid, data} -> IO.write(pid, data)
      :position, {_pid, {:cur, 0}} -> {:ok, 0}
      :close, _pid -> :ok
    end

    {:ok, pid} = StringIO.open("")
    {:ok, tar} = :erl_tar.init(pid, :write, fun)

    for {path, content} <- files do
      :ok = :erl_tar.add(tar, content, to_charlist(path), [])
    end

    :ok = :erl_tar.close(tar)
    data = StringIO.flush(pid)
    if compressed, do: :zlib.gzip(data), else: data
  end

  defp create_zip(files) when is_list(files) do
    {:ok, {"a.zip", files}} = :zip.create("a.zip", files, [:memory])
    files
  end
end
