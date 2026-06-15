defmodule Req.EventStreamTest do
  use Req.Case, async: true

  test "events" do
    assert "data: hello\n\ndata: world\n\n" |> Req.EventStream.stream() |> Enum.to_list() ==
             [%{data: "hello"}, %{data: "world"}]
  end

  test "all fields" do
    assert "id: 1\nevent: message\nretry: 5000\ndata: hello\n\n"
           |> Req.EventStream.stream()
           |> Enum.to_list() ==
             [%{data: "hello", event: "message", id: "1", retry: 5000}]
  end

  test "incomplete event at the end is discarded" do
    assert "data: hello\n\ndata: wor" |> Req.EventStream.stream() |> Enum.to_list() ==
             [%{data: "hello"}]
  end

  test "empty" do
    assert "" |> Req.EventStream.stream() |> Enum.to_list() == []
  end

  describe "Req.stream" do
    test "it works" do
      %{url: url} =
        start_http_server(fn conn ->
          send_resp_sse(conn, ["hello", "world"])
        end)

      {:ok, events} =
        Req.stream(url, [], fn event, _resp, acc ->
          {:ok, [event | acc]}
        end)

      assert events == [%{data: "world"}, %{data: "hello"}]
    end

    test "invalid response body" do
      %{url: url} =
        start_http_server(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, "oops")
        end)

      {:ok, events} =
        Req.stream(url, [], fn event, _resp, acc ->
          {:ok, [event | acc]}
        end)

      assert events == []
    end

    test "fun returning error halts" do
      %{url: url} =
        start_http_server(fn conn ->
          send_resp_sse(conn, ["hello", "world"])
        end)

      {:error, %RuntimeError{message: "stop"}, events} =
        Req.stream(url, [], fn event, _resp, acc ->
          {:error, RuntimeError.exception("stop"), [event | acc]}
        end)

      assert events == [%{data: "hello"}]
    end
  end

  defp send_resp_sse(conn, enumerable) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(enumerable, conn, fn data, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, "data: #{data}\n\n")
      conn
    end)
  end
end
