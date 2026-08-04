defmodule Req.PlugTest do
  use Req.Case, async: true

  test "reading request body" do
    plug = fn conn ->
      {:ok, "{\"a\":1}", conn} = Plug.Conn.read_body(conn)
      {:ok, "", conn} = Plug.Conn.read_body(conn)
      assert conn.body_params == %{"a" => 1}
      assert Req.Test.raw_body(conn) == "{\"a\":1}"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    resp = Req.stream!(method: :post, plug: plug, json: %{a: 1})
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "partially reading body" do
    plug = fn conn ->
      {:more, "{", conn} = Plug.Conn.read_body(conn, length: 1)
      {:more, "\"", conn} = Plug.Conn.read_body(conn, length: 1)
      {:more, "a\"", conn} = Plug.Conn.read_body(conn, length: 2)
      {:more, ":", conn} = Plug.Conn.read_body(conn, length: 1)
      {:ok, "1}", conn} = Plug.Conn.read_body(conn)
      # We're done here
      {:ok, "", conn} = Plug.Conn.read_body(conn)

      assert conn.body_params == %{"a" => 1}
      assert Req.Test.raw_body(conn) == "{\"a\":1}"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    resp = Req.stream!(method: :post, plug: plug, json: %{a: 1})
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "reading json body with parsers" do
    plug = fn conn ->
      parser_opts =
        Plug.Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

      conn = Plug.Parsers.call(conn, parser_opts)
      {:ok, "{\"a\":1}", conn} = Plug.Conn.read_body(conn)
      {:ok, "", conn} = Plug.Conn.read_body(conn)

      assert conn.body_params == %{"a" => 1}
      assert Req.Test.raw_body(conn) == "{\"a\":1}"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    resp = Req.stream!(method: :post, plug: plug, json: %{a: 1})
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "reading binary body" do
    plug = fn conn ->
      {:ok, "foo", conn} = Plug.Conn.read_body(conn)
      {:ok, "", conn} = Plug.Conn.read_body(conn)
      assert Req.Test.raw_body(conn) == "foo"
      assert Req.Test.raw_body(conn) == "foo"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    resp = Req.stream!(method: :post, plug: plug, body: "foo")
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "reading binary body with parsers" do
    plug = fn conn ->
      parser_opts =
        Plug.Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason
        )

      conn = Plug.Parsers.call(conn, parser_opts)

      {:ok, "foo", conn} = Plug.Conn.read_body(conn)
      {:ok, "", conn} = Plug.Conn.read_body(conn)

      assert conn.body_params == %{}
      assert Req.Test.raw_body(conn) == "foo"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    resp = Req.stream!(method: :post, plug: plug, body: "foo")
    assert resp.status == 200
    assert resp.body == "ok"
  end

  test "request" do
    plug = fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert body == ~s|{"a":1}|
      assert conn.query_params == %{"foo" => <<0xFF>>}
      send_resp(conn, 200, "ok")
    end

    req = Req.new(plug: plug, json: %{a: 1}, params: %{foo: <<0xFF>>})

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == "ok"

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc ->
        {:cont, [data | acc]}
      end)

    assert resp.status == 200
    assert acc == ["ok"]

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

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == "foofoo"

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc ->
        {:cont, [data | acc]}
      end)

    assert resp.status == 200
    assert acc == ["foofoo"]

    refute_receive _
  end

  test "fetches query params" do
    plug = fn conn ->
      assert conn.query_params == %{"a" => "1"}
      send_resp(conn, 200, "ok")
    end

    req = Req.new(plug: plug, params: [a: 1])

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == "ok"

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc ->
        {:cont, [data | acc]}
      end)

    assert resp.status == 200
    assert acc == ["ok"]
  end

  test "fetches request body" do
    plug = fn conn ->
      assert conn.body_params == %{"a" => 1}
      assert Req.Test.raw_body(conn) == "{\"a\":1}"
      send_resp(conn, 200, "ok")
    end

    req = Req.new(plug: plug, json: %{a: 1})

    resp = Req.stream!(req, method: :post)
    assert resp.status == 200
    assert resp.body == "ok"

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc -> {:cont, [data | acc]} end, method: :post)

    assert resp.status == 200
    assert acc == ["ok"]
  end

  test "into: fun" do
    {req, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
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
      end)

    resp = Req.request!(req)
    assert resp.status == 200
    assert resp.body == ["foo", "bar", "baz"]
    refute_receive _
  end

  test "into: fun with halt" do
    {req, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
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
      end)

    resp = Req.request!(req)
    assert resp.status == 200
    assert resp.body == ["foo"]
    refute_receive _
  end

  test "into: fun with send_resp" do
    {req, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Req.new(
          plug: fn conn ->
            send_resp(conn, 200, "foo")
          end,
          into: fn {:data, data}, {req, resp} ->
            {:cont, {req, put_in(resp.body, [data])}}
          end
        )
      end)

    resp = Req.request!(req)
    assert resp.status == 200
    assert resp.body == ["foo"]
    refute_receive _
  end

  test "into: fun with send_file" do
    {req, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Req.new(
          plug: fn conn ->
            send_file(conn, 200, "mix.exs")
          end,
          into: fn {:data, data}, {req, resp} ->
            {:cont, {req, put_in(resp.body, [data])}}
          end
        )
      end)

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

    {:error, err, resp} = Req.stream(req)
    assert err == %Req.TransportError{reason: :timeout}
    assert resp.status == nil
    assert resp.body == ""

    {:error, err, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc ->
        {:cont, [data | acc]}
      end)

    assert err == %Req.TransportError{reason: :timeout}
    assert resp.status == nil
    assert acc == []
  end

  test "compressed request body" do
    plug = fn conn ->
      assert get_req_header(conn, "content-encoding") == []
      {:ok, ~s|{"test":"data"}|, conn} = read_body(conn)
      Req.Test.json(conn, %{success: true})
    end

    req = Req.new(plug: plug, json: %{test: "data"}, compress_body: true)

    resp = Req.stream!(req, method: :post)
    assert resp.status == 200
    assert resp.body == %{"success" => true}

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc -> {:cont, [data | acc]} end, method: :post)

    assert resp.status == 200
    assert acc == [~s|{"success":true}|]
  end

  test "bad return" do
    plug = fn _ ->
      :bad
    end

    assert_raise ArgumentError, "expected to return %Plug.Conn{}, got: :bad", fn ->
      Req.stream!(plug: plug)
    end

    assert_raise ArgumentError, "expected to return %Plug.Conn{}, got: :bad", fn ->
      Req.stream([plug: plug], [], fn _data, _resp, acc -> {:cont, acc} end)
    end
  end

  test "no response" do
    plug = fn conn ->
      conn
    end

    assert_raise RuntimeError, ~r"expected connection to have a response", fn ->
      Req.stream!(plug: plug)
    end

    assert_raise RuntimeError, ~r"expected connection to have a response", fn ->
      Req.stream([plug: plug], [], fn _data, _resp, acc -> {:cont, acc} end)
    end
  end
end
