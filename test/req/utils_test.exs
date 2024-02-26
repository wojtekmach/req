defmodule Req.UtilsTest do
  use ExUnit.Case, async: true

  test "with_hash/2" do
    assert Enum.into(~w[foo bar baz], Req.Utils.with_hash("", :md5)) ==
             {"foobarbaz", %{hash: :crypto.hash(:md5, "foobarbaz")}}
  end

  test "with_gunzip/2" do
    assert Enum.into([:zlib.gzip(~w[foo bar baz])], Req.Utils.with_gunzip("")) ==
             {"foobarbaz", %{}}
  end

  test "compose" do
    assert Enum.into(~w[foo bar baz], "" |> Req.Utils.with_hash(:md5) |> with_count()) ==
             {"foobarbaz", %{count: 3, hash: :crypto.hash(:md5, "foobarbaz")}}

    assert Enum.into(
             [:zlib.gzip("foobarbaz")],
             "" |> Req.Utils.with_gunzip() |> Req.Utils.with_hash(:md5) |> with_count()
           ) ==
             {"foobarbaz", %{count: 1, hash: :crypto.hash(:md5, "foobarbaz")}}
  end

  defp with_count(collectable) do
    Req.Utils.collectable_with(
      collectable,
      fn acc, state ->
        {acc, Map.put(state, :count, 0)}
      end,
      fn
        {:cont, element}, state ->
          {{:cont, element}, update_in(state.count, &(&1 + 1))}

        :halt, state ->
          {:halt, state}

        :done, state ->
          {:done, state}
      end
    )
  end
end
