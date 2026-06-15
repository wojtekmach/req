defmodule Req.NDJSONTest do
  use Req.Case, async: true

  # TODO: Remove when requiring OTP 27
  @moduletag skip: System.otp_release() < "27"

  test "objects" do
    assert ~s|{"id":1}\n{"id":2}\n| |> Req.NDJSON.stream() |> Enum.to_list() ==
             [%{"id" => 1}, %{"id" => 2}]
  end

  test "crlf and blank lines" do
    assert ~s|{"id":1}\r\n\n\r\n{"id":2}\r\n| |> Req.NDJSON.stream() |> Enum.to_list() ==
             [%{"id" => 1}, %{"id" => 2}]
  end

  test "no trailing newline" do
    assert ~s|{"id":1}\n{"id":2}| |> Req.NDJSON.stream() |> Enum.to_list() ==
             [%{"id" => 1}, %{"id" => 2}]
  end

  test "scalars" do
    assert ~s|1\n"two"\n[3]\n4| |> Req.NDJSON.stream() |> Enum.to_list() == [1, "two", [3], 4]
  end

  test "empty" do
    assert "" |> Req.NDJSON.stream() |> Enum.to_list() == []
    assert "\n \r\n" |> Req.NDJSON.stream() |> Enum.to_list() == []
  end

  test "invalid json" do
    assert_raise Req.NDJSON.DecodeError, "invalid byte 111 at position (byte offset) 1", fn ->
      ~s|{"id":1}\noops\n| |> Req.NDJSON.stream() |> Enum.to_list()
    end

    assert_raise Req.NDJSON.DecodeError,
                 "unexpected end of JSON binary at position (byte offset) 0",
                 fn ->
                   ~s|{"id":| |> Req.NDJSON.stream() |> Enum.to_list()
                 end
  end

  describe "decode" do
    test "objects" do
      assert Req.NDJSON.decode(~s|{"id":1}\n{"id":2}|) == {:ok, [%{"id" => 1}, %{"id" => 2}]}
    end

    test "invalid json" do
      assert {:error, %Req.NDJSON.DecodeError{}} = Req.NDJSON.decode(~s|{"id":|)
    end
  end

  describe "Req.stream" do
    test "it works" do
      %{url: url} =
        start_http_server(fn conn ->
          send_resp_ndjson(conn, [%{id: 1}, %{id: 2}])
        end)

      {:ok, objects} =
        Req.stream(url, [], fn object, _resp, acc ->
          {:ok, [object | acc]}
        end)

      assert objects == [%{"id" => 2}, %{"id" => 1}]
    end

    test "decoders: false disables decoding" do
      %{url: url} =
        start_http_server(fn conn ->
          send_resp_ndjson(conn, [%{id: 1}, %{id: 2}])
        end)

      {:ok, chunks} =
        Req.stream(
          url,
          [],
          fn chunk, _resp, acc ->
            {:ok, [chunk | acc]}
          end,
          decoders: false
        )

      assert IO.iodata_to_binary(Enum.reverse(chunks)) == ~s|{"id":1}\n{"id":2}\n|
    end

    test "compressed: true" do
      %{url: url} =
        start_http_server(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, :zlib.gzip(~s|{"id":1}\n{"id":2}\n|))
        end)

      {:ok, objects} =
        Req.stream(
          url,
          [],
          fn object, _resp, acc ->
            {:ok, [object | acc]}
          end,
          compressed: true
        )

      assert objects == [%{"id" => 2}, %{"id" => 1}]
    end

    test "invalid response body" do
      %{url: url} =
        start_http_server(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.send_resp(200, "oops")
        end)

      {:error, %Req.NDJSON.DecodeError{} = exception, []} =
        Req.stream(url, [], fn object, _resp, acc ->
          {:ok, [object | acc]}
        end)

      assert exception.message == "invalid byte 111 at position (byte offset) 0"
    end

    test "fun returning error halts" do
      %{url: url} =
        start_http_server(fn conn ->
          send_resp_ndjson(conn, [%{id: 1}, %{id: 2}])
        end)

      {:error, %RuntimeError{message: "stop"}, objects} =
        Req.stream(url, [], fn object, _resp, acc ->
          {:error, RuntimeError.exception("stop"), [object | acc]}
        end)

      assert objects == [%{"id" => 1}]
    end
  end

  defp send_resp_ndjson(conn, enumerable) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(enumerable, conn, fn object, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, [:json.encode(object), "\n"])
      conn
    end)
  end
end
