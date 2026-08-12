defmodule Req.JSON do
  @moduledoc """
  JSON decoding using Elixir's `JSON` module.

  This module is used by `Req.Decode` on `.json`, `application/json`,
  and `application/vnd.api+json`.
  """

  @doc false
  def decode_init(:buffer) do
    {:continue, state} = :json.decode_start("", nil, %{})
    {:buffer, state}
  end

  def decode_init(:stream) do
    :stream
  end

  @doc false
  def decode_chunk({:buffer, state}, data) do
    case :json.decode_continue(data, state) do
      {:continue, state} ->
        {:ok, nil, {:buffer, state}}

      {decoded, _acc = nil, rest} ->
        decode_trailing({:buffer, :done, decoded}, rest)
    end
  rescue
    err in ErlangError ->
      {:error, %JSON.DecodeError{message: err_message(err.original)}}
  end

  def decode_chunk({:buffer, :done, _decoded} = state, data) do
    decode_trailing(state, data)
  end

  def decode_chunk(:stream, data) do
    {:ok, data, :stream}
  end

  @doc false
  def decode_finish({:buffer, :done, decoded}) do
    {:ok, decoded}
  end

  def decode_finish({:buffer, state}) do
    {decoded, nil, ""} = :json.decode_continue(:end_of_input, state)
    {:ok, decoded}
  rescue
    err in ErlangError ->
      {:error, %JSON.DecodeError{message: err_message(err.original)}}
  end

  def decode_finish(:stream) do
    {:ok, nil}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end

  defp decode_trailing(state, <<ws, rest::binary>>) when ws in [?\s, ?\t, ?\n, ?\r] do
    decode_trailing(state, rest)
  end

  defp decode_trailing(state, "") do
    {:ok, nil, state}
  end

  defp decode_trailing(_state, <<byte, _::binary>>) do
    {:error, %JSON.DecodeError{message: err_message({:invalid_byte, byte})}}
  end

  defp err_message(:unexpected_end) do
    "unexpected end of JSON binary"
  end

  defp err_message({:invalid_byte, byte}) do
    "invalid byte #{byte}"
  end

  defp err_message({:unexpected_sequence, bytes}) do
    "unexpected sequence #{inspect(bytes)}"
  end
end
