defmodule Req.SSETest do
  use Req.Case, async: true

  test "decoded by default" do
    %{req: req} =
      serve("GET /": &send_resp_sse(&1, ["data: foo\n\n"]))

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == [%{data: "foo"}]
  end

  test "success" do
    %{req: req} =
      serve(
        "GET /": fn conn ->
          send_resp_sse(conn, [
            "bad\n\ndata: foo\n\nevent: msg\ndata: ba",
            "r\n\ndata: incomplete"
          ])
        end
      )

    resp = Req.stream!(req, decoders: [:sse])
    assert resp.status == 200
    assert resp.body == [%{data: "foo"}, %{data: "bar", event: "msg"}]

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc ->
          {:cont, [data | acc]}
        end,
        decoders: [:sse]
      )

    assert resp.status == 200
    assert resp.body == nil
    assert Enum.reverse(acc) == [%{data: "foo"}, %{data: "bar", event: "msg"}]
  end
end
