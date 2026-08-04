defmodule Req.NDJSON do
  @moduledoc """
  [NDJSON] decoding using `Req.JSON`.

  Each line is decoded as a separate JSON document. This module is used by `Req.Decode` on
  `application/x-ndjson` and `application/ndjson`. With `Req.stream/4`, each line is delivered
  as its own data event.

  [NDJSON]: https://github.com/ndjson/ndjson-spec
  """

  @doc false
  def decode_init do
    ""
  end

  @doc false
  def decode_chunk(buffer, data) do
    parts = String.split(buffer <> data, "\n")
    {lines, [buffer]} = Enum.split(parts, -1)
    decode_lines(lines, [], buffer)
  end

  @doc false
  def decode_finish(buffer) do
    if String.trim(buffer) == "" do
      {:ok, []}
    else
      with {:ok, value} <- Req.JSON.decode(buffer) do
        {:ok, [value]}
      end
    end
  end

  @doc false
  def decode_close(_state) do
    :ok
  end

  @doc false
  def decode(binary) do
    with {:ok, values, buffer} <- decode_chunk(decode_init(), binary),
         {:ok, rest} <- decode_finish(buffer) do
      {:ok, values ++ rest}
    end
  end

  defp decode_lines([line | lines], values, buffer) do
    if String.trim(line) == "" do
      decode_lines(lines, values, buffer)
    else
      with {:ok, value} <- Req.JSON.decode(line) do
        decode_lines(lines, [value | values], buffer)
      end
    end
  end

  defp decode_lines([], values, buffer) do
    {:ok, Enum.reverse(values), buffer}
  end
end
