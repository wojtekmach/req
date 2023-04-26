defmodule Req.StepsTest do
  use ExUnit.Case, async: true

  require Logger

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  ## Request steps

  test "put_base_url", c do
    Bypass.expect(c.bypass, "GET", "", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.get!("/", base_url: c.url).body == "ok"
    assert Req.get!("", base_url: c.url).body == "ok"

    req = Req.new(base_url: c.url)
    assert Req.get!(req, url: "/").body == "ok"
    assert Req.get!(req, url: "").body == "ok"
  end

  test "put_base_url: with absolute url", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.get!(c.url, base_url: "ignored").body == "ok"
  end

  test "put_base_url: with base path", c do
    Bypass.expect(c.bypass, "GET", "/api/v2/foo", fn conn ->
      assert conn.request_path == "/api/v2/foo"
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.get!("/foo", base_url: c.url <> "/api/v2", retry: :never).body == "ok"
    assert Req.get!("foo", base_url: c.url <> "/api/v2").body == "ok"
    assert Req.get!("/foo", base_url: c.url <> "/api/v2/").body == "ok"
    assert Req.get!("foo", base_url: c.url <> "/api/v2/").body == "ok"
    assert Req.get!("", base_url: c.url <> "/api/v2/foo").body == "ok"
  end

  test "auth: string" do
    req = Req.new(auth: "foo") |> Req.Request.prepare()

    assert List.keyfind(req.headers, "authorization", 0) == {"authorization", "foo"}
  end

  test "auth: basic" do
    req = Req.new(auth: {"foo", "bar"}) |> Req.Request.prepare()

    assert List.keyfind(req.headers, "authorization", 0) ==
             {"authorization", "Basic #{Base.encode64("foo:bar")}"}
  end

  test "auth: bearer" do
    req = Req.new(auth: {:bearer, "abcd"}) |> Req.Request.prepare()

    assert List.keyfind(req.headers, "authorization", 0) ==
             {"authorization", "Bearer abcd"}
  end

  @tag :tmp_dir
  test "auth: :netrc", c do
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
  test "auth: {:netrc, path}", c do
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

  test "default options", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      send(pid, {:params, conn.params})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    Req.default_options(params: %{"foo" => "bar"})
    Req.get!(c.url)
    assert_received {:params, %{"foo" => "bar"}}
  after
    Application.put_env(:req, :default_options, [])
  end

  test "default_headers", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      Plug.Conn.send_resp(conn, 200, user_agent)
    end)

    assert "req/" <> _ = Req.get!(c.url).body
  end

  test "encode_body: json", c do
    Bypass.expect(c.bypass, "POST", "/", fn conn ->
      assert {:ok, ~s|{"a":1}|, conn} = Plug.Conn.read_body(conn)
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")

      Plug.Conn.send_resp(conn, 200, "")
    end)

    Req.post!(c.url, json: %{a: 1})
  end

  test "encode_body: form" do
    req = Req.new(form: [a: 1]) |> Req.Request.prepare()
    assert req.body == "a=1"

    req = Req.new(form: %{a: 1}) |> Req.Request.prepare()
    assert req.body == "a=1"
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
    req = Req.new(url: "http://foo/:id", path_params: [id: 1]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo/1"
  end

  test "put_range" do
    req = Req.new(range: "bytes=0-10") |> Req.Request.prepare()

    assert List.keyfind(req.headers, "range", 0) ==
             {"range", "bytes=0-10"}

    req = Req.new(range: 0..20) |> Req.Request.prepare()

    assert List.keyfind(req.headers, "range", 0) ==
             {"range", "bytes=0-20"}
  end

  test "compress_body" do
    req = Req.new(method: :post, json: %{a: 1}) |> Req.Request.prepare()
    assert Jason.decode!(req.body) == %{"a" => 1}

    req = Req.new(method: :post, json: %{a: 1}, compress_body: true) |> Req.Request.prepare()
    assert :zlib.gunzip(req.body) |> Jason.decode!() == %{"a" => 1}
    assert List.keyfind(req.headers, "content-encoding", 0) == {"content-encoding", "gzip"}
  end

  ## Response steps

  test "decompress_body: gzip", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Req.get!(c.url).body == "foo"
  end

  test "decompress_body: brotli", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      {:ok, body} = :brotli.encode("foo")

      conn
      |> Plug.Conn.put_resp_header("content-encoding", "br")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert Req.get!(c.url).body == "foo"
  end

  @tag :capture_log
  test "decompress_body: zstd", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "zstd")
      |> Plug.Conn.send_resp(200, :ezstd.compress("foo"))
    end)

    assert Req.get!(c.url).body == "foo"
  end

  @tag :tmp_dir
  test "output: path (compressed)", c do
    Bypass.expect_once(c.bypass, "GET", "/foo.txt", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("bar"))
    end)

    response = Req.get!(c.url <> "/foo.txt", output: c.tmp_dir <> "/foo.txt")
    assert response.body == ""
    assert File.read!(c.tmp_dir <> "/foo.txt") == "bar"
  end

  test "output: :remote_name", c do
    Bypass.expect_once(c.bypass, "GET", "/directory/does/not/matter/foo.txt", fn conn ->
      Plug.Conn.send_resp(conn, 200, "bar")
    end)

    response = Req.get!(c.url <> "/directory/does/not/matter/foo.txt", output: :remote_name)
    assert response.body == ""
    assert File.read!("foo.txt") == "bar"
  after
    File.rm("foo.txt")
  end

  test "output: disables decoding", c do
    Bypass.expect_once(c.bypass, "GET", "/foo.json", fn conn ->
      json(conn, 200, %{a: 1})
    end)

    response = Req.get!(c.url <> "/foo.json", output: :remote_name)
    assert response.body == ""
    assert File.read!("foo.json") == ~s|{"a":1}|
  after
    File.rm("foo.json")
  end

  test "output: empty filename", c do
    Bypass.expect_once(c.bypass, "GET", "", fn conn ->
      Plug.Conn.send_resp(conn, 200, "body contents")
    end)

    assert_raise RuntimeError, "cannot write to file \"\"", fn ->
      Req.get!(c.url, output: :remote_name)
    end
  end

  test "decode_body: json", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      json(conn, 200, %{a: 1})
    end)

    assert Req.get!(c.url).body == %{"a" => 1}
  end

  test "decode_body: json-api", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/vnd.api+json; charset=utf-8")
      |> json(200, %{a: 1})
    end)

    assert Req.get!(c.url).body == %{"a" => 1}
  end

  @tag :tmp_dir
  test "decode_body: with output", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      json(conn, 200, %{a: 1})
    end)

    assert Req.get!(c.url, output: c.tmp_dir <> "/a.json").body == ""
    assert File.read!(c.tmp_dir <> "/a.json") == ~s|{"a":1}|
  end

  test "decode_body: gzip", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Req.get!(c.url).body == "foo"
  end

  @tag :tmp_dir
  test "decode_body: tar (content-type)", c do
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
  test "decode_body: tar (path)", c do
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
  test "decode_body: tar extract", c do
    files = [{~c"foo.txt", "bar"}]

    path = ~c"#{c.tmp_dir}/foo.tar"
    :ok = :erl_tar.create(path, files, [])
    tar = File.read!(path)

    Bypass.expect(c.bypass, "GET", "/foo.tar", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, tar)
    end)

    dir = "#{c.tmp_dir}/dir"
    assert Req.get!(c.url <> "/foo.tar", extract: dir).body == ["#{dir}/foo.txt"]
    assert File.ls!(dir) == ["foo.txt"]
    assert File.read!("#{dir}/foo.txt") == "bar"
  end

  @tag :tmp_dir
  test "decode_body: tar.gz (path)", c do
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

  @tag :tmp_dir
  test "decode_body: tar.gz extract", c do
    files = [{~c"foo.txt", "bar"}]

    path = ~c"#{c.tmp_dir}/foo.tar"
    :ok = :erl_tar.create(path, files, [:compressed])
    tar = File.read!(path)

    Bypass.expect(c.bypass, "GET", "/foo.tar.gz", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, tar)
    end)

    dir = "#{c.tmp_dir}/dir"
    assert Req.get!(c.url <> "/foo.tar.gz", extract: dir).body == ["#{dir}/foo.txt"]
    assert File.ls!(dir) == ["foo.txt"]
    assert File.read!("#{dir}/foo.txt") == "bar"
  end

  test "decode_body: zip (content-type)", c do
    files = [{~c"foo.txt", "bar"}]

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      {:ok, {~c"foo.zip", data}} = :zip.create(~c"foo.zip", files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/zip", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url).body == files
  end

  test "decode_body: zip (path)", c do
    files = [{~c"foo.txt", "bar"}]

    Bypass.expect(c.bypass, "GET", "/foo.zip", fn conn ->
      {:ok, {~c"foo.zip", data}} = :zip.create(~c"foo.zip", files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url <> "/foo.zip").body == files
  end

  @tag :tmp_dir
  test "decode_body: zip extract", c do
    files = [{~c"foo.txt", "bar"}]

    Bypass.expect(c.bypass, "GET", "/foo.zip", fn conn ->
      {:ok, {~c"foo.zip", data}} = :zip.create(~c"foo.zip", files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    dir = "#{c.tmp_dir}/dir"
    assert Req.get!(c.url <> "/foo.zip", extract: dir).body == ["#{dir}/foo.txt"]
    assert File.ls!(dir) == ["foo.txt"]
    assert File.read!("#{dir}/foo.txt") == "bar"
  end

  test "decode_body: csv", c do
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

  test "follow_redirects: absolute", c do
    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      redirect(conn, 302, c.url <> "/ok")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!(c.url <> "/redirect").status == 200
           end) =~ "[debug] follow_redirects: redirecting to #{c.url}/ok"
  end

  test "follow_redirects: relative", c do
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
           end) =~ "[debug] follow_redirects: redirecting to /ok"

    assert ExUnit.CaptureLog.capture_log(fn ->
             response = Req.get!(c.url <> "/redirect?a=1")
             assert response.status == 200
             assert response.body == "a=1"
           end) =~ "[debug] follow_redirects: redirecting to /ok?a=1"
  end

  test "follow_redirects: 301..303", c do
    Bypass.expect(c.bypass, "POST", "/redirect", fn conn ->
      redirect(conn, 301, c.url <> "/ok")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.post!(c.url <> "/redirect", body: "body").status == 200
           end) =~ "[debug] follow_redirects: redirecting to #{c.url}/ok"
  end

  test "follow_redirects: auth same host", c do
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
           end) =~ "[debug] follow_redirects: redirecting to #{c.url}/auth"
  end

  test "follow_redirects: auth location trusted" do
    adapter = fn request ->
      case request.url.host do
        "original" ->
          assert List.keyfind(request.headers, "authorization", 0)

          response = %Req.Response{
            status: 301,
            headers: [{"location", "http://untrusted"}],
            body: "redirecting"
          }

          {request, response}

        "untrusted" ->
          assert List.keyfind(request.headers, "authorization", 0)

          response = %Req.Response{
            status: 200,
            headers: [],
            body: "bad things"
          }

          {request, response}
      end
    end

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!("http://original",
                      adapter: adapter,
                      auth: {"authorization", "credentials"},
                      location_trusted: true
                    ).status == 200
           end) =~ "[debug] follow_redirects: redirecting to http://untrusted"
  end

  test "follow_redirects/2: auth different host" do
    adapter = untrusted_redirect_adapter(:host, "trusted", "untrusted")

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!("http://trusted",
                      adapter: adapter,
                      auth: {"authorization", "credentials"}
                    ).status == 200
           end) =~ "[debug] follow_redirects: redirecting to http://untrusted"
  end

  test "follow_redirects/2: auth different port" do
    adapter = untrusted_redirect_adapter(:port, 12345, 23456)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!("http://trusted:12345",
                      adapter: adapter,
                      auth: {"authorization", "credentials"}
                    ).status == 200
           end) =~ "[debug] follow_redirects: redirecting to http://trusted:23456"
  end

  test "follow_redirects/2: auth different scheme" do
    adapter = untrusted_redirect_adapter(:scheme, "http", "https")

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!("http://trusted",
                      adapter: adapter,
                      auth: {"authorization", "credentials"}
                    ).status == 200
           end) =~ "[debug] follow_redirects: redirecting to https://trusted"
  end

  test "follow_redirects: skip params", c do
    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      redirect(conn, 302, c.url <> "/ok")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      assert conn.query_string == ""
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!(c.url <> "/redirect", params: [a: 1]).status == 200
           end) =~ "[debug] follow_redirects: redirecting to #{c.url}/ok"
  end

  test "follow_redirects: max redirects", c do
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

    assert captured_log =~ "follow_redirects: redirecting to " <> c.url
  end

  test "follow_redirects: redirect_log_level, default to :debug", c do
    "http:" <> no_scheme = c.url

    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      redirect(conn, 302, "#{no_scheme}/ok")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!(c.url <> "/redirect").status == 200
           end) =~ "[debug] follow_redirects: redirecting to #{no_scheme}/ok"
  end

  test "follow_redirects: redirect_log_level, set to :error", c do
    "http:" <> no_scheme = c.url

    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      redirect(conn, 302, "#{no_scheme}/ok")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!(c.url <> "/redirect", redirect_log_level: :error).status == 200
           end) =~ "[error] follow_redirects: redirecting to #{no_scheme}/ok"
  end

  test "follow_redirects: redirect_log_level, disabled", c do
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

  test "follow_redirects: inherit scheme", c do
    "http:" <> no_scheme = c.url

    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      redirect(conn, 302, "#{no_scheme}/ok")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!(c.url <> "/redirect").status == 200
           end) =~ "[debug] follow_redirects: redirecting to #{no_scheme}/ok"
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
          assert List.keyfind(request.headers, "authorization", 0)

          new_url =
            request.url
            |> Map.put(component, updated_value)
            |> to_string()

          response = %Req.Response{
            status: 301,
            headers: [{"location", new_url}],
            body: "redirecting"
          }

          {request, response}

        ^updated_value ->
          refute List.keyfind(request.headers, "authorization", 0)

          response = %Req.Response{
            status: 200,
            headers: [],
            body: "bad things"
          }

          {request, response}
      end
    end
  end

  ## Error steps

  @tag :capture_log
  test "retry: eventually successful - function", c do
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
        response = Req.get!(request)
        assert response.body == "ok - updated"
      end)

    assert log =~ "will retry in 1ms, 3 attempts left"
    assert log =~ "will retry in 2ms, 2 attempts left"
    assert log =~ "will retry in 4ms, 1 attempt left"
  end

  @tag :capture_log
  test "retry: eventually successful - integer", c do
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
  test "retry: default log_level", c do
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
  test "retry: custom log_level", c do
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
  test "retry: logging disabled", c do
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
  test "retry: retry-after" do
    adapter = fn request ->
      request = Req.Request.update_private(request, :attempt, 0, &(&1 + 1))
      attempt = request.private.attempt

      response =
        case attempt do
          0 -> Req.Response.new(status: 429) |> retry_after(0)
          1 -> Req.Response.new(status: 429) |> retry_after(DateTime.utc_now())
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
  test "retry: always failing", c do
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

  test "retry: never", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      send(pid, :ping)
      Plug.Conn.send_resp(conn, 500, "oops")
    end)

    request = Req.new(url: c.url, retry: :never)

    assert Req.get!(request).status == 500
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "retry: custom function", c do
    pid = self()

    Bypass.expect(c.bypass, "POST", "/", fn conn ->
      send(pid, :ping)
      Plug.Conn.send_resp(conn, 500, "oops")
    end)

    fun = fn response ->
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
  test "retry: does not re-encode params", c do
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

  test "put_plug" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == ~s|{"a":1}|
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert Req.request!(plug: plug, json: %{a: 1}).body == "ok"
  end

  test "run_finch: :finch_request with arity 1 (deprecated)", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    pid = self()

    fun = fn request ->
      send(pid, request)
      request
    end

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Req.get!(c.url <> "/ok", finch_request: fun).body == "ok"
      end)

    assert warning =~ "deprecated"
    assert_received %Finch.Request{}
  end

  test "run_finch: :finch_request", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    pid = self()

    fun = fn req, finch_request, finch_name, finch_opts ->
      {:ok, resp} = Finch.request(finch_request, finch_name, finch_opts)
      send(pid, resp)
      {req, %Req.Response{status: resp.status, headers: resp.headers, body: "finch_request"}}
    end

    assert Req.get!(c.url <> "/ok", finch_request: fun).body == "finch_request"
    assert_received %Finch.Response{body: "ok"}
  end

  test "run_finch: :finch_request error", c do
    fun = fn req, _finch_request, _finch_name, _finch_opts ->
      {req, %ArgumentError{message: "exec error"}}
    end

    assert_raise ArgumentError, "exec error", fn ->
      Req.get!(c.url, finch_request: fun, retry: :never)
    end
  end

  test "run-finch: :finch_request with invalid return", c do
    fun = fn _, _, _, _ -> :ok end

    assert_raise RuntimeError, ~r"expected adapter to return \{request, response\}", fn ->
      Req.get!(c.url, finch_request: fun)
    end
  end

  test "run_finch: pool timeout", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [pool_timeout: 0]

    assert_raise RuntimeError, ~r/unable to provide a connection within the timeout/, fn ->
      Req.get!(c.url, options)
    end
  end

  test "run_finch: receive timeout", c do
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

  test "run_finch: :connect_options :timeout" do
    {:ok, listen_sock} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(listen_sock)

    req =
      Req.new(
        url: "http://localhost:#{port}",
        connect_options: [timeout: 0],
        retry: :never
      )

    Task.async(fn ->
      assert Req.request(req) == {:error, %Mint.TransportError{reason: :timeout}}
    end)
    |> Task.await(1000)
  end

  test "run_finch: :connect_options :protocol", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      {_, %{version: :"HTTP/2"}} = conn.adapter
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    req = Req.new(url: c.url, connect_options: [protocol: :http2])
    assert Req.request!(req).body == "ok"
  end

  test "run_finch: :connect_options :proxy", c do
    Bypass.expect(c.bypass, "GET", "/foo/bar", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    # Bypass will forward request to itself
    # Not quite a proper forward proxy server, but good enough
    test_proxy = {:http, "localhost", c.bypass.port, []}

    req = Req.new(base_url: c.url, connect_options: [proxy: test_proxy])
    assert Req.request!(req, url: "/foo/bar").body == "ok"
  end

  test "run_finch: :connect_options :hostname", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      assert Plug.Conn.get_req_header(conn, "host") == ["example.com:#{c.bypass.port}"]
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    req = Req.new(base_url: c.url, connect_options: [hostname: "example.com"])
    assert Req.request!(req).body == "ok"
  end

  test "run_finch: :connect_options :transport_opts", c do
    req = Req.new(connect_options: [transport_opts: [cacertfile: "bad.pem"]])

    assert_raise File.Error, ~r/could not read file "bad.pem"/, fn ->
      Req.request!(req, url: "https://localhost:#{c.bypass.port}")
    end
  end

  test "run_finch: :connect_options bad option", c do
    assert_raise ArgumentError, "unknown option :timeou. Did you mean :timeout?", fn ->
      Req.get!(c.url, connect_options: [timeou: 0])
    end
  end

  test "run_finch: :finch and :connect_options" do
    assert_raise ArgumentError, "cannot set both :finch and :connect_options", fn ->
      Req.request!(finch: MyFinch, connect_options: [timeout: 0])
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
