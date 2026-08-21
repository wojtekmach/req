defmodule Req.StepsTest do
  use Req.Case, async: true

  describe "put_base_url" do
    test "it works" do
      %{req: req, url: url} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      resp = Req.stream!(req, base_url: url, url: "/")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.stream!(req, base_url: url, url: "")
      assert resp.status == 200
      assert resp.body == "ok"

      req = Req.merge(req, base_url: url)
      resp = Req.stream!(req, url: "/")
      assert resp.status == 200
      assert resp.body == "ok"
      resp = Req.stream!(req, url: "")
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "with absolute url" do
      %{req: req, url: url} =
        serve("GET /": &send_resp(&1, 200, "ok"))

      resp = Req.stream!(req, base_url: "ignored", url: url)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "with base path" do
      %{req: req, url: url} =
        serve("GET /api/v2/foo": &send_resp(&1, 200, "ok"))

      resp = Req.stream!(req, base_url: "#{url}/api/v2", url: "/foo", retry: false)
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: "#{url}/api/v2", url: "foo")
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: "#{url}/api/v2/", url: "/foo")
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: "#{url}/api/v2/", url: "foo")
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: "#{url}/api/v2/foo", url: "")
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

      resp = Req.stream!(req, base_url: fn -> "#{url}/api/v1" end, url: "")
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: fn -> "#{url}/api/v1" end, url: "foo")
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: fn -> URI.new!("#{url}/api/v1") end, url: "")
      assert resp.status == 200
      assert resp.body == "ok"

      resp = Req.stream!(req, base_url: {URI, :new!, ["#{url}/api/v1"]}, url: "")
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

      resp = Req.stream!(req, method: :post, body: "foo")
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

      resp = Req.stream!(req, method: :post, body: Stream.take(~w[foo foo foo], 2))
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

      resp = Req.stream!(req, method: :post, json: %{a: 1})
      assert resp.status == 200
      assert resp.body == ""
    end

    test "form" do
      %{req: req} =
        serve(
          "POST /": fn conn ->
            assert {:ok, "a=1", conn} = read_body(conn)
            send_resp(conn, 200, "")
          end
        )

      resp = Req.stream!(req, method: :post, form: [a: 1])
      assert resp.status == 200
      assert resp.body == ""
      resp = Req.stream!(req, method: :post, form: %{a: 1})
      assert resp.status == 200
      assert resp.body == ""
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
        Req.stream!(req,
          method: :post,
          form_multipart: [
            a: 1,
            b: File.stream!("#{tmp_dir}/b.txt"),
            c: {File.stream!("#{tmp_dir}/c"), filename: "ccc"}
          ]
        )

      assert resp.status == 200
      assert resp.body == "ok"
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
        Req.stream!(req,
          method: :post,
          form_multipart: [
            a: 1,
            b:
              {Stream.cycle(["a", "b", "c"]) |> Stream.take(6),
               filename: "cycle", content_type: "application/text"}
          ]
        )

      assert resp.status == 200
      assert resp.body == "ok"
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

      resp =
        Req.stream!(req, method: :post, form_multipart: [a: 1], retry: :transient, retry_delay: 1)

      assert resp.status == 200
      assert resp.body == ""
    end
  end

  test "put_params" do
    %{req: req, url: url} =
      serve(
        "GET /": fn conn ->
          send_resp(conn, 200, conn.query_string)
        end
      )

    resp = Req.stream!(req, params: [x: 1, y: 2])
    assert resp.status == 200
    assert resp.body == "x=1&y=2"

    resp = Req.stream!(req, url: "#{url}?x=1", params: [x: 2, x: 3])
    assert resp.status == 200
    assert resp.body == "x=2&x=3"

    resp = Req.stream!(req, url: "#{url}?x=1&x=2&x=3", params: [x: 4, x: 5])
    assert resp.status == 200
    assert resp.body == "x=4&x=5&x=3"

    resp = Req.stream!(req, url: "#{url}?y=1&x=1", params: [x: 9, y: 2])
    assert resp.status == 200
    assert resp.body == "x=9&y=2"

    resp = Req.stream!(req, url: "#{url}?x=1&x=2&y=1", params: [x: 9])
    assert resp.status == 200
    assert resp.body == "x=9&x=2&y=1"
  end

  # TODO: support this?
  test "put_params with list value" do
    %{req: req} =
      serve("GET /": &send_resp(&1, 200, ""))

    assert_raise ArgumentError, "encode_query/2 values cannot be lists, got: [1, 2]", fn ->
      Req.stream!(req, params: [a: [1, 2]])
    end
  end

  test "put_path_params" do
    %{req: req, url: url} =
      serve(&send_resp(&1, 200, &1.request_path))

    resp = Req.stream!(req, url: "#{url}/:id/ola", path_params: [id: "abc|def"])
    assert resp.status == 200
    assert resp.body == "/abc%7Cdef/ola"

    # With :curly style.

    resp =
      Req.stream!(req,
        url: "#{url}/{id}:bar",
        path_params: [id: "abc|def"],
        path_params_style: :curly
      )

    assert resp.status == 200
    assert resp.body == "/abc%7Cdef:bar"
  end

  @tag :transport
  @tag skip: adapter() == :httpc
  test "put_path_params does not expand curly segments in :colon style" do
    %{req: req, url: url} = serve("GET /": &send_resp(&1, 200, ""))

    {:error, err, resp} =
      Req.stream(req, url: "#{url}/:id{ola}", path_params: [id: "abc"], retry: false)

    assert err == %Req.HTTPError{protocol: :http1, reason: {:invalid_request_target, "/abc{ola}"}}
    assert resp.status == nil
    assert resp.body == ""
  end

  test "put_path_params when path_params are empty still sets the template" do
    %{req: req, url: url} =
      serve("GET /bar": &send_resp(&1, 200, ""))

    resp = Req.stream!(req, url: "#{url}/bar", path_params: [])
    assert resp.status == 200
    assert resp.body == ""
    assert resp.request.private.path_params_template == "/bar"

    resp = Req.stream!(req, url: "#{url}/bar")
    assert resp.status == 200
    assert resp.body == ""
    assert resp.request.private == %{}
  end

  @tag :capture_log
  test "put_path_params is idempotent" do
    %{req: req, url: url} =
      serve("GET /users/123": &send_resp(&1, 500, ""))

    resp = Req.stream!(req, url: "#{url}/users/:id", path_params: [id: 123], retry_delay: 1)

    assert resp.status == 500
    assert resp.body == ""
    assert resp.request.url.path == "/users/123"
    assert resp.request.private.path_params_template == "/users/:id"
  end

  test "put_path_params properly escapes reserved characters" do
    %{req: req, url: url} =
      serve(&send_resp(&1, 200, &1.request_path))

    resp = Req.stream!(req, url: "#{url}/:id/ola", path_params: [id: "abc#def"])
    assert resp.status == 200
    assert resp.body == "/abc%23def/ola"

    # With :curly style.

    resp =
      Req.stream!(req,
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

    resp = Req.stream!(req, range: "bytes=0-10")
    assert resp.status == 200
    assert resp.body == "bytes=0-10"
    resp = Req.stream!(req, range: 0..20)
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
            assert JSON.decode!(body) == %{"a" => 1}
            send_resp(conn, 200, "")
          end,
          "POST /": fn conn ->
            assert get_req_header(conn, "content-encoding") == ["gzip"]
            assert {:ok, body, conn} = read_body(conn)
            assert body |> :zlib.gunzip() |> JSON.decode!() == %{"a" => 1}
            send_resp(conn, 200, "")
          end
        )

      resp = Req.stream!(req, method: :post, json: %{a: 1})
      assert resp.status == 200
      assert resp.body == ""

      resp = Req.stream!(req, method: :post, json: %{a: 1}, compress_body: true)
      assert resp.status == 200
      assert resp.body == ""
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

      resp =
        Req.stream!(req,
          method: :post,
          body: "foo",
          compress_body: true,
          headers: [content_encoding: "br"]
        )

      assert resp.status == 200
      assert resp.body == ""
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

      resp =
        Req.stream!(req,
          method: :post,
          body: Stream.take(~w[foo foo foo], 2),
          compress_body: true
        )

      assert resp.status == 200
      assert resp.body == "foofoo"
    end

    test "req_body_fun" do
      req_body_fun = fn
        [] ->
          {:data, "foo", [:done]}

        [:done] = acc ->
          {:done, acc}
      end

      %{req: req} = serve("POST /": &send_resp(&1, 200, ""))

      assert_raise ArgumentError,
                   "compress_body does not support req_body_fun",
                   fn ->
                     Req.stream(req, [], fn _data, _resp, acc -> {:cont, acc} end,
                       method: :post,
                       body: req_body_fun,
                       compress_body: true
                     )
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

      resp = Req.stream!(req, compress_body: true)
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

      resp = Req.stream!(req, method: :put)
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

      resp = Req.stream!(req, method: :put)
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

      resp = Req.stream!(req, method: :put)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "missing :access_key_id" do
      req = Req.new(aws_sigv4: [])

      assert_raise ArgumentError, "missing :access_key_id in :aws_sigv4 option", fn ->
        Req.stream(req)
      end
    end

    test "missing :secret_access_key" do
      req = Req.new(aws_sigv4: [access_key_id: "foo"])

      assert_raise ArgumentError, "missing :secret_access_key in :aws_sigv4 option", fn ->
        Req.stream(req)
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
        Req.stream(req)
      end
    end
  end
end
