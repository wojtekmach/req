defmodule Req.JSONTest do
  use Req.Case, async: true

  @tag skip: Req.Case.adapter() == :httpc
  test "success" do
    %{req: req} =
      serve(fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp_chunked([~s|{"message":|, ~s|"Hello, World!"}|])
      end)

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == %{"message" => "Hello, World!"}

    {:ok, resp, acc} =
      Req.stream(
        req,
        [],
        fn data, _resp, acc -> {:cont, [data | acc]} end
      )

    assert resp.status == 200
    assert resp.body == nil
    assert acc == ["\"Hello, World!\"}", "{\"message\":"]
  end

  @tag skip: Req.Case.adapter() == :httpc
  test "bad json - unexpected end" do
    %{req: req} =
      serve(fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp_chunked([~s|{"message":|, ~s|"Hello"|])
      end)

    {:error, err, resp} = Req.stream(req)
    assert %JSON.DecodeError{} = err
    assert Exception.message(err) == "unexpected end of JSON binary"
    assert resp.status == 200
    assert resp.body == ""

    {:ok, resp, acc} =
      Req.stream(req, [], fn data, _resp, acc -> {:cont, [data | acc]} end)

    assert resp.status == 200
    assert resp.body == nil
    assert acc == ["\"Hello\"", "{\"message\":"]
  end

  @tag skip: adapter() == :httpc
  test "bad json - trailing bytes" do
    %{req: req} =
      serve(fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp_chunked([~s|{"message":"Hello"}x|])
      end)

    {:error, err, resp} = Req.stream(req)
    assert err == %JSON.DecodeError{message: "invalid byte 120"}
    assert resp.status == 200
    assert resp.body == ""

    %{req: req} =
      serve(fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp_chunked([~s|{"message":"Hello"}|, " \n", "x"])
      end)

    {:error, err, resp} = Req.stream(req)
    assert err == %JSON.DecodeError{message: "invalid byte 120"}
    assert resp.status == 200
    assert resp.body == ""

    %{req: req} =
      serve(fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp_chunked([~s|{"message":"Hello"}|, " \n"])
      end)

    resp = Req.stream!(req)
    assert resp.status == 200
    assert resp.body == %{"message" => "Hello"}
  end

  test "bad json - invalid sequence" do
    %{req: req} =
      serve(fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp_chunked([~s|{"message":|, ~s|"\x01"|])
      end)

    {:error, err, resp} = Req.stream(req)
    assert %JSON.DecodeError{} = err
    assert Exception.message(err) == "invalid byte 1"
    assert resp.status == 200
    assert resp.body == ""
  end
end
