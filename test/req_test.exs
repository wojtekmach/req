defmodule ReqTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  describe "high-level API" do
    test "get!/2", c do
      Bypass.expect(c.bypass, "GET", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.get!(c.url <> "/json").body == %{"a" => 1}
    end

    test "post!/3", c do
      Bypass.expect(c.bypass, "POST", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.post!(c.url <> "/json", {:json, %{foo: "bar"}}).body == %{"a" => 1}
    end

    test "put!/3", c do
      Bypass.expect(c.bypass, "PUT", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.put!(c.url <> "/json", {:json, %{foo: "bar"}}).body == %{"a" => 1}
    end

    test "delete!/2", c do
      Bypass.expect(c.bypass, "DELETE", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
      end)

      assert Req.delete!(c.url <> "/json").body == %{"a" => 1}
    end
  end

  test "raw mode", c do
    raw = :zlib.gzip(Jason.encode_to_iodata!(%{"a" => 1}))

    Bypass.expect(c.bypass, "GET", "/json+gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, raw)
    end)

    assert Req.get!(c.url <> "/json+gzip", raw: true).body == raw
  end

  ## Finch errors

  test "pool timeout", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [finch_options: [pool_timeout: 0]]
    assert {:timeout, _} = catch_exit(Req.get!(c.url <> "/", options))
  end

  test "receive timeout", c do
    Bypass.stub(c.bypass, "GET", "/", fn conn ->
      Process.sleep(1000)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    options = [finch_options: [receive_timeout: 0]]

    assert {:error, %Mint.TransportError{reason: :timeout}} =
             Req.request(:get, c.url <> "/", options)

    # TODO:
    # when this is uncommented, we'll get an exit shutdown, figure out why
    # Process.sleep(1000)
  end

  ## Low-level API

  test "low-level API", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request = Req.build(:get, c.url <> "/ok")
    assert {:ok, %{status: 200, body: "ok"}} = Req.run(request)
  end

  test "simple request step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.build(:get, c.url <> "/not-found")
      |> Req.prepend_request_steps([
        fn request ->
          put_in(request.url.path, "/ok")
        end
      ])

    assert {:ok, %{status: 200, body: "ok"}} = Req.run(request)
  end

  test "request step returns response", c do
    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_request_steps([
        fn request ->
          {request, %Req.Response{status: 200, body: "from cache"}}
        end
      ])
      |> Req.prepend_response_steps([
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])

    assert {:ok, %{status: 200, body: "from cache - updated"}} = Req.run(request)
  end

  test "request step returns exception", c do
    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_request_steps([
        fn request ->
          {request, RuntimeError.exception("oops")}
        end
      ])
      |> Req.prepend_error_steps([
        fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      ])

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.run(request)
  end

  test "request step halts with response", c do
    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_request_steps([
        fn request ->
          {Req.Request.halt(request), %Req.Response{status: 200, body: "from cache"}}
        end,
        &unreachable/1
      ])
      |> Req.prepend_response_steps([
        &unreachable/1
      ])
      |> Req.prepend_error_steps([
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "from cache"}} = Req.run(request)
  end

  test "request step halts with exception", c do
    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_request_steps([
        fn request ->
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        &unreachable/1
      ])
      |> Req.prepend_response_steps([
        &unreachable/1
      ])
      |> Req.prepend_error_steps([
        &unreachable/1
      ])

    assert {:error, %RuntimeError{message: "oops"}} = Req.run(request)
  end

  test "simple response step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_response_steps([
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.run(request)
  end

  test "response step returns exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_response_steps([
        fn {request, response} ->
          assert response.body == "ok"
          {request, RuntimeError.exception("oops")}
        end
      ])
      |> Req.prepend_error_steps([
        fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      ])

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.run(request)
  end

  test "response step halts with response", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_response_steps([
        fn {request, response} ->
          {Req.Request.halt(request), update_in(response.body, &(&1 <> " - updated"))}
        end,
        &unreachable/1
      ])
      |> Req.prepend_error_steps([
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.run(request)
  end

  test "response step halts with exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_response_steps([
        fn {request, response} ->
          assert response.body == "ok"
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        &unreachable/1
      ])
      |> Req.prepend_error_steps([
        &unreachable/1
      ])

    assert {:error, %RuntimeError{message: "oops"}} = Req.run(request)
  end

  test "simple error step", c do
    Bypass.down(c.bypass)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_error_steps([
        fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, RuntimeError.exception("oops")}
        end
      ])

    assert {:error, %RuntimeError{message: "oops"}} = Req.run(request)
  end

  test "error step returns response", c do
    Bypass.down(c.bypass)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_response_steps([
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])
      |> Req.prepend_error_steps([
        fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, %Req.Response{status: 200, body: "ok"}}
        end,
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.run(request)
  end

  test "error step halts with response", c do
    Bypass.down(c.bypass)

    request =
      Req.build(:get, c.url <> "/ok")
      |> Req.prepend_response_steps([
        &unreachable/1
      ])
      |> Req.prepend_error_steps([
        fn {request, exception} ->
          assert exception.reason == :econnrefused
          {Req.Request.halt(request), %Req.Response{status: 200, body: "ok"}}
        end,
        &unreachable/1
      ])

    assert {:ok, %{status: 200, body: "ok"}} = Req.run(request)
  end

  ## Request steps

  test "put_base_url/2", c do
    Bypass.expect(c.bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.get!("/", base_url: c.url).status == 200
    assert Req.get!("", base_url: c.url).status == 200
  end

  test "auth/2", c do
    Bypass.expect(c.bypass, "GET", "/auth", fn conn ->
      expected = "Basic " <> Base.encode64("foo:bar")

      case Plug.Conn.get_req_header(conn, "authorization") do
        [^expected] ->
          Plug.Conn.send_resp(conn, 200, "ok")

        _ ->
          Plug.Conn.send_resp(conn, 401, "unauthorized")
      end
    end)

    assert Req.get!(c.url <> "/auth", auth: {"bad", "bad"}).status == 401
    assert Req.get!(c.url <> "/auth", auth: {"foo", "bar"}).status == 200
  end

  test "encode_headers/1", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/encode-headers", fn conn ->
      send(pid, {:headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    Req.get!(c.url <> "/encode-headers",
      headers: [user_agent: :foo, x_date: ~U[2021-01-01 09:00:00Z]]
    )

    assert_receive {:headers, headers}
    assert Map.new(headers)["user-agent"] == "foo"
    assert Map.new(headers)["x-date"] == "Fri, 01 Jan 2021 09:00:00 GMT"
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

  @tag :tmp_dir
  test "load_netrc/2", c do
    Bypass.expect(c.bypass, "GET", "/auth", fn conn ->
      expected = "Basic " <> Base.encode64("foo:bar")

      case Plug.Conn.get_req_header(conn, "authorization") do
        [^expected] ->
          Plug.Conn.send_resp(conn, 200, "ok")

        _ ->
          Plug.Conn.send_resp(conn, 401, "unauthorized")
      end
    end)

    assert Req.get!(c.url <> "/auth").status == 401

    File.write!("#{c.tmp_dir}/empty_netrc", "")
    assert Req.get!(c.url <> "/auth", netrc: "#{c.tmp_dir}/empty_netrc").status == 401

    File.write!("#{c.tmp_dir}/wrong_netrc", """
    machine localhost
    username bad
    password bad
    """)

    assert Req.get!(c.url <> "/auth", netrc: "#{c.tmp_dir}/wrong_netrc").status == 401

    File.write!("#{c.tmp_dir}/correct_netrc", """
    machine localhost
    username foo
    password bar
    """)

    assert Req.get!(c.url <> "/auth", netrc: "#{c.tmp_dir}/correct_netrc").status == 200

    File.write!("#{c.tmp_dir}/bad_netrc", """
    bad
    """)

    assert_raise RuntimeError, "parse error: \"bad\"", fn ->
      Req.get!(c.url <> "/auth", netrc: "#{c.tmp_dir}/bad_netrc")
    end
  end

  test "default_headers/1", c do
    Bypass.expect(c.bypass, "GET", "/user-agent", fn conn ->
      [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      Plug.Conn.send_resp(conn, 200, user_agent)
    end)

    assert %{body: "req/" <> _} = Req.get!(c.url <> "/user-agent")
  end

  test "encode/2: json", c do
    Bypass.expect(c.bypass, "POST", "/json", fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [{:json, json_decoder: Jason}]))
      assert conn.body_params == %{"a" => 1}
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.post!(c.url <> "/json", {:json, %{a: 1}}).body == "ok"
  end

  test "encode/2: form", c do
    Bypass.expect(c.bypass, "POST", "/form", fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded]))
      assert conn.body_params == %{"a" => "1"}
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert Req.post!(c.url <> "/form", {:form, a: 1}).body == "ok"
  end

  test "params/2", c do
    Bypass.expect(c.bypass, "GET", "/params", fn conn ->
      Plug.Conn.send_resp(conn, 200, conn.query_string)
    end)

    assert Req.get!(c.url <> "/params", params: [x: 1, y: 2]).body == "x=1&y=2"
    assert Req.get!(c.url <> "/params?x=1", params: [y: 2, z: 3]).body == "x=1&y=2&z=3"
  end

  test "range/2", c do
    Bypass.expect(c.bypass, "GET", "/range", fn conn ->
      [range] = Plug.Conn.get_req_header(conn, "range")
      Plug.Conn.send_resp(conn, 206, range)
    end)

    assert Req.get!(c.url <> "/range", range: "bytes=0-10").body == "bytes=0-10"
    assert Req.get!(c.url <> "/range", range: 0..10).body == "bytes=0-10"
  end

  ## Response steps

  test "decompress/2", c do
    Bypass.expect(c.bypass, "GET", "/gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "x-gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Req.get!(c.url <> "/gzip").body == "foo"
  end

  test "decode/2: json", c do
    Bypass.expect(c.bypass, "GET", "/json", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(%{"a" => 1}))
    end)

    assert Req.get!(c.url <> "/json").body == %{"a" => 1}
  end

  test "decode/2: gzip", c do
    Bypass.expect(c.bypass, "GET", "/gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/x-gzip", nil)
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Req.get!(c.url <> "/gzip").body == "foo"
  end

  @tag :tmp_dir
  test "decode/2: tar (content-type)", c do
    files = [{'foo.txt', "bar"}]

    path = '#{c.tmp_dir}/foo.tar'
    :ok = :erl_tar.create(path, files)
    tar = File.read!(path)

    Bypass.expect(c.bypass, "GET", "/tar", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/x-tar")
      |> Plug.Conn.send_resp(200, tar)
    end)

    assert Req.get!(c.url <> "/tar").body == files
  end

  @tag :tmp_dir
  test "decode/2: tar (path)", c do
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
  test "decode/2: tar.gz (path)", c do
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

  test "decode/2: zip (content-type)", c do
    files = [{'foo.txt', "bar"}]

    Bypass.expect(c.bypass, "GET", "/zip", fn conn ->
      {:ok, {'foo.zip', data}} = :zip.create('foo.zip', files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/zip", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url <> "/zip").body == files
  end

  test "decode/2: zip (path)", c do
    files = [{'foo.txt', "bar"}]

    Bypass.expect(c.bypass, "GET", "/foo.zip", fn conn ->
      {:ok, {'foo.zip', data}} = :zip.create('foo.zip', files, [:memory])

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url <> "/foo.zip").body == files
  end

  test "decode/2: csv", c do
    csv = [
      ["x", "y"],
      ["1", "2"],
      ["3", "4"]
    ]

    Bypass.expect(c.bypass, "GET", "/csv", fn conn ->
      data = NimbleCSV.RFC4180.dump_to_iodata(csv)

      conn
      |> Plug.Conn.put_resp_content_type("text/csv")
      |> Plug.Conn.send_resp(200, data)
    end)

    assert Req.get!(c.url <> "/csv").body == csv
  end

  test "follow_redirects/2: absolute", c do
    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      location = c.url <> "/ok"

      conn
      |> Plug.Conn.put_resp_header("location", location)
      |> Plug.Conn.send_resp(302, "redirecting to #{location}")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Req.get!(c.url <> "/redirect").status == 200
           end) =~ "[debug] Req.follow_redirects/2: Redirecting to #{c.url}/ok"
  end

  test "follow_redirects/2: relative", c do
    Bypass.expect(c.bypass, "GET", "/redirect", fn conn ->
      location =
        case conn.query_string do
          nil -> "/ok"
          string -> "/ok?" <> string
        end

      conn
      |> Plug.Conn.put_resp_header("location", location)
      |> Plug.Conn.send_resp(302, "redirecting to #{location}")
    end)

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, conn.query_string)
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             response = Req.get!(c.url <> "/redirect")
             assert response.status == 200
             assert response.body == ""
           end) =~ "[debug] Req.follow_redirects/2: Redirecting to /ok"

    assert ExUnit.CaptureLog.capture_log(fn ->
             response = Req.get!(c.url <> "/redirect?a=1")
             assert response.status == 200
             assert response.body == "a=1"
           end) =~ "[debug] Req.follow_redirects/2: Redirecting to /ok?a=1"
  end

  ## Error steps

  @tag :capture_log
  test "retry: eventually successful", c do
    {:ok, _} = Agent.start_link(fn -> 0 end, name: :counter)

    Bypass.expect(c.bypass, "GET", "/retry", fn conn ->
      if Agent.get_and_update(:counter, &{&1, &1 + 1}) < 2 do
        Plug.Conn.send_resp(conn, 500, "oops")
      else
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    request =
      Req.build(:get, c.url <> "/retry")
      |> Req.prepend_response_steps([
        &Req.retry(&1, delay: 10),
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.run(request)
    assert Agent.get(:counter, & &1) == 3
  end

  @tag :capture_log
  test "retry: always failing", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/retry", fn conn ->
      send(pid, :ping)
      Plug.Conn.send_resp(conn, 500, "oops")
    end)

    request =
      Req.build(:get, c.url <> "/retry")
      |> Req.prepend_response_steps([
        &Req.retry(&1, delay: 10),
        fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      ])

    assert {:ok, %{status: 500, body: "oops - updated"}} = Req.run(request)
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :tmp_dir
  test "cache", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/cache", fn conn ->
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

    request =
      Req.build(:get, c.url <> "/cache")
      |> Req.prepend_request_steps([&Req.put_if_modified_since(&1, dir: c.tmp_dir)])

    response = Req.run!(request)
    assert response.status == 200
    assert response.body == "ok"
    assert_received :cache_miss

    response = Req.run!(request)
    assert response.status == 200
    assert response.body == "ok"
    assert_received :cache_hit
  end

  @tag :tmp_dir
  @tag :capture_log
  test "cache + retry", c do
    pid = self()
    {:ok, _} = Agent.start_link(fn -> 0 end, name: :counter)

    Bypass.expect(c.bypass, "GET", "/cache", fn conn ->
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
      Req.build(:get, c.url <> "/cache")
      |> Req.prepend_request_steps([&Req.put_if_modified_since(&1, dir: c.tmp_dir)])
      |> Req.prepend_response_steps([&Req.retry(&1, delay: 10), &Req.decode_body/1])

    response = Req.run!(request)
    assert response.status == 200
    assert response.body == %{"a" => 1}
    assert_received :cache_miss

    response = Req.run!(request)
    assert response.status == 200
    assert response.body == %{"a" => 1}
    assert_received :cache_hit
    assert_received :cache_hit
    assert_received :cache_hit
    refute_received _
  end

  ## Helpers

  defp unreachable(_) do
    raise "unreachable"
  end
end
