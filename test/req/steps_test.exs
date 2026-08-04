defmodule Req.StepsTest do
  use Req.Case, async: true

  describe "put_base_url" do
    test "it works" do
      %{req: req, url: url} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      resp = Req.get!(req, base_url: url, url: "/")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: url, url: "")
      assert resp.status == 200
      assert resp.body == "ok"

      req = Req.merge(req, base_url: url)
      resp = Req.get!(req, url: "/")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, url: "")
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "with absolute url" do
      %{req: req, url: url} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      resp = Req.get!(req, base_url: "ignored", url: url)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "with base path" do
      %{req: req, url: url} =
        serve("GET /api/v2/foo": &send_resp(&1, 200, "ok"))

      resp = Req.get!(req, base_url: "#{url}/api/v2", url: "/foo", retry: false)
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: "#{url}/api/v2", url: "foo")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: "#{url}/api/v2/", url: "/foo")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: "#{url}/api/v2/", url: "foo")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: "#{url}/api/v2/foo", url: "")
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "function" do
      %{req: req, url: url} =
        serve_sequence(
          "GET /api/v1": &send_resp(&1, 200, "ok"),
          "GET /api/v1/foo": &send_resp(&1, 200, "ok"),
          "GET /api/v1": &send_resp(&1, 200, "ok"),
          "GET /api/v1": &send_resp(&1, 200, "ok")
        )

      resp = Req.get!(req, base_url: fn -> "#{url}/api/v1" end, url: "")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: fn -> "#{url}/api/v1" end, url: "foo")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: fn -> URI.new!("#{url}/api/v1") end, url: "")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.get!(req, base_url: {URI, :new!, ["#{url}/api/v1"]}, url: "")
      assert resp.status == 200
      assert resp.body == "ok"
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

      resp = Req.post!(req, body: "foo")
      assert resp.status == 200
      assert resp.body == "foo"
    end

    test "body stream" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            {:ok, body, conn} = read_body(conn)
            send_resp(conn, 200, body)
          end
        )

      resp = Req.post!(req, body: Stream.take(~w[foo foo foo], 2))
      assert resp.status == 200
      assert resp.body == "foofoo"
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

      resp =
        Req.post!(req,
          form_multipart: [
            a: 1,
            b: File.stream!("#{tmp_dir}/b.txt"),
            c: {File.stream!("#{tmp_dir}/c"), filename: "ccc"}
          ]
        )

      assert resp.status == 200
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

      resp =
        Req.post!(req,
          form_multipart: [
            a: 1,
            b:
              {Stream.cycle(["a", "b", "c"]) |> Stream.take(6),
               filename: "cycle", content_type: "application/text"}
          ]
        )

      assert resp.status == 200
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

      resp = Req.post!(req, form_multipart: [a: 1], retry: :transient, retry_delay: 1)
      assert resp.status == 200
    end

    test "GET to POST" do
      %{req: req} =
        serve(
          "GET /": &send_resp(&1, 200, &1.method),
          "POST /": &send_resp(&1, 200, &1.method),
          "PUT /": &send_resp(&1, 200, &1.method)
        )

      resp = Req.request!(req)
      assert resp.status == 200
      assert resp.body == "GET"
      resp = Req.request!(req, body: "")
      assert resp.status == 200
      assert resp.body == "POST"
      resp = Req.request!(req, body: "foo")
      assert resp.status == 200
      assert resp.body == "POST"
      resp = Req.request!(req, json: %{a: 1})
      assert resp.status == 200
      assert resp.body == "POST"
      resp = Req.request!(req, json: %{a: 1}, method: :put)
      assert resp.status == 200
      assert resp.body == "PUT"
    end
  end

  test "put_params" do
    %{req: req, url: url} =
      serve(
        "GET /": fn conn ->
          send_resp(conn, 200, conn.query_string)
        end
      )

    resp = Req.get!(req, params: [x: 1, y: 2])
    assert resp.status == 200
    assert resp.body == "x=1&y=2"
    resp = Req.get!(req, params: [x: 1, x: 2])
    assert resp.status == 200
    assert resp.body == "x=2"
    resp = Req.get!(req, url: "#{url}?x=1", params: [x: 9, y: 2])
    assert resp.status == 200
    assert resp.body == "x=9&y=2"
    resp = Req.get!(req, url: "#{url}?x=1&x=2&y=1", params: [x: 9])
    assert resp.status == 200
    assert resp.body == "x=9&x=2&y=1"
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

    resp = Req.get!(req, url: "#{url}/:id/ola", path_params: [id: "abc|def"])
    assert resp.status == 200
    assert resp.body == "/abc%7Cdef/ola"

    # With :curly style.

    resp =
      Req.get!(req,
        url: "#{url}/{id}:bar",
        path_params: [id: "abc|def"],
        path_params_style: :curly
      )

    assert resp.status == 200
    assert resp.body == "/abc%7Cdef:bar"
  end

  @tag skip: Req.Case.adapter() in [:httpc, :plug]
  test "put_path_params does not expand curly segments in :colon style" do
    %{req: req, url: url} = serve("GET /": &send_resp(&1, 200, ""))

    {:error, err} =
      Req.request(req, url: "#{url}/:id{ola}", path_params: [id: "abc"], retry: false)

    assert err == %Req.HTTPError{protocol: :http1, reason: {:invalid_request_target, "/abc{ola}"}}
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

    resp = Req.get!(req, url: "#{url}/:id/ola", path_params: [id: "abc#def"])
    assert resp.status == 200
    assert resp.body == "/abc%23def/ola"

    # With :curly style.

    resp =
      Req.get!(req,
        url: "#{url}/{id}:bar",
        path_params: [id: "abc#def"],
        path_params_style: :curly
      )

    assert resp.status == 200
    assert resp.body == "/abc%23def:bar"
  end

  test "put_range" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          [range] = get_req_header(conn, "range")
          send_resp(conn, 200, range)
        end
      )

    resp = Req.get!(req, range: "bytes=0-10")
    assert resp.status == 200
    assert resp.body == "bytes=0-10"
    resp = Req.get!(req, range: 0..20)
    assert resp.status == 200
    assert resp.body == "bytes=0-20"
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

            # Req.Plug decompresses the request body and strips content-encoding
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

      resp = Req.post!(req, body: Stream.take(~w[foo foo foo], 2), compress_body: true)
      assert resp.status == 200
      assert resp.body == "foofoo"
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

      resp = Req.get!(req, compress_body: true)
      assert resp.status == 200
      assert resp.body == "ok"
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

      resp = Req.put!(req)
      assert resp.status == 200
      assert resp.body == "ok"
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

      resp = Req.put!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    # TODO: Remove when requiring OTP 28 (Elixir 1.21/22?)
    @tag skip: System.otp_release() < "28"
    test "excludes accept-encoding, hop-by-hop, and other unsignable headers from signature" do
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
              "expect",
              "user-agent",
              "from",
              "max-forwards",
              "pragma",
              "referer",
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
        assert ["req/" <> _] = get_req_header(conn, "user-agent")

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
            expect: "100-continue",
            from: "user@example.com",
            "max-forwards": "10",
            pragma: "no-cache",
            referer: "https://example.com",
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

      resp = Req.put!(req)
      assert resp.status == 200
      assert resp.body == "ok"
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

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             response = Req.get!(request)
             assert response.status == 200
             assert response.body == "ok"
           end) =~ "`cache: true`/cache step are deprecated and will be removed in Req v0.8"

    assert_received :cache_miss

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      response = Req.Request.run!(request)
      assert response.status == 200
      assert response.body == "ok"
    end)

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

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      response = Req.get!(request)
      assert response.status == 200
      assert response.body == %{"a" => 1}
    end)

    assert_received :cache_miss

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      response = Req.Request.run!(request)
      assert response.status == 200
      assert response.body == %{"a" => 1}
    end)

    assert_received :cache_hit
    assert_received :cache_hit
    assert_received :cache_hit
    refute_received _
  end
end
