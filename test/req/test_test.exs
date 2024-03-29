defmodule Req.TestTest do
  use ExUnit.Case, async: true
  doctest Req.Test

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

  describe "expect/3" do
    test "works in the normal expectation-based way" do
      Req.Test.expect(:foo, 2, 1)
      assert Req.Test.stub(:foo) == 1
      assert Req.Test.stub(:foo) == 1

      assert_raise RuntimeError, "no stub or expectations for :foo", fn ->
        Req.Test.stub(:foo)
      end
    end

    test "works with the default expected count of 1" do
      Req.Test.expect(:foo_default, 1)
      assert Req.Test.stub(:foo_default) == 1

      assert_raise RuntimeError, "no stub or expectations for :foo_default", fn ->
        assert Req.Test.stub(:foo_default)
      end
    end
  end

  describe "plug" do
    test "function" do
      Req.Test.stub(:foo, fn conn ->
        Plug.Conn.send_resp(conn, 200, "hi")
      end)

      assert Req.get!(plug: {Req.Test, :foo}).body == "hi"
    end

    test "module" do
      defmodule Foo do
        def init(options), do: options
        def call(conn, []), do: Plug.Conn.send_resp(conn, 200, "hi")
      end

      Req.Test.stub(:foo, Foo)

      assert Req.get!(plug: {Req.Test, :foo}).body == "hi"
    end
  end

  describe "allow/3" do
    test "allows the request via an owner process" do
      test_pid = self()
      ref = make_ref()

      Req.Test.stub(:foo, 1)

      child_pid =
        spawn(fn ->
          # Make sure we have no $callers in the pdict.
          Process.delete(:"$callers")

          receive do
            :go -> send(test_pid, {ref, Req.Test.stub(:foo)})
          end
        end)

      Req.Test.stub(:foo, 1)
      Req.Test.allow(:foo, self(), child_pid)

      send(child_pid, :go)
      assert_receive {^ref, 1}
    end
  end

  describe "transport_error/2" do
    test "validate reason" do
      assert_raise ArgumentError, "unexpected Req.TransportError reason: :bad", fn ->
        Req.Test.transport_error(%Plug.Conn{}, :bad)
      end
    end
  end
end
