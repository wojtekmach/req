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
      # Req.Test.stub(:foo, 3)
    end)
    |> Task.await()

    assert Req.Test.stub(:foo) == 2
  end
end
