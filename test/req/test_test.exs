defmodule Req.TestTest do
  use ExUnit.Case, async: true

  test "stub" do
    assert_raise RuntimeError, ~r/cannot find stub/, fn ->
      Req.Test.stub(:foo)
    end

    Req.Test.stub(:foo, 1)
    assert Req.Test.stub(:foo) == 1

    Req.Test.stub(:foo, 2)
    assert Req.Test.stub(:foo) == 2

    Task.async(fn ->
      assert Req.Test.stub(:foo) == 2
      Req.Test.stub(:foo, 3)
    end)
    |> Task.await()

    assert Req.Test.stub(:foo) == 2
  end

  test "plug" do
    Req.Test.stub(:foo, fn conn ->
      Plug.Conn.send_resp(conn, 200, "hi")
    end)

    assert Req.get!(plug: {Req.Test, :foo}).body == "hi"
  end
end
