defmodule Req.GzipTest do
  use ExUnit.Case, async: true

  test "success" do
    assert "hello world" |> Req.Gzip.encode() |> Req.Gzip.decode() == {:ok, "hello world"}

    compressed =
      ["hello ", "world"]
      |> Req.Gzip.encode_to_stream()
      |> Enum.join()

    assert Req.Gzip.decode(compressed) == {:ok, "hello world"}

    chunks = for <<byte <- compressed>>, do: <<byte>>
    assert chunks |> Req.Gzip.decode_stream() |> Enum.join() == "hello world"

    assert Req.Gzip.decode(compressed <> compressed) == {:ok, "hello worldhello world"}

    assert [compressed, compressed] |> Req.Gzip.decode_stream() |> Enum.join() ==
             "hello worldhello world"
  end

  test "invalid data" do
    assert Req.Gzip.decode("invalid") ==
             {:error, %Req.DecompressError{format: :gzip, data: "invalid", reason: :data_error}}

    assert_raise Req.DecompressError, "gzip decompression failed, reason: :data_error", fn ->
      ["inv", "alid"]
      |> Req.Gzip.decode_stream()
      |> Enum.join()
    end
  end
end
