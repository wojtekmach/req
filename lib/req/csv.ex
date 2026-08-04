defmodule Req.CSV do
  @moduledoc false

  def decode(string) do
    {:ok, NimbleCSV.RFC4180.parse_string(string, skip_headers: false)}
  end

  def decode_init(:buffer) do
    {:buffer, ""}
  end

  def decode_init(:stream) do
    :stream
  end

  def decode_chunk({:buffer, buffer}, data) do
    {:ok, data, {:buffer, [buffer | data]}}
  end

  def decode_chunk(:stream, data) do
    {:ok, data, :stream}
  end

  def decode_finish({:buffer, buffer}) do
    decode(IO.iodata_to_binary(buffer))
  end

  def decode_finish(:stream) do
    {:ok, nil}
  end

  def decode_close(_state) do
    :ok
  end
end
