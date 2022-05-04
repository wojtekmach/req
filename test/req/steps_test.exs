defmodule Req.StepsTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  ## Request steps

  test "put_base_url/1", c do
    Bypass.expect(c.bypass, "GET", "", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.get!("/", base_url: c.url).body == "ok"
    assert Req.get!("", base_url: c.url).body == "ok"

    req = Req.new(base_url: c.url)
    assert Req.get!(req, url: "/").body == "ok"
    assert Req.get!(req, url: "").body == "ok"
  end

  test "put_base_url/1: with absolute url", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.get!(c.url, base_url: "ignored").body == "ok"
  end

  test "auth/1: basic" do
    req = Req.new(auth: {"foo", "bar"}) |> Req.Request.prepare()

    assert List.keyfind(req.headers, "authorization", 0) ==
             {"authorization", "Basic #{Base.encode64("foo:bar")}"}
  end

  test "auth/1: bearer" do
    req = Req.new(auth: {:bearer, "abcd"}) |> Req.Request.prepare()

    assert List.keyfind(req.headers, "authorization", 0) ==
             {"authorization", "Bearer abcd"}
  end

  @tag :tmp_dir
  test "auth/1: :netrc", c do
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
  test "auth/1: {:netrc, path}", c do
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

  test "default_headers/1", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      Plug.Conn.send_resp(conn, 200, user_agent)
    end)

    assert "req/" <> _ = Req.get!(c.url).body
  end

  test "encode_body/1: json" do
    req = Req.new(json: %{a: 1}) |> Req.Request.prepare()
    assert req.body |> IO.iodata_to_binary() == ~s|{"a":1}|
  end

  test "encode_body/1: form" do
    req = Req.new(form: [a: 1]) |> Req.Request.prepare()
    assert req.body == "a=1"

    req = Req.new(form: %{a: 1}) |> Req.Request.prepare()
    assert req.body == "a=1"
  end

  test "put_params/1" do
    req = Req.new(url: "http://foo", params: [x: 1, y: 2]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo?x=1&y=2"

    req = Req.new(url: "http://foo", params: [x: 1, x: 2]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo?x=1&x=2"

    req = Req.new(url: "http://foo?x=1", params: [x: 1, y: 2]) |> Req.Request.prepare()
    assert URI.to_string(req.url) == "http://foo?x=1&x=1&y=2"
  end

  test "put_range/1" do
    req = Req.new(range: "bytes=0-10") |> Req.Request.prepare()

    assert List.keyfind(req.headers, "range", 0) ==
             {"range", "bytes=0-10"}

    req = Req.new(range: 0..20) |> Req.Request.prepare()

    assert List.keyfind(req.headers, "range", 0) ==
             {"range", "bytes=0-20"}
  end

  defmodule MyPlug do
    def init(options), do: options

    def call(conn, options) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, [])

      map = %{
        conn: Map.take(conn, [:host, :request_path]),
        body: body,
        options: options
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(map))
    end
  end

  test "put_plug" do
    assert Req.get!("https://foo/bar", body: "yo", plug: MyPlug).body == %{
             "conn" => %{
               "host" => "foo",
               "request_path" => "/bar"
             },
             "body" => "yo",
             "options" => []
           }

    resp = Req.get!("http:///README.md", plug: {Plug.Static, at: "/", from: "."})
    assert resp.body =~ "Req is an HTTP client"
  end

  ## Response steps

  test "decompress/1", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Req.get!(c.url).body == "foo"
  end

  @tag :tmp_dir
  test "output/1: path (compressed)", c do
    Bypass.expect_once(c.bypass, "GET", "/save_to_path", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("to be filed"))
    end)

    response = Req.get!(c.url <> "/save_to_path", output: c.tmp_dir <> "/saved.txt")
    assert response.body == ""
    assert File.read!(c.tmp_dir <> "/saved.txt") == "to be filed"
  end

  test "output/1: :remote_name (not compressed)", c do
    Bypass.expect_once(c.bypass, "GET", "/directory/save_this.txt", fn conn ->
      Plug.Conn.send_resp(conn, 200, "to be filed")
    end)

    response = Req.get!(c.url <> "/directory/save_this.txt", output: :remote_name)
    assert response.body == ""
    assert File.read!("save_this.txt") == "to be filed"
  after
    File.rm("save_this.txt")
  end

  test "output/1: empty filename", c do
    Bypass.expect_once(c.bypass, "GET", "", fn conn ->
      Plug.Conn.send_resp(conn, 200, "body contents")
    end)

    assert_raise RuntimeError, "cannot write to file \"\"", fn ->
      Req.get!(c.url, output: :remote_name)
    end
  end

  test "decode_body/1: json", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
    end)

    assert Req.get!(c.url).body == %{"a" => 1}
  end

  test "decode_body/1: gzip", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Req.get!(c.url).body == "foo"
  end

  @tag :tmp_dir
  test "decode_body/1: tar (content-type)", c do
    files = [{'foo.txt', "bar"}]

    path = '#{c.tmp_dir}/foo.tar'
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
  test "decode_body/1: tar (path)", c do
    files = [{'foo.txt', "bar"}]

    path = '#{c.tmp_dir}/foo.tar'
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
  test "decode_body/1: tar.gz (path)", c do
    files = [{'foo.txt', "bar"}]

    path = '#{c.tmp_dir}/foo.tar'
    :ok = :erl_tar.create(path, files, [:compressed])
    tar = File.read!(path)

    Bypass.expect(c.bypass, "GET", "/foo.tar.gz", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, tar)
    end)

    assert Req.get!(c.url <> "/foo.tar.gz").body == files
  end

  test "decode_body/1: zip (content-type)", c do
    files = [{'foo.txt', "bar"}]

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      {:ok, {'foo.zip', data}} = :zip.create('foo.zip', files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/zip", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url).body == files
  end

  test "decode_body/1: zip (path)", c do
    files = [{'foo.txt', "bar"}]

    Bypass.expect(c.bypass, "GET", "/foo.zip", fn conn ->
      {:ok, {'foo.zip', data}} = :zip.create('foo.zip', files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url <> "/foo.zip").body == files
  end

  test "decode_body/1: csv", c do
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

  test "follow_redirects/1: absolute", c do
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

  test "follow_redirects/1: relative", c do
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

  test "follow_redirects/1: 301..303", c do
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

  test "follow_redirects/1: auth - same host", c do
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

  test "follow_redirects/1: auth - location trusted" do
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

  test "follow_redirects/2: auth - different host" do
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
          refute List.keyfind(request.headers, "authorization", 0)

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
                      auth: {"authorization", "credentials"}
                    ).status == 200
           end) =~ "[debug] follow_redirects: redirecting to http://untrusted"
  end

  test "follow_redirects/1: skip params", c do
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

  test "follow_redirects/1: max redirects", c do
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

  defp redirect(conn, status, url) do
    conn
    |> Plug.Conn.put_resp_header("location", url)
    |> Plug.Conn.send_resp(status, "redirecting to #{url}")
  end

  ## Error steps

  @tag :capture_log
  test "retry: eventually successful", c do
    {:ok, _} = Agent.start_link(fn -> 0 end, name: :counter)

    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      if Agent.get_and_update(:counter, &{&1, &1 + 1}) < 2 do
        Plug.Conn.send_resp(conn, 500, "oops")
      else
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    request =
      Req.new(url: c.url, retry_delay: 1)
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert Req.get!(request).body == "ok - updated"
    assert Agent.get(:counter, & &1) == 3
  end

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
    refute_received _
  end

  @tag :capture_log
  test "retry: always", c do
    pid = self()

    Bypass.expect(c.bypass, "POST", "/", fn conn ->
      send(pid, :ping)
      Plug.Conn.send_resp(conn, 500, "oops")
    end)

    request = Req.new(url: c.url, retry: true, retry_delay: 1)

    assert Req.post!(request).status == 500
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

    request = Req.new(url: c.url, retry: false)

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
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))

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

  test "run_finch/1: pool timeout", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [finch_options: [pool_timeout: 0]]
    assert {:timeout, _} = catch_exit(Req.get!(c.url, options))
  end

  test "run_finch/1: receive timeout", c do
    pid = self()

    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      send(pid, :ping)
      Process.sleep(10)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [finch_options: [receive_timeout: 0], retry_delay: 10]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Mint.TransportError{reason: :timeout}} =
                 Req.request([method: :get, url: c.url] ++ options)

        assert_receive :ping
        assert_receive :ping
        assert_receive :ping
        refute_receive _
      end)

    refute log =~ "3 attempts left"
    assert log =~ "2 attempts left"
    assert log =~ "1 attempt left"
  end
end
