defmodule Req.UtilsTest do
  use ExUnit.Case, async: true

  test "collectable_with" do
    collector = fn
      acc, collector, {:cont, element} ->
        collector.(acc, {:cont, String.upcase(element)})

      acc, collector, :done ->
        collector.(acc, :done)

      acc, collector, :halt ->
        collector.(acc, :halt)
    end

    list_with_upcase = Req.Utils.collectable_with([], & &1, collector)
    assert Enum.into(~w[foo bar baz], list_with_upcase) == ~w[FOO BAR BAZ]
  end

  test "with_gunzip/2" do
    assert Enum.into([:zlib.gzip("foobarbaz")], Req.Utils.with_gunzip("")) ==
             "foobarbaz"
  end

  test "with_gzip/2" do
    assert Enum.into(~w[foo bar baz], Req.Utils.with_gzip("")) ==
             :zlib.gzip("foobarbaz")
  end

  test "with_hash/2" do
    assert Enum.into(~w[foo bar baz], Req.Utils.with_hash("", :md5)) ==
             {"foobarbaz", :crypto.hash(:md5, "foobarbaz")}
  end

  test "compose" do
    collectable =
      ""
      |> Req.Utils.with_hash(:md5)
      |> Req.Utils.with_gunzip()

    assert Enum.into([:zlib.gzip("foobarbaz")], collectable) ==
             {"foobarbaz", :crypto.hash(:md5, "foobarbaz")}
  end
end
