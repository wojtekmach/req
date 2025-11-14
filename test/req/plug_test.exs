defmodule Req.PlugTest do
  use ExUnit.Case, async: true

  test "reading request body" do
    plug = fn conn ->
      {:ok, "{\"a\":1}", conn} = Plug.Conn.read_body(conn)
      {:ok, "", conn} = Plug.Conn.read_body(conn)
      assert conn.body_params == %{"a" => 1}
      assert Req.Test.raw_body(conn) == "{\"a\":1}"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert Req.post!(plug: plug, json: %{a: 1}).body == "ok"
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

    assert Req.post!(plug: plug, json: %{a: 1}).body == "ok"
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

    assert Req.post!(plug: plug, json: %{a: 1}).body == "ok"
  end

  test "reading binary body" do
    plug = fn conn ->
      {:ok, "foo", conn} = Plug.Conn.read_body(conn)
      {:ok, "", conn} = Plug.Conn.read_body(conn)
      assert Req.Test.raw_body(conn) == "foo"
      assert Req.Test.raw_body(conn) == "foo"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert Req.post!(plug: plug, body: "foo").body == "ok"
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

    assert Req.post!(plug: plug, body: "foo").body == "ok"
  end
end
