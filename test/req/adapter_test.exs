defmodule Req.AdapterTest do
  use ExUnit.Case, async: true

  test "reading request body" do
    plug = fn conn ->
      {:ok, "{\"a\":1}", conn} = Plug.Conn.read_body(conn)
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

  test "fetches request with parsers" do
    plug = fn conn ->
      parser_opts =
        Plug.Parsers.init(
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Jason,
          body_reader: {Req.Test, :__read_request_body__, []}
        )

      conn = Plug.Parsers.call(conn, parser_opts)

      {:ok, "{\"a\":1}", conn} = Plug.Conn.read_body(conn)
      assert conn.body_params == %{"a" => 1}
      assert Req.Test.raw_body(conn) == "{\"a\":1}"
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert Req.post!(plug: plug, json: %{a: 1}).body == "ok"
  end
end
