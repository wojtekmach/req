defmodule Req.CSV do
  @moduledoc false

  def decode(string) do
    {:ok, NimbleCSV.RFC4180.parse_string(string, skip_headers: false)}
  end

  def decode_init do
    nil
  end

  def decode_chunk(state, data) do
    {:ok, data, state}
  end

  def decode_finish(_state) do
    {:ok, nil}
  end

  def decode_close(_state) do
    :ok
  end
end
