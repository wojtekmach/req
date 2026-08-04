defmodule Req.JSON do
  @moduledoc """
  JSON decoding using `JSON`.

  This module is used by `Req.Decode` on `.json`, `application/json`,
  and `application/vnd.api+json`.
  """

  @doc false
  def decode(binary) do
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

  @doc false
  def decode_init do
    nil
  end

  @doc false
  def decode_chunk(state, data) do
    {:ok, data, state}
  end

  @doc false
  def decode_finish(_state) do
    {:ok, nil}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end
end
