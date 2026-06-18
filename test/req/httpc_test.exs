defmodule Req.HTTPCTest do
  use Req.Case, async: true

  @moduletag :adapter_httpc

  setup do
    %{url: url} =
      start_http_server(fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

    req =
      Req.new(
        adapter: &Req.HTTPC.run/1,
        url: url
      )

    [req: req]
  end

  describe "httpc" do
    test "request", %{req: req} do
      resp = Req.get!(req)
      assert resp.status == 200
      assert resp.body == "ok"
    end

    test "post request body" do
      %{url: url} =
        start_http_server(fn conn ->
          assert {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, body)
        end)

      req = Req.new(adapter: &Req.HTTPC.run/1, url: url)

      resp = Req.post!(req, body: "foofoofoo")
      assert resp.status == 200
      assert resp.body == "foofoofoo"
    end

    test "stream request body" do
      %{url: url} =
        start_http_server(fn conn ->
          assert {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, body)
        end)

      req = Req.new(adapter: &Req.HTTPC.run/1, url: url)

      resp = Req.post!(req, body: {:stream, Stream.take(["foo", "foo", "foo"], 2)})
      assert resp.status == 200
      assert resp.body == "foofoo"
    end

    test "into: fun" do
      %{url: url} =
        start_http_server(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      req = Req.new(adapter: &Req.HTTPC.run/1, url: url)
      pid = self()

      resp =
        Req.get!(
          req,
          into: fn {:data, data}, acc ->
            send(pid, {:data, data})
            {:cont, acc}
          end
        )

      assert resp.status == 200
      assert resp.headers["transfer-encoding"] == ["chunked"]
      assert_receive {:data, "foobar"}

      # httpc seems to randomly chunk things
      receive do
        {:data, ""} -> :ok
      after
        0 -> :ok
      end

      refute_receive _
    end

    test "into: :self" do
      %{url: url} =
        start_http_server(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      req = Req.new(adapter: &Req.HTTPC.run/1, url: url)
      resp = Req.get!(req, into: :self)
      assert resp.status == 200

      # httpc seems to randomly chunk things
      assert Req.parse_message(resp, assert_receive(_)) in [
               {:ok, [data: "foo"]},
               {:ok, [data: "foobar"]}
             ]

      assert Req.parse_message(resp, assert_receive(_)) in [
               {:ok, [data: "bar"]},
               {:ok, [data: ""]},
               {:ok, [:done]}
             ]
    end

    test "into: pid cancel" do
      %{url: url} =
        start_http_server(fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "foo")
          {:ok, conn} = Plug.Conn.chunk(conn, "bar")
          conn
        end)

      req = Req.new(adapter: &Req.HTTPC.run/1, url: url)
      resp = Req.get!(req, into: :self)
      assert resp.status == 200
      assert :ok = Req.cancel_async_response(resp)
    end
  end
end
