defmodule Req.NDJSONTest do
  use Req.Case, async: true

  test "decoded by default" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}\n|)
        end
      )

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == [%{"a" => 1}]
  end

  test "application/ndjson" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/ndjson")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}\n|)
        end
      )

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == [%{"a" => 1}]
  end

  test "success" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> send_resp_chunked([~s|{"a":1}\n{"b|, ~s|":2}\n|])
        end
      )

    resp = Req.stream!(req, decoders: [:ndjson])
    assert resp.status == 200
    assert resp.body == [%{"a" => 1}, %{"b" => 2}]

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        decoders: [:ndjson]
      )

    assert resp.status == 200
    assert resp.body == nil
    assert Enum.reverse(acc) == [%{"a" => 1}, %{"b" => 2}]
  end

  test "without trailing newline" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}\n\n{"b":2}|)
        end
      )

    resp = Req.stream!(req, decoders: [:ndjson])
    assert resp.status == 200
    assert resp.body == [%{"a" => 1}, %{"b" => 2}]

    {:ok, _resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        decoders: [:ndjson]
      )

    assert Enum.reverse(acc) == [%{"a" => 1}, %{"b" => 2}]
  end

  test "invalid" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}\nbad\n|)
        end
      )

    {:error, err, resp} = Req.stream(req, decoders: [:ndjson])

    assert err == %JSON.DecodeError{
             message: "invalid byte 98 at position (byte offset) 0",
             data: "bad",
             offset: 0
           }

    assert resp.status == 200
    assert resp.body == ""

    {:error, err, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        decoders: [:ndjson]
      )

    assert err == %JSON.DecodeError{
             message: "invalid byte 98 at position (byte offset) 0",
             data: "bad",
             offset: 0
           }

    assert resp.status == 200
    assert resp.body == nil
    assert acc == []
  end

  test "halt" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}\n{"b":2}\n|)
        end
      )

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:halt, [data | acc]}
        end,
        decoders: [:ndjson]
      )

    assert resp.status == 200
    assert resp.body == nil
    assert acc == [%{"a" => 1}]
  end

  test "content-encoding is not decoded when streaming" do
    body = :zlib.gzip(~s|{"a":1}\n|)

    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, body)
        end
      )

    resp = Req.stream!(req, decoders: [:ndjson])
    assert resp.status == 200
    assert resp.body == body

    {:ok, _resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        decoders: [:ndjson]
      )

    assert IO.iodata_to_binary(Enum.reverse(acc)) == body
  end

  test "compressed: true" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> send_resp_gzip(~s|{"a":1}\n|)
        end
      )

    resp = Req.stream!(req, compressed: true, decoders: [:ndjson])
    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == [%{"a" => 1}]

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        compressed: true,
        decoders: [:ndjson]
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "content-encoding") == []
    assert resp.body == nil
    assert Enum.reverse(acc) == [%{"a" => 1}]
  end

  test "invalid with compressed: true" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> send_resp_gzip(~s|{"a":1}\nbad\n|)
        end
      )

    {:error, err, resp} = Req.stream(req, compressed: true, decoders: [:ndjson])

    assert err == %JSON.DecodeError{
             message: "invalid byte 98 at position (byte offset) 0",
             data: "bad",
             offset: 0
           }

    assert resp.status == 200
    assert resp.body == ""

    {:error, err, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        compressed: true,
        decoders: [:ndjson]
      )

    assert %JSON.DecodeError{} = err
    assert resp.status == 200
    assert resp.body == nil
    assert acc == []
  end

  test "decoders: false when streaming" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          conn
          |> put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_resp(200, ~s|{"a":1}\n|)
        end
      )

    {:ok, _resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        decoders: false
      )

    assert IO.iodata_to_binary(Enum.reverse(acc)) == ~s|{"a":1}\n|
  end
end
