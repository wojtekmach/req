defmodule Req.NDJSON do
  # @moduledoc """
  # [NDJSON] decoding using `Req.JSON`.

  # Each line is decoded as a separate JSON document. This module is used by `Req.Decode` on
  # `application/x-ndjson` and `application/ndjson`. With `Req.stream/4`, each line is delivered
  # as its own data event.

  # [NDJSON]: https://github.com/ndjson/ndjson-spec
  # """

  @doc false
  def decode_init(:buffer) do
    {:buffer, "", []}
  end

  def decode_init(:stream) do
    {:stream, ""}
  end

  @doc false
  def decode_chunk({:buffer, buffer, values}, data) do
    with {:ok, new_values, buffer} <- split_lines(buffer, data) do
      {:ok, nil, {:buffer, buffer, Enum.reverse(new_values, values)}}
    end
  end

  def decode_chunk({:stream, buffer}, data) do
    with {:ok, values, buffer} <- split_lines(buffer, data) do
      {:ok, values, {:stream, buffer}}
    end
  end

  @doc false
  def decode_finish({:buffer, buffer, values}) do
    with {:ok, tail} <- decode_tail(buffer) do
      {:ok, Enum.reverse(values, tail)}
    end
  end

  def decode_finish({:stream, buffer}) do
    decode_tail(buffer)
  end

  @doc false
  def decode_close(_state) do
    :ok
  end

  defp split_lines(buffer, data) do
    parts = String.split(buffer <> data, "\n")
    {lines, [buffer]} = Enum.split(parts, -1)
    decode_lines(lines, [], buffer)
  end

  defp decode_lines([line | lines], values, buffer) do
    if String.trim(line) == "" do
      decode_lines(lines, values, buffer)
    else
      with {:ok, value} <- decode_json(line) do
        decode_lines(lines, [value | values], buffer)
      end
    end
  end

  defp decode_lines([], values, buffer) do
    {:ok, Enum.reverse(values), buffer}
  end

  defp decode_tail(buffer) do
    if String.trim(buffer) == "" do
      {:ok, []}
    else
      with {:ok, value} <- decode_json(buffer) do
        {:ok, [value]}
      end
    end
  end

  defp decode_json(binary) do
    case JSON.decode(binary) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, {:unexpected_end, offset}} ->
        {:error,
         %JSON.DecodeError{
           message: "unexpected end of JSON binary at position (byte offset) #{offset}",
           data: binary,
           offset: offset
         }}

      {:error, {:invalid_byte, offset, byte}} ->
        {:error,
         %JSON.DecodeError{
           message: "invalid byte #{byte} at position (byte offset) #{offset}",
           data: binary,
           offset: offset
         }}

      {:error, {:unexpected_sequence, offset, bytes}} ->
        {:error,
         %JSON.DecodeError{
           message: "unexpected sequence #{inspect(bytes)} at position (byte offset) #{offset}",
           data: binary,
           offset: offset
         }}
    end
  end
end
