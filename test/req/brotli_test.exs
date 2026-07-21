defmodule Req.BrotliTest do
  use ExUnit.Case, async: true

  test "success" do
    assert "hello world" |> Req.Brotli.encode() |> Req.Brotli.decode() == {:ok, "hello world"}

    compressed =
      ["hello ", "world"]
      |> Req.Brotli.encode_to_stream()
      |> Enum.join()

    assert Req.Brotli.decode(compressed) == {:ok, "hello world"}

    chunks = for <<byte <- compressed>>, do: <<byte>>
    assert chunks |> Req.Brotli.decode_stream() |> Enum.join() == "hello world"
  end

  test "invalid data" do
    assert Req.Brotli.decode("invalid") == {:error, :brotli_error}

    assert_raise ErlangError, fn ->
      ["inv", "alid"]
      |> Req.Brotli.decode_stream()
      |> Enum.join()
    end
  end
end
