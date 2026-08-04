defmodule Req.HTTPErrorsTest do
  use Req.Case, async: true

  test "return by default" do
    %{req: req} = serve("GET /": &send_resp(&1, 404, "not found"))

    resp = Req.stream!(req)
    assert resp.status == 404
    assert resp.body == "not found"
  end

  test "raise" do
    %{req: req} = serve("GET /": &send_resp(&1, 404, "not found"))

    assert_raise RuntimeError,
                 "The requested URL returned error: 404\nResponse body: \"not found\"",
                 fn ->
                   Req.stream!(req, http_errors: :raise)
                 end
  end

  test "stream" do
    %{req: req} = serve("GET /": &send_resp(&1, 404, "not found"))

    assert_raise RuntimeError,
                 "The requested URL returned error: 404\nResponse body: nil",
                 fn ->
                   Req.stream(req, [], fn data, _resp, acc -> {:cont, [data | acc]} end,
                     http_errors: :raise
                   )
                 end
  end
end
