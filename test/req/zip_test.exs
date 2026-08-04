defmodule Req.ZIPTest do
  use Req.Case, async: true

  test "success" do
    %{req: req} =
      serve(fn conn ->
        send_resp_zip(conn, [{~c"a.txt", "aaa"}])
      end)

    resp = Req.stream!(req, decoders: [:zip])
    assert resp.status == 200
    assert resp.body == [{~c"a.txt", "aaa"}]

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end,
        decoders: [:zip]
      )

    assert resp.status == 200
    assert resp.body == nil
    assert IO.iodata_to_binary(Enum.reverse(acc)) == Req.ZIP.encode!([{~c"a.txt", "aaa"}])
  end
end
