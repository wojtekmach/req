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

  test "streaming decompression continues until all output is read" do
    payload = :binary.copy("0123456789abcdef", 64 * 1024)
    compressed = Req.Brotli.encode(payload)

    assert [compressed] |> Req.Brotli.decode_stream() |> Enum.join() == payload
  end

  test "invalid data" do
    assert Req.Brotli.decode("invalid") ==
             {:error, %Req.DecompressError{format: :br, data: "invalid", reason: :brotli_error}}

    assert_raise Req.DecompressError, "br decompression failed, reason: :brotli_error", fn ->
      ["inv", "alid"]
      |> Req.Brotli.decode_stream()
      |> Enum.join()
    end
  end
end
