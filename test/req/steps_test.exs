defmodule Req.StepsTest do
  use Req.Case, async: true

  ## Request steps

  describe "compressed" do
    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "sets accept-encoding when compressed: true" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "accept-encoding") == ["zstd, br, gzip"]
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, compressed: true)
    end

    test "does not set accept-encoding by default" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "accept-encoding") == []
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req)
    end

    test "does not set accept-encoding when streaming response body" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "accept-encoding") == []
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, compressed: true, into: [])
    end

    test "does not set accept-encoding when streaming response body with into: fun" do
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
  end

  describe "put_base_url" do
    test "it works" do
      %{req: req, url: url} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, base_url: url, url: "/").body == "ok"
      assert Req.get!(req, base_url: url, url: "").body == "ok"

      req = Req.merge(req, base_url: url)
      assert Req.get!(req, url: "/").body == "ok"
      assert Req.get!(req, url: "").body == "ok"
    end

    test "with absolute url" do
      %{req: req, url: url} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, base_url: "ignored", url: url).body == "ok"
    end

    test "with base path" do
      %{req: req, url: url} =
        serve("GET /api/v2/foo": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, base_url: "#{url}/api/v2", url: "/foo", retry: false).body == "ok"
      assert Req.get!(req, base_url: "#{url}/api/v2", url: "foo").body == "ok"
      assert Req.get!(req, base_url: "#{url}/api/v2/", url: "/foo").body == "ok"
      assert Req.get!(req, base_url: "#{url}/api/v2/", url: "foo").body == "ok"
      assert Req.get!(req, base_url: "#{url}/api/v2/foo", url: "").body == "ok"
    end

    test "function" do
      %{req: req, url: url} =
        serve_sequence(
          "GET /api/v1": &send_resp(&1, 200, "ok"),
          "GET /api/v1/foo": &send_resp(&1, 200, "ok"),
          "GET /api/v1": &send_resp(&1, 200, "ok"),
          "GET /api/v1": &send_resp(&1, 200, "ok")
        )

      assert Req.get!(req, base_url: fn -> "#{url}/api/v1" end, url: "").body == "ok"
      assert Req.get!(req, base_url: fn -> "#{url}/api/v1" end, url: "foo").body == "ok"
      assert Req.get!(req, base_url: fn -> URI.new!("#{url}/api/v1") end, url: "").body == "ok"
      assert Req.get!(req, base_url: {URI, :new!, ["#{url}/api/v1"]}, url: "").body == "ok"
    end
  end

  describe "auth" do
    test "string" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "authorization") == ["foo"]
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, auth: "foo")
    end

    test "basic" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            expected = "Basic " <> Base.encode64("foo:bar")
            assert get_req_header(conn, "authorization") == [expected]
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, auth: {:basic, "foo:bar"})
    end

    test "bearer" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "authorization") == ["Bearer abcd"]
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, auth: {:bearer, "abcd"})
    end

    test "digest" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            # Does not apply authorization header until after the pre-authorized request is made
            assert get_req_header(conn, "authorization") == []
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, auth: {:digest, "foo:bar"})
    end

    test "mfa" do
      defmodule AuthToken do
        def generate, do: {:bearer, "abcd"}
      end

      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "authorization") == ["Bearer abcd"]
            send_resp(conn, 200, "")
          end
        )

      Req.get!(req, auth: {AuthToken, :generate, []})
    end

    @tag :tmp_dir
    test ":netrc", c do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            expected = "Basic " <> Base.encode64("foo:bar")

            case get_req_header(conn, "authorization") do
              [^expected] ->
                send_resp(conn, 200, "ok")

              _ ->
                send_resp(conn, 401, "unauthorized")
            end
          end
        )

      old_netrc = System.get_env("NETRC")

      System.put_env("NETRC", "#{c.tmp_dir}/.netrc")

      File.write!("#{c.tmp_dir}/.netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(req, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/tabs")

      File.write!("#{c.tmp_dir}/tabs", """
      machine localhost
           login foo
           password bar
      """)

      assert Req.get!(req, auth: :netrc).status == 200

      System.put_env("NETRC", "#{c.tmp_dir}/single_line")

      File.write!("#{c.tmp_dir}/single_line", """
      machine otherhost
      login meat
      password potatoes
      machine localhost login foo password bar
      """)

      assert Req.get!(req, auth: :netrc).status == 200

      if old_netrc, do: System.put_env("NETRC", old_netrc), else: System.delete_env("NETRC")
    end

    @tag :tmp_dir
    test "{:netrc, path}", c do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            expected = "Basic " <> Base.encode64("foo:bar")

            case get_req_header(conn, "authorization") do
              [^expected] ->
                send_resp(conn, 200, "ok")

              _ ->
                send_resp(conn, 401, "unauthorized")
            end
          end
        )

      assert_raise RuntimeError, "error reading .netrc file: no such file or directory", fn ->
        Req.get!(req, auth: {:netrc, "non_existent_file"})
      end

      File.write!("#{c.tmp_dir}/custom_netrc", """
      machine localhost
      login foo
      password bar
      """)

      assert Req.get!(req, auth: {:netrc, c.tmp_dir <> "/custom_netrc"}).status == 200

      File.write!("#{c.tmp_dir}/wrong_netrc", """
      machine localhost
      login bad
      password bad
      """)

      assert Req.get!(req, auth: {:netrc, "#{c.tmp_dir}/wrong_netrc"}).status == 401

      File.write!("#{c.tmp_dir}/empty_netrc", "")

      assert_raise RuntimeError, ".netrc file is empty", fn ->
        Req.get!(req, auth: {:netrc, "#{c.tmp_dir}/empty_netrc"})
      end

      File.write!("#{c.tmp_dir}/bad_netrc", """
      bad
      """)

      assert_raise RuntimeError, "error parsing .netrc file", fn ->
        Req.get!(req, auth: {:netrc, "#{c.tmp_dir}/bad_netrc"})
      end
    end
  end

  describe "encode_body" do
    # neither `body: data` nor `body: stream` is used by the step but testing these
    # here for locality
    test "body" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            {:ok, body, conn} = read_body(conn)
            send_resp(conn, 200, body)
          end
        )

      assert Req.post!(req, body: "foo").body == "foo"
    end

    test "body stream" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            {:ok, body, conn} = read_body(conn)
            send_resp(conn, 200, body)
          end
        )

      assert Req.post!(req, body: Stream.take(~w[foo foo foo], 2)).body == "foofoo"
    end

    test "json" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert {:ok, ~s|{"a":1}|, conn} = read_body(conn)
            assert ["application/json"] = get_req_header(conn, "accept")
            assert ["application/json"] = get_req_header(conn, "content-type")

            send_resp(conn, 200, "")
          end
        )

      Req.post!(req, json: %{a: 1})
    end

    test "form" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert {:ok, "a=1", conn} = read_body(conn)
            send_resp(conn, 200, "")
          end
        )

      Req.post!(req, form: [a: 1])
      Req.post!(req, form: %{a: 1})
    end

    @tag :tmp_dir
    test "form_multipart", %{tmp_dir: tmp_dir} do
      File.write!("#{tmp_dir}/b.txt", "bbb")
      File.write!("#{tmp_dir}/c", "ccc")

      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert get_req_header(conn, "content-length") == ["391"]
            assert %{"a" => "1", "b" => b, "c" => c} = conn.body_params

            assert b.filename == "b.txt"
            assert b.content_type == "text/plain"
            assert File.read!(b.path) == "bbb"

            assert c.filename == "ccc"
            assert c.content_type == "application/octet-stream"
            assert File.read!(c.path) == "ccc"

            send_resp(conn, 200, "ok")
          end
        )

      assert Req.post!(
               req,
               form_multipart: [
                 a: 1,
                 b: File.stream!("#{tmp_dir}/b.txt"),
                 c: {File.stream!("#{tmp_dir}/c"), filename: "ccc"}
               ]
             ).status == 200
    end

    test "form_multipart enum without size" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert get_req_header(conn, "content-length") == []
            assert %{"a" => "1", "b" => b} = conn.body_params

            assert b.filename == "cycle"
            assert b.content_type == "application/text"
            assert File.read!(b.path) == "abcabc"

            send_resp(conn, 200, "ok")
          end
        )

      assert Req.post!(
               req,
               form_multipart: [
                 a: 1,
                 b:
                   {Stream.cycle(["a", "b", "c"]) |> Stream.take(6),
                    filename: "cycle", content_type: "application/text"}
               ]
             ).status == 200
    end

    @tag :capture_log
    test "form_multipart: content-type boundary stays in sync with body on retry" do
      %{req: req} =
        serve_sequence(
          "POST /": fn conn ->
            assert conn.body_params == %{"a" => "1"}
            send_resp(conn, 500, "")
          end,
          "POST /": fn conn ->
            assert conn.body_params == %{"a" => "1"}
            send_resp(conn, 200, "")
          end
        )

      assert Req.post!(req, form_multipart: [a: 1], retry: :transient, retry_delay: 1).status ==
               200
    end

    test "GET to POST" do
      %{req: req} =
        serve(
          "GET /": &send_resp(&1, 200, &1.method),
          "POST /": &send_resp(&1, 200, &1.method),
          "PUT /": &send_resp(&1, 200, &1.method)
        )

      assert Req.request!(req).body == "GET"
      assert Req.request!(req, body: "").body == "POST"
      assert Req.request!(req, body: "foo").body == "POST"
      assert Req.request!(req, json: %{a: 1}).body == "POST"
      assert Req.request!(req, json: %{a: 1}, method: :put).body == "PUT"
    end
  end

  test "put_params" do
    %{req: req, url: url} =
      serve(
        "GET /": fn conn ->
          send_resp(conn, 200, conn.query_string)
        end
      )

    assert Req.get!(req, params: [x: 1, y: 2]).body == "x=1&y=2"
    assert Req.get!(req, params: [x: 1, x: 2]).body == "x=2"
    assert Req.get!(req, url: "#{url}?x=1", params: [x: 9, y: 2]).body == "x=9&y=2"
    assert Req.get!(req, url: "#{url}?x=1&x=2&y=1", params: [x: 9]).body == "x=9&x=2&y=1"
  end

  # TODO: support this?
  test "put_params with list value" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, ""))

    assert_raise ArgumentError, "encode_query/2 values cannot be lists, got: [1, 2]", fn ->
      Req.get!(req, params: [a: [1, 2]])
    end
  end

  test "put_path_params" do
    %{req: req, url: url} =
      serve(&send_resp(&1, 200, &1.request_path))

    assert Req.get!(req, url: "#{url}/:id/ola", path_params: [id: "abc|def"]).body ==
             "/abc%7Cdef/ola"

    # With :curly style.

    assert Req.get!(req,
             url: "#{url}/{id}:bar",
             path_params: [id: "abc|def"],
             path_params_style: :curly
           ).body == "/abc%7Cdef:bar"
  end

  @tag skip: Req.Case.adapter() in [:httpc, :plug]
  test "put_path_params does not expand curly segments in :colon style" do
    %{req: req, url: url} = serve("GET /": &send_resp(&1, 200, ""))

    assert {:error, %Req.HTTPError{reason: {:invalid_request_target, "/abc{ola}"}}} =
             Req.request(req, url: "#{url}/:id{ola}", path_params: [id: "abc"], retry: false)
  end

  test "put_path_params when path_params are empty still sets the template" do
    %{req: req, url: url} =
      serve("GET /bar": &send_resp(&1, 200, ""))

    {sent, _resp} = Req.run!(req, url: "#{url}/bar", path_params: [])
    assert Req.Request.get_private(sent, :path_params_template)

    {sent, _resp} = Req.run!(req, url: "#{url}/bar")
    refute Req.Request.get_private(sent, :path_params_template)
  end

  @tag :capture_log
  test "put_path_params is idempotent" do
    %{req: req, url: url} =
      serve("GET /users/123": &send_resp(&1, 500, ""))

    {req, resp} =
      Req.run!(req, url: "#{url}/users/:id", path_params: [id: 123], retry_delay: 1)

    assert resp.status == 500
    assert req.url.path == "/users/123"
    assert Req.Request.get_private(req, :path_params_template) == "/users/:id"
  end

  test "put_path_params properly escapes reserved characters" do
    %{req: req, url: url} =
      serve(&send_resp(&1, 200, &1.request_path))

    assert Req.get!(req, url: "#{url}/:id/ola", path_params: [id: "abc#def"]).body ==
             "/abc%23def/ola"

    # With :curly style.

    assert Req.get!(req,
             url: "#{url}/{id}:bar",
             path_params: [id: "abc#def"],
             path_params_style: :curly
           ).body == "/abc%23def:bar"
  end

  test "put_range" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          [range] = get_req_header(conn, "range")
          send_resp(conn, 200, range)
        end
      )

    assert Req.get!(req, range: "bytes=0-10").body == "bytes=0-10"
    assert Req.get!(req, range: 0..20).body == "bytes=0-20"
  end

  describe "compress_body" do
    @tag :transport
    test "request" do
      %{req: req} =
        serve_sequence(
          "POST /": fn conn ->
            assert get_req_header(conn, "content-encoding") == []
            assert {:ok, body, conn} = read_body(conn)
            assert Jason.decode!(body) == %{"a" => 1}
            send_resp(conn, 200, "")
          end,
          "POST /": fn conn ->
            assert get_req_header(conn, "content-encoding") == ["gzip"]
            assert {:ok, body, conn} = read_body(conn)
            assert body |> :zlib.gunzip() |> Jason.decode!() == %{"a" => 1}
            send_resp(conn, 200, "")
          end
        )

      Req.post!(req, json: %{a: 1})
      Req.post!(req, json: %{a: 1}, compress_body: true)
    end

    @tag :transport
    test "does not compress already encoded body" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert get_req_header(conn, "content-encoding") == ["br"]
            assert {:ok, "foo", conn} = read_body(conn)
            send_resp(conn, 200, "")
          end
        )

      Req.post!(req, body: "foo", compress_body: true, headers: [content_encoding: "br"])
    end

    test "stream" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert {:ok, body, conn} = read_body(conn)

            # run_plug decompresses the request body and strips content-encoding
            body =
              case get_req_header(conn, "content-encoding") do
                ["gzip"] ->
                  :zlib.gunzip(body)

                [] ->
                  body
              end

            send_resp(conn, 200, body)
          end
        )

      assert Req.post!(req, body: Stream.take(~w[foo foo foo], 2), compress_body: true).body ==
               "foofoo"
    end

    test "req_body_fun" do
      req_body_fun = fn
        %Req.Request{private: %{phase: :done}} = request ->
          {:done, request}

        %Req.Request{} = request ->
          request = Req.Request.put_private(request, :phase, :done)
          {:data, "foo", request}
      end

      %{req: req} = serve("POST /": &send_resp(&1, 200, ""))

      assert_raise ArgumentError,
                   "compress_body does not support req_body_fun",
                   fn ->
                     Req.post!(req, body: req_body_fun, compress_body: true)
                   end
    end

    test "nil body" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert get_req_header(conn, "content-encoding") == []
            send_resp(conn, 200, "ok")
          end
        )

      assert Req.get!(req, compress_body: true).body == "ok"
    end
  end

  describe "checksum" do
    @foo_md5 "md5:acbd18db4cc2f85cedef654fccc4a4d8"
    @foo_sha1 "sha1:0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33"
    @foo_sha256 "sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"

    test "into: binary" do
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "foo"))

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
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "foo"))

      req =
        req
        |> Req.merge(
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
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "foo"))

      req = Req.merge(req, into: [])

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
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "foo"))

      req = Req.merge(req, into: :self)

      assert_raise ArgumentError, ":checksum cannot be used with `into: :self`", fn ->
        Req.get!(req, checksum: @foo_sha1)
      end
    end
  end

  describe "http_digest" do
    test "md5 challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890"|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~ ~r/response="402359218de50d24c1c39d8c3c41a0c4"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end

    test "sha-256 challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890", algorithm=SHA-256|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~
                      ~r/response="79fbcaf8e746ff152ab381f928ee1f5875ef3dab475937cd7a6f2a34c0941021\"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end

    test "no challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            send_resp(conn, 401, "Unauthorized")
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 401
    end

    @tag :capture_log
    test "unsupported digest algorithm" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s|Digest realm="test", nonce="1234567890", algorithm=UNSUPPORTED|
            )
            |> send_resp(401, "Unauthorized")
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 401

      assert Req.Response.get_header(resp, "www-authenticate") == [
               ~s|Digest realm="test", nonce="1234567890", algorithm=UNSUPPORTED|
             ]
    end

    test "unauthorized after challenge" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header(
              "www-authenticate",
              ~s|Digest realm="test", nonce="1234567890", algorithm=MD5|
            )
            |> send_resp(401, "Unauthorized")
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 401
    end

    test "quoted values and paths" do
      %{req: req, url: url} =
        serve(
          "GET /some/path": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test \\"realm\\"", nonce="1234567890"|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo \\"bar\\""/ and
                    authorization =~ ~r/realm="test \\"realm\\""/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/some\/path"/ and
                    authorization =~ ~r/response="872e1593ea4d45f4d0a099614a6b9632\"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, url: "#{url}/some/path", auth: {:digest, "foo \"bar\":bar"})
      assert resp.status == 200
    end

    test "with qop" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890", qop="auth"|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                # Calculate expected response using cnonce
                cnonce = ~r/cnonce="([a-f0-9]+)"/ |> Regex.run(authorization) |> Enum.at(1)

                ha1 = :crypto.hash(:md5, "foo:test:bar") |> Base.encode16(case: :lower)
                ha2 = :crypto.hash(:md5, "GET:/") |> Base.encode16(case: :lower)

                expected_response =
                  :crypto.hash(
                    :md5,
                    # Response is calculated by hash_func(ha1:nonce:nc:cnonce:qop:ha2)
                    "#{ha1}:1234567890:00000001:#{cnonce}:auth:#{ha2}"
                  )
                  |> Base.encode16(case: :lower)

                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~ ~r/response="#{expected_response}"/ and
                    authorization =~ ~r/qop=auth/ and
                    authorization =~ ~r/nc=00000001/ and
                    authorization =~ ~r/cnonce="#{cnonce}"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end

    test "with session" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            case get_req_header(conn, "authorization") do
              [] ->
                conn
                |> put_resp_header(
                  "www-authenticate",
                  ~s|Digest realm="test", nonce="1234567890", algorithm=MD5-SESS|
                )
                |> send_resp(401, "Unauthorized")

              [authorization | _] ->
                # Calculate expected response using cnonce
                cnonce = ~r/cnonce="([a-f0-9]+)"/ |> Regex.run(authorization) |> Enum.at(1)
                ha1 = :crypto.hash(:md5, "foo:test:bar") |> Base.encode16(case: :lower)

                ha1 =
                  :crypto.hash(:md5, "#{ha1}:1234567890:#{cnonce}") |> Base.encode16(case: :lower)

                ha2 = :crypto.hash(:md5, "GET:/") |> Base.encode16(case: :lower)

                expected_response =
                  :crypto.hash(
                    :md5,
                    "#{ha1}:1234567890:#{ha2}"
                  )
                  |> Base.encode16(case: :lower)

                has_expected_header? =
                  String.starts_with?(authorization, "Digest ") and
                    authorization =~ ~r/username="foo"/ and
                    authorization =~ ~r/realm="test"/ and
                    authorization =~ ~r/nonce="1234567890"/ and
                    authorization =~ ~r/uri="\/"/ and
                    authorization =~ ~r/response="#{expected_response}"/ and
                    authorization =~ ~r/cnonce="#{cnonce}"/

                if has_expected_header? do
                  send_resp(conn, 200, "OK")
                else
                  send_resp(conn, 401, "Unauthorized")
                end
            end
          end
        )

      resp = Req.get!(req, auth: {:digest, "foo:bar"})
      assert resp.status == 200
    end
  end

  describe "put_aws_sigv4" do
    def reflect_sigv4_options(opts), do: opts

    test "body: binary" do
      plug = fn conn ->
        assert {:ok, "hello", conn} = read_body(conn)
        assert ["AWS4-HMAC-SHA256" <> _] = get_req_header(conn, "authorization")
        assert [<<_::binary-size(64)>>] = get_req_header(conn, "x-amz-content-sha256")
        send_resp(conn, 200, "ok")
      end

      req =
        Req.new(
          url: "https://s3.amazonaws.com",
          # Test mfa tuple
          aws_sigv4:
            {__MODULE__, :reflect_sigv4_options,
             [[access_key_id: "foo", secret_access_key: "bar"]]},
          body: "hello",
          plug: plug
        )

      assert Req.put!(req).body == "ok"
    end

    test "body: enumerable" do
      plug = fn conn ->
        assert {:ok, "hello", conn} = read_body(conn)
        assert ["AWS4-HMAC-SHA256" <> _] = get_req_header(conn, "authorization")
        assert ["UNSIGNED-PAYLOAD"] = get_req_header(conn, "x-amz-content-sha256")
        send_resp(conn, 200, "ok")
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

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "excludes accept-encoding, hop-by-hop, and trace-id headers from signature" do
      plug = fn conn ->
        [authorization] = get_req_header(conn, "authorization")

        signed_headers =
          authorization
          |> String.split(",")
          |> Enum.find_value(fn part ->
            case String.split(part, "=", parts: 2) do
              ["SignedHeaders", value] -> String.split(value, ";")
              _ -> nil
            end
          end)

        for excluded <- [
              "accept-encoding",
              "x-amzn-trace-id",
              "connection",
              "keep-alive",
              "proxy-authenticate",
              "proxy-authorization",
              "te",
              "trailer",
              "transfer-encoding",
              "upgrade"
            ] do
          refute excluded in signed_headers,
                 "expected #{excluded} not in SignedHeaders, got: #{inspect(signed_headers)}"
        end

        # Headers excluded from the signature are still sent on the wire.
        assert ["zstd, br, gzip"] = get_req_header(conn, "accept-encoding")
        assert ["trace-123"] = get_req_header(conn, "x-amzn-trace-id")
        assert ["keep-alive"] = get_req_header(conn, "connection")

        # Non-excluded custom headers are still signed.
        assert "x-custom" in signed_headers

        send_resp(conn, 200, "ok")
      end

      req =
        Req.new(
          url: "https://s3.amazonaws.com",
          compressed: true,
          aws_sigv4: [access_key_id: "foo", secret_access_key: "bar"],
          headers: [
            "x-amzn-trace-id": "trace-123",
            connection: "keep-alive",
            "keep-alive": "timeout=5",
            "proxy-authenticate": "Basic",
            "proxy-authorization": "Basic foo",
            te: "trailers",
            trailer: "Expires",
            "transfer-encoding": "chunked",
            upgrade: "websocket",
            "x-custom": "signed"
          ],
          body: "hello",
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
    test "is disabled by default" do
      %{req: req} = serve("GET /": &send_resp_gzip(&1, "foo"))

      resp = Req.get!(req)
      assert Req.Response.get_header(resp, "content-encoding") == ["gzip"]
      assert resp.body == :zlib.gzip("foo")
    end

    test "gzip success" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_header("content-encoding", "x-gzip")
            |> send_resp_gzip("foo")
          end
        )

      resp = Req.get!(req, compressed: true)
      assert Req.Response.get_header(resp, "content-encoding") == []
      assert resp.body == "foo"
    end

    test "gzip error" do
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

    test "brotli success" do
      %{req: req} =
        serve("GET /": &send_resp_br(&1, "foo"))

      resp = Req.get!(req, compressed: true)
      assert resp.body == "foo"
    end

    test "brotli error" do
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
    @tag skip: System.otp_release() < "28"
    test "zstd success" do
      %{req: req} =
        serve("GET /": &send_resp_zstd(&1, "foo"))

      resp = Req.get!(req, compressed: true)
      assert resp.body == "foo"
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "zstd error" do
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

  describe "decode_body" do
    test "multiple types" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> prepend_resp_headers([
              {"content-type", "text/plain"},
              {"content-type", "text/plain; charset=utf-8"}
            ])
            |> send_resp(200, "ok")
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
            |> put_resp_header(
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
            |> put_resp_content_type("application/json")
            |> send_resp(200, "bad")
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
            |> put_resp_content_type("text/calendar")
            |> send_resp(200, "raw-ics")
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
            |> put_resp_content_type("application/epub+zip", nil)
            |> send_resp(200, zip)
          end
        )

      assert Req.get!(req, decoders: [epub: Req.ZIP]).body == files
    end

    test "custom decoder error" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_content_type("text/calendar")
            |> send_resp(200, "raw-ics")
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
            |> put_resp_content_type("text/calendar")
            |> send_resp(200, ~s|{"a":1}|)
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
            |> put_resp_content_type("application/octet-stream", nil)
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
            |> put_resp_content_type("application/octet-stream")
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
            send_resp(conn, 200, create_tar(files))
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
            |> put_resp_content_type("application/octet-stream", nil)
            |> send_resp(200, create_tar(files, compressed: true))
          end
        )

      assert Req.get!(req, url: "#{url}/foo.tar.gz", decoders: [:tgz]).body == files
    end

    test "tar invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_content_type("application/x-tar", nil)
            |> send_resp(200, "invalid")
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
            |> put_resp_content_type("application/octet-stream", nil)
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
            |> put_resp_content_type("application/zip", nil)
            |> send_resp(200, "invalid")
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
            |> put_resp_content_type("application/x-gzip", nil)
            |> send_resp(200, :zlib.gzip("foo"))
          end
        )

      assert Req.get!(req, decoders: [:gz]).body == "foo"
    end

    test "gzip invalid" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_content_type("application/x-gzip", nil)
            |> send_resp(200, "bad")
          end
        )

      assert_raise ErlangError, "Erlang error: :data_error", fn ->
        Req.get(req, decoders: [:gz])
      end
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "zstd (content-type)" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            conn
            |> put_resp_content_type("application/zstd", nil)
            |> send_resp(200, :zstd.compress("foo"))
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
            |> put_resp_content_type("application/octet-stream", nil)
            |> send_resp(200, :zstd.compress("foo"))
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
            |> put_resp_content_type("application/zstd", nil)
            |> send_resp(200, "bad")
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
          |> put_resp_header("content-encoding", "x-gzip")
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)
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
          |> put_resp_header("content-encoding", "x-gzip")
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)
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
          |> put_resp_header("content-encoding", "deflate")
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)
        end
      )

    {resp, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Req.get!(req, compressed: true)
      end)

    assert resp.body |> :zlib.uncompress() |> Jason.decode!() == %{"a" => 1}
    assert log == ~s|[debug] algorithm "deflate" is not supported\n|
  end

  describe "redirect" do
    test "ignore when :redirect is false" do
      %{req: req, url: url} =
        serve("GET /redirect": &send_redirect(&1, 302, "/ok"))

      assert Req.get!(req, url: "#{url}/redirect", redirect: false).status == 302
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
               assert Req.get!(req, url: "#{url}/redirect", retry: false).status == 200
             end) == "[debug] redirecting to #{url}/ok\n"
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
               assert Req.get!(req, url: "#{url}/redirect").status == 200
             end) == "[debug] redirecting to /ok\n"

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
             end) == "[debug] redirecting to /ok\n"
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
             end) == "[debug] redirecting to /ok\n"

      assert ExUnit.CaptureLog.capture_log(fn ->
               response = Req.get!(req, url: "#{url}/redirect?a=1")
               assert response.status == 200
               assert response.body == "a=1"
             end) == "[debug] redirecting to /ok?a=1\n"
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
                 assert Req.post!(req, url: "#{url}/redirect", body: "body").status == 200
               end) == "[debug] redirecting to #{url}/ok\n"
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

      assert Req.post!(req, url: "#{url}/redirect", json: %{a: 1}).status == 200
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
                 assert Req.post!(req, url: "#{url}/redirect", body: "body").status == 200
               end) == "[debug] redirecting to #{url}/ok\n"
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
                 assert Req.head!(req, url: "#{url}/redirect").status == 200
               end) == "[debug] redirecting to #{url}/ok\n"
      end
    end

    test "without location" do
      %{req: req, url: url} =
        serve(
          "POST /redirect": fn conn ->
            send_resp(conn, 303, "")
          end
        )

      assert Req.post!(req, url: "#{url}/redirect").status == 303
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
               assert Req.get!(req, url: "#{url}/redirect", auth: {:basic, "foo:bar"}).status ==
                        200
             end) == "[debug] redirecting to #{url}/auth\n"
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
               assert Req.get!(req,
                        auth: {:basic, "authorization:credentials"},
                        redirect_trusted: true
                      ).status == 200
             end) == "[debug] redirecting to http://127.0.0.1:#{url.port}/ok\n"
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
               assert Req.get!(req, auth: {:basic, "foo:bar"}).status == 200
             end) == "[debug] redirecting to http://127.0.0.1:#{url.port}/ok\n"
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
               assert Req.get!(req, auth: {:basic, "foo:bar"}).status == 200
             end) == "[debug] redirecting to #{untrusted_url}/ok\n"
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
               assert Req.get!(req, auth: {:basic, "authorization:credentials"}).status == 200
             end) == "[debug] redirecting to #{untrusted_url}/ok\n"
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
          assert Req.get!(req).status == 200
        end)

      assert log == """
             [warning] stripping userinfo from redirect location
             [debug] redirecting to http://127.0.0.1:#{url.port}/path
             """
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
               assert Req.get!(req, url: "#{url}/redirect", params: [a: 1]).status == 200
             end) == "[debug] redirecting to #{url}/ok\n"
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
               assert Req.get!(req, url: "#{url}/redirect").status == 200
             end) == "[debug] redirecting to /ok\n"
    end

    test "redirect_log_level, set to :error" do
      %{req: req, url: url} =
        serve(
          "GET /redirect": &send_redirect(&1, 302, "/ok"),
          "GET /ok": &send_resp(&1, 200, "ok")
        )

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Req.get!(req, url: "#{url}/redirect", redirect_log_level: :error).status ==
                        200
             end) == "[error] redirecting to /ok\n"
    end

    test "redirect_log_level, disabled" do
      %{req: req, url: url} =
        serve(
          "GET /redirect": &send_redirect(&1, 302, "/ok"),
          "GET /ok": &send_resp(&1, 200, "ok")
        )

      assert Req.get!(req, url: "#{url}/redirect", redirect_log_level: false).status == 200
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
               assert Req.get!(req, url: "#{url}/redirect").status == 200
             end) == "[debug] redirecting to #{no_scheme}/ok\n"
    end
  end

  describe "expect" do
    test "status integer" do
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, expect: 200).body == "ok"
      assert {:error, e} = Req.get(req, expect: 201)
      assert Exception.message(e) =~ "expected status 201, got: 200"
    end

    test "status range" do
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, expect: 200..201).body == "ok"
      assert {:error, e} = Req.get(req, expect: 201..202)
      assert Exception.message(e) =~ "expected status 201..202, got: 200"
    end

    test "status list" do
      %{req: req} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, expect: [200, 201]).body == "ok"
      assert {:error, e} = Req.get(req, expect: [201, 202])
      assert Exception.message(e) =~ "expected status [201, 202], got: 200"

      assert Req.get!(req, expect: [200..201]).body == "ok"
      assert {:error, e} = Req.get(req, expect: [201..202])
      assert Exception.message(e) =~ "expected status [201..202], got: 200"
    end

    test "status category atom" do
      %{req: req, url: url} =
        serve(
          "GET /200": &send_resp(&1, 200, "ok"),
          "GET /301": &send_resp(&1, 301, "moved"),
          "GET /404": &send_resp(&1, 404, "not found"),
          "GET /500": &send_resp(&1, 500, "error")
        )

      assert Req.get!(req, url: "#{url}/200", expect: :successful).body == "ok"
      assert {:error, e} = Req.get(req, url: "#{url}/404", expect: :successful)
      assert Exception.message(e) =~ "expected status :successful, got: 404"

      assert Req.get!(req, url: "#{url}/301", expect: :redirection).body == "moved"
      assert {:error, e} = Req.get(req, url: "#{url}/200", expect: :redirection)
      assert Exception.message(e) =~ "expected status :redirection, got: 200"

      assert Req.get!(req, url: "#{url}/404", expect: :client_error).body == "not found"

      assert Req.get!(req, url: "#{url}/500", expect: :server_error, retry: false).body == "error"
    end

    test "status category atom in list" do
      %{req: req} = serve("GET /": &send_resp(&1, 200, "ok"))

      assert Req.get!(req, expect: [:successful, :redirection]).body == "ok"
      assert {:error, _} = Req.get(req, expect: [:redirection, :client_error])
    end
  end

  ## Error steps

  describe "retry" do
    @tag :capture_log
    test "eventually successful - function" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 200, "ok")
        )

      request =
        Req.merge(req, retry_delay: &Integer.pow(2, &1))
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

      assert log == """
             [warning] retry: got response with status 500, will retry in 1ms, 3 attempts left
             [warning] retry: got response with status 500, will retry in 2ms, 2 attempts left
             [warning] retry: got response with status 500, will retry in 4ms, 1 attempt left
             """
    end

    test "invalid :retry_delay" do
      %{req: req} =
        serve(
          "GET /": fn conn ->
            send_resp(conn, 500, "")
          end
        )

      req = Req.merge(req, retry_delay: fn _ -> :ok end)

      assert_raise ArgumentError,
                   "expected :retry_delay function to return non-negative integer, got: :ok",
                   fn ->
                     Req.request!(req)
                   end
    end

    @tag :capture_log
    test "eventually successful - integer" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 200, "ok")
        )

      request =
        Req.merge(req, retry_delay: 1)
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

      assert log == """
             [warning] retry: got response with status 500, will retry in 1ms, 3 attempts left
             [warning] retry: got response with status 500, will retry in 1ms, 2 attempts left
             """
    end

    @tag :capture_log
    test "default log_level" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 200, "ok")
        )

      request = Req.merge(req, retry_delay: 1)
      log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)

      assert log ==
               "[warning] retry: got response with status 500, will retry in 1ms, 3 attempts left\n"
    end

    @tag :capture_log
    test "custom log_level" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 200, "ok")
        )

      request = Req.merge(req, retry_delay: 1, retry_log_level: :info)

      log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)

      assert log ==
               "[info] retry: got response with status 500, will retry in 1ms, 3 attempts left\n"
    end

    @tag :capture_log
    test "logging disabled" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 200, "ok")
        )

      request = Req.merge(req, retry_delay: 1, retry_log_level: false)

      log = ExUnit.CaptureLog.capture_log(fn -> Req.get!(request) end)
      assert log == ""
    end

    @tag :capture_log
    test "retries response with malformed compressed body" do
      %{req: req} =
        serve_sequence(
          "GET /": fn conn ->
            conn
            |> put_resp_header("content-encoding", "gzip")
            |> send_resp(500, "bad gzip")
          end,
          "GET /": &send_resp(&1, 200, "ok")
        )

      response = Req.get!(req, compressed: true, retry_delay: 1)
      assert response.status == 200
      assert response.body == "ok"
    end

    @tag :capture_log
    test "retry-after" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp_retry_after(&1, 0),
          "GET /":
            &send_resp_retry_after(%{&1 | status: 503}, DateTime.add(DateTime.utc_now(), 2)),
          "GET /": &send_resp(&1, 200, "ok")
        )

      assert Req.request!(req, max_retries: 5).body == "ok"
    end

    @tag :capture_log
    test ":retry_delay" do
      pid = self()

      %{req: req} =
        serve_sequence(
          "GET /": &send_resp_retry_after(&1, 0),
          "GET /": &send_resp_retry_after(&1, -1),
          "GET /": &send_resp_retry_after(%{&1 | status: 503}, DateTime.utc_now()),
          "GET /":
            &send_resp_retry_after(%{&1 | status: 503}, DateTime.add(DateTime.utc_now(), -3600)),
          "GET /": &send_resp(&1, 200, "ok")
        )

      retry_delay = fn retry_count ->
        send(pid, {:retry_delay, retry_count})
        0
      end

      assert Req.request!(req, retry_delay: retry_delay, max_retries: 5).body == "ok"
      assert_received {:retry_delay, 0}
      assert_received {:retry_delay, 1}
      assert_received {:retry_delay, 2}
      assert_received {:retry_delay, 3}
    end

    @tag :capture_log
    test "always failing" do
      pid = self()

      %{req: request} =
        serve(
          "GET /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request =
        request
        |> Req.merge(retry_delay: 1)
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
    test "retry: :safe_transient does not retry on POST" do
      pid = self()

      %{req: request} =
        serve(
          "POST /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request = Req.merge(request, retry: :safe_transient, max_retries: 10)

      assert Req.post!(request).status == 500
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "retry: :transient retries on POST" do
      pid = self()

      %{req: request} =
        serve(
          "POST /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request = Req.merge(request, retry: :transient, retry_delay: 1, max_retries: 1)

      assert Req.post!(request).status == 500
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    test "retry: false" do
      pid = self()

      %{req: request} =
        serve(
          "GET /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request = Req.merge(request, retry: false)

      assert Req.get!(request).status == 500
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "custom function returning true" do
      pid = self()

      fun = fn _request, response ->
        assert response.status == 500
        true
      end

      %{req: request} =
        serve(
          "POST /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request = Req.merge(request, retry: fun, retry_delay: 1)

      assert Req.post!(request).status == 500
      assert_received :ping
      assert_received :ping
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "custom function returning {:delay, milliseconds}" do
      pid = self()

      fun = fn _request, response ->
        assert response.status == 500
        {:delay, 1}
      end

      %{req: request} =
        serve(
          "GET /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request = Req.merge(request, retry: fun)

      assert Req.get!(request).status == 500
      assert_received :ping
      assert_received :ping
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "raise on custom function returning {:delay, milliseconds} when `:retry_delay` is provided" do
      pid = self()

      fun = fn _request, response ->
        assert response.status == 500
        {:delay, 1}
      end

      %{req: request} =
        serve(
          "GET /": fn conn ->
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      request = Req.merge(request, retry: fun, retry_delay: 1)

      assert_raise ArgumentError,
                   "expected :retry_delay not to be set when the :retry function is returning `{:delay, milliseconds}`",
                   fn -> Req.get!(request) end
    end

    @tag :capture_log
    test "does not re-encode params" do
      pid = self()

      %{req: req} =
        serve(
          "GET /": fn conn ->
            assert conn.query_string == "a=1&b=2"
            send(pid, :ping)
            send_resp(conn, 500, "oops")
          end
        )

      assert Req.get!(req, params: [a: 1, b: 2], retry_delay: 1).status == 500
      assert_received :ping
      assert_received :ping
      assert_received :ping
      assert_received :ping
      refute_received _
    end

    @tag :capture_log
    test "re-runs request steps on each attempt" do
      pid = self()

      %{req: req} =
        serve("GET /": &send_resp(&1, 500, "oops"))

      req =
        Req.Request.append_request_steps(req,
          count: fn request ->
            send(pid, :step_ran)
            request
          end
        )

      assert Req.get!(req, retry_delay: 1, max_retries: 3).status == 500

      # 1 initial attempt + 3 retries
      assert_received :step_ran
      assert_received :step_ran
      assert_received :step_ran
      assert_received :step_ran
      refute_received _
    end

    @tag :capture_log
    test "does not carry `halted` status over" do
      %{req: req} =
        serve_sequence(
          "GET /": &send_resp(&1, 500, "oops"),
          "GET /": &send_resp(&1, 200, "ok")
        )

      response_step = fn
        {request, %Req.Response{} = response} ->
          response = Req.Response.put_private(response, :ran_response_step, true)
          {request, response}

        {request, response} ->
          {request, response}
      end

      response =
        Req.merge(req, retry_delay: 1)
        |> Req.Request.append_response_steps(response_step: response_step)
        |> Req.request!()

      assert %{ran_response_step: true} = response.private
    end
  end

  @tag :tmp_dir
  test "cache", c do
    pid = self()

    %{req: request} =
      serve(
        "GET /": fn conn ->
          case get_req_header(conn, "if-modified-since") do
            [] ->
              send(pid, :cache_miss)

              conn
              |> put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
              |> send_resp(200, "ok")

            _ ->
              send(pid, :cache_hit)

              conn
              |> put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
              |> send_resp(304, "")
          end
        end
      )

    request = Req.merge(request, cache: true, cache_dir: c.tmp_dir)

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

    %{req: request} =
      serve_sequence(
        "GET /": fn conn ->
          send(pid, :cache_miss)

          conn
          |> put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
          |> Req.Test.json(%{a: 1})
        end,
        "GET /": fn conn ->
          send(pid, :cache_hit)
          send_resp(conn, 500, "")
        end,
        "GET /": fn conn ->
          send(pid, :cache_hit)
          send_resp(conn, 500, "")
        end,
        "GET /": fn conn ->
          send(pid, :cache_hit)

          conn
          |> put_resp_header("last-modified", "Wed, 21 Oct 2015 07:28:00 GMT")
          |> send_resp(304, "")
        end
      )

    request = Req.merge(request, retry_delay: 10, cache: true, cache_dir: c.tmp_dir)

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
        {:ok, body, conn} = read_body(conn)
        assert body == ~s|{"a":1}|
        assert conn.query_params == %{"foo" => <<0xFF>>}
        send_resp(conn, 200, "ok")
      end

      assert Req.request!(plug: plug, json: %{a: 1}, params: %{foo: <<0xFF>>}).body == "ok"
      refute_receive _
    end

    test "request stream" do
      req =
        Req.new(
          plug: fn conn ->
            {:ok, body, conn} = read_body(conn)
            send_resp(conn, 200, body)
          end,
          body: Stream.take(~w[foo foo foo], 2)
        )

      assert Req.request!(req).body == "foofoo"
      refute_receive _
    end

    test "request body fun" do
      req =
        Req.new(
          plug: fn conn ->
            {:ok, body, conn} = read_body(conn)
            send_resp(conn, 200, body)
          end,
          body: fn
            %Req.Request{private: %{done: true}} = request ->
              {:done, request}

            %Req.Request{private: %{count: count}} = request ->
              request = Req.Request.put_private(request, :count, count + 1)
              request = Req.Request.put_private(request, :done, count + 1 >= 3)
              {:data, "chunk#{count}", request}

            %Req.Request{} = request ->
              request = Req.Request.put_private(request, :count, 1)
              {:data, "chunk0", request}
          end
        )

      {req, resp} = Req.run!(req)
      assert resp.body == "chunk0chunk1chunk2"
      assert req.private.count == 3
      refute_receive _
    end

    test "fetches query params" do
      plug = fn conn ->
        assert conn.query_params == %{"a" => "1"}
        send_resp(conn, 200, "ok")
      end

      assert Req.request!(plug: plug, params: [a: 1]).body == "ok"
    end

    test "fetches request body" do
      plug = fn conn ->
        assert conn.body_params == %{"a" => 1}
        assert Req.Test.raw_body(conn) == "{\"a\":1}"
        send_resp(conn, 200, "ok")
      end

      assert Req.post!(plug: plug, json: %{a: 1}).body == "ok"
    end

    test "into: fun" do
      req =
        Req.new(
          plug: fn conn ->
            conn = send_chunked(conn, 200)
            {:ok, conn} = chunk(conn, "foo")
            {:ok, conn} = chunk(conn, "bar")
            {:ok, conn} = chunk(conn, "baz")
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
            conn = send_chunked(conn, 200)
            {:ok, conn} = chunk(conn, "foo")
            {:ok, conn} = chunk(conn, "bar")
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
            send_resp(conn, 200, "foo")
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
            send_file(conn, 200, "mix.exs")
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
            conn = send_chunked(conn, 200)
            {:ok, conn} = chunk(conn, "foo")
            {:ok, conn} = chunk(conn, "bar")
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
            send_resp(conn, 200, "foo")
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
            send_file(conn, 200, "mix.exs")
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
            conn = send_chunked(conn, 404)
            {:ok, conn} = chunk(conn, "foo")
            {:ok, conn} = chunk(conn, "bar")
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
            conn = send_chunked(conn, 200)
            {:ok, conn} = chunk(conn, "foo")
            {:ok, conn} = chunk(conn, "bar")
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

    test "compressed request body" do
      plug = fn conn ->
        assert get_req_header(conn, "content-encoding") == []
        {:ok, ~s|{"test":"data"}|, conn} = read_body(conn)
        Req.Test.json(conn, %{success: true})
      end

      resp = Req.post!(plug: plug, json: %{test: "data"}, compress_body: true)
      assert resp.body == %{"success" => true}
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
end
