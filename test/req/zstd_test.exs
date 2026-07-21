defmodule Req.ZstdTest do
  use ExUnit.Case, async: true

  @moduletag skip: System.otp_release() < "28"

  test "success" do
    assert "hello world" |> Req.Zstd.encode() |> Req.Zstd.decode() == {:ok, "hello world"}

    compressed =
      ["hello ", "world"]
      |> Req.Zstd.encode_to_stream()
      |> Enum.join()

    assert Req.Zstd.decode(compressed) == {:ok, "hello world"}

    chunks = for <<byte <- compressed>>, do: <<byte>>
    assert chunks |> Req.Zstd.decode_stream() |> Enum.join() == "hello world"

    big = String.duplicate("hello world", 50_000)
    big_compressed = Req.Zstd.encode(big)
    assert [big_compressed] |> Req.Zstd.decode_stream() |> Enum.join() == big
  end

  test "invalid data" do
    assert Req.Zstd.decode("invalid") == {:error, "Unknown frame descriptor"}

    assert_raise ErlangError, fn ->
      ["inv", "alid"]
      |> Req.Zstd.decode_stream()
      |> Enum.join()
    end
  end
end
